local core = require("openmw.core")
local settings = require("scripts.SkillPerkSystem.settings")
local treeRegistry = require("scripts.SkillPerkSystem.tree_registry")
local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local pluginLoader = require("scripts.SkillPerkSystem.plugin_loader")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local SOURCE_MANIFEST = "scripts.SkillPerkSystem.manifest"
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

local function registerPerk(data)
    return pluginAPI.registerPerk(data, SOURCE_MANIFEST)
end

local function registerTreeNode(data)
    return pluginAPI.registerTreeNode(data, SOURCE_MANIFEST)
end

local function registerPerkModule(data, expectedSkill)
    return pluginAPI.registerPerkModule(data, SOURCE_MANIFEST, expectedSkill)
end

local function registerEffect(data)
    return pluginAPI.registerEffect(data, SOURCE_MANIFEST)
end

local pluginValidationReport = pluginLoader.loadInstalledPacks(pluginAPI)
local preloadReport = pluginLoader.preloadPerkModules(pluginAPI)

local function validationError(message)
    error(VALIDATION_ERROR_TAG .. ": " .. tostring(message), 2)
end

local function extractSkillModuleInfo(packName, moduleName)
    local prefix = "scripts." .. tostring(packName) .. ".perks."
    if type(moduleName) ~= "string" or moduleName:sub(1, #prefix) ~= prefix then
        return nil, nil
    end

    local suffix = moduleName:sub(#prefix + 1)
    local skillID = suffix:match("^([^.]+)%.([^.]+)$")
    local moduleFile = suffix:match("^[^.]+%.([^.]+)$")
    if type(skillID) ~= "string" or skillID == "" or type(moduleFile) ~= "string" or moduleFile == "" then
        return nil, nil
    end

    return skillID, moduleFile
end

local function collectMergeStatsBySkill(report)
    local mergedFilesBySkill = {}
    local validationBySkill = {}

    for _, packReport in ipairs((report and report.packs) or {}) do
        local failedByModule = {}
        for _, failure in ipairs(packReport.moduleFailures or {}) do
            failedByModule[failure.module] = true
        end

        for _, moduleAttempt in ipairs(packReport.moduleAttempts or {}) do
            local skillID, moduleFile = extractSkillModuleInfo(packReport.packName, moduleAttempt.module)
            if skillID ~= nil then
                mergedFilesBySkill[skillID] = mergedFilesBySkill[skillID] or {}
                mergedFilesBySkill[skillID][packReport.packName .. ":" .. moduleFile] = true

                validationBySkill[skillID] = validationBySkill[skillID] or {
                    files = 0,
                    loaded = 0,
                    failed = 0,
                }

                local stats = validationBySkill[skillID]
                stats.files = stats.files + 1
                if moduleAttempt.success and not failedByModule[moduleAttempt.module] then
                    stats.loaded = stats.loaded + 1
                else
                    stats.failed = stats.failed + 1
                end
            end
        end
    end

    local result = {}
    for skillID, mergedFiles in pairs(mergedFilesBySkill) do
        local mergedCount = 0
        for _ in pairs(mergedFiles) do
            mergedCount = mergedCount + 1
        end

        local stats = validationBySkill[skillID] or { files = mergedCount, loaded = mergedCount, failed = 0 }
        table.insert(result, {
            skillID = skillID,
            mergedFiles = mergedCount,
            validationStatus = stats.failed > 0 and "failed" or "ok",
            filesLoaded = stats.loaded,
            filesFailed = stats.failed,
        })
    end

    table.sort(result, function(a, b)
        return a.skillID < b.skillID
    end)

    return result
end

local function formatCycleChain(chain)
    local labels = {}
    for _, entry in ipairs(chain) do
        local source = registryState.getTreeNodeSource(entry) or "unknown"
        table.insert(labels, tostring(entry) .. "(" .. tostring(source) .. ")")
    end
    return table.concat(labels, " -> ")
end

local function validateMergedTreeGraph()
    local nodeByID = registryState.getTreeNodes()

    local missingParents = {}
    for nodeID, node in pairs(nodeByID) do
        local source = registryState.getTreeNodeSource(nodeID) or "unknown"
        for _, parentID in ipairs(node.requires or {}) do
            if nodeByID[parentID] == nil then
                table.insert(
                    missingParents,
                    "node='"
                        .. tostring(nodeID)
                        .. "' source='"
                        .. tostring(source)
                        .. "' missing_parent='"
                        .. tostring(parentID)
                        .. "'"
                )
            end
        end
    end

    table.sort(missingParents)
    if #missingParents > 0 then
        validationError("missing node prerequisites detected: " .. table.concat(missingParents, "; "))
    end

    local visitState = {}
    local stack = {}

    local function detect(nodeID)
        local state = visitState[nodeID]
        if state == "visiting" then
            local startIndex = 1
            for i, stackID in ipairs(stack) do
                if stackID == nodeID then
                    startIndex = i
                    break
                end
            end
            local chain = {}
            for i = startIndex, #stack do
                table.insert(chain, stack[i])
            end
            table.insert(chain, nodeID)
            return chain
        end

        if state == "done" then
            return nil
        end

        visitState[nodeID] = "visiting"
        table.insert(stack, nodeID)

        local node = nodeByID[nodeID]
        for _, parentID in ipairs(node.requires or {}) do
            local cycle = detect(parentID)
            if cycle ~= nil then
                return cycle
            end
        end

        table.remove(stack)
        visitState[nodeID] = "done"
        return nil
    end

    local sortedNodeIDs = {}
    for nodeID in pairs(nodeByID) do
        table.insert(sortedNodeIDs, nodeID)
    end
    table.sort(sortedNodeIDs)

    for _, nodeID in ipairs(sortedNodeIDs) do
        local cycle = detect(nodeID)
        if cycle ~= nil then
            validationError("node prerequisite cycle detected: " .. formatCycleChain(cycle))
        end
    end
end

local function buildPluginValidationSummary(report)
    local packs = (type(report) == "table" and type(report.packs) == "table") and report.packs or {}
    local totalPacksDetected = (type(report) == "table" and type(report.totalPacksDetected) == "number") and report.totalPacksDetected
        or #packs

    local loadedSuccessfully = 0
    local failedOrSkipped = 0
    local strictValidationFailures = 0

    for _, packReport in ipairs(packs) do
        if packReport.status == "loaded" then
            loadedSuccessfully = loadedSuccessfully + 1
        else
            failedOrSkipped = failedOrSkipped + 1
        end

        for _, failure in ipairs(packReport.moduleFailures or {}) do
            if failure.class == "validation" then
                strictValidationFailures = strictValidationFailures + 1
            end
        end
    end

    print(
        "["
            .. settings.MOD_NAME
            .. "] plugin validation summary: packs="
            .. tostring(totalPacksDetected)
            .. " loaded="
            .. tostring(loadedSuccessfully)
            .. " failed_or_skipped="
            .. tostring(failedOrSkipped)
            .. " strict_validation_failures="
            .. tostring(strictValidationFailures)
    )

    if strictValidationFailures > 0 then
        print("[" .. settings.MOD_NAME .. "] !!! STRICT SCHEMA VALIDATION FAILURES DETECTED !!!")
    end

    for _, packReport in ipairs(packs) do
        if packReport.status ~= "loaded" then
            print(
                "["
                    .. settings.MOD_NAME
                    .. "] plugin validation issue: pack='"
                    .. tostring(packReport.packName)
                    .. "' status='"
                    .. tostring(packReport.status)
                    .. "' reason='"
                    .. tostring(packReport.reason)
                    .. "'"
            )
        end

        for _, failure in ipairs(packReport.moduleFailures or {}) do
            if failure.class == "validation" then
                print(
                    "["
                        .. settings.MOD_NAME
                        .. "] STRICT validation failure: pack='"
                        .. tostring(packReport.packName)
                        .. "' module='"
                        .. tostring(failure.module)
                        .. "' reason='"
                        .. tostring(failure.reason)
                        .. "'"
                )
            end
        end
    end

    if settings.PLUGIN_VALIDATION_VERBOSE then
        for _, packReport in ipairs(packs) do
            print(
                "["
                    .. settings.MOD_NAME
                    .. "] plugin report: pack='"
                    .. tostring(packReport.packName)
                    .. "' status='"
                    .. tostring(packReport.status)
                    .. "' manifest_found="
                    .. tostring(packReport.manifest and packReport.manifest.found)
                    .. " register_success="
                    .. tostring(packReport.manifest and packReport.manifest.registerSuccess)
                    .. " modules_attempted="
                    .. tostring(packReport.modulesAttemptedCount)
                    .. " modules_loaded="
                    .. tostring(packReport.modulesLoadedCount)
                    .. " failures="
                    .. tostring(#packReport.moduleFailures)
            )

            for _, failure in ipairs(packReport.moduleFailures) do
                print(
                    "["
                        .. settings.MOD_NAME
                        .. "] plugin report detail: pack='"
                        .. tostring(packReport.packName)
                        .. "' class='"
                        .. tostring(failure.class)
                        .. "' module='"
                        .. tostring(failure.module)
                        .. "' reason='"
                        .. tostring(failure.reason)
                        .. "'"
                )
            end
        end
    end
end

local function buildPreloadSummary(report)
    if type(report) ~= "table" then
        return
    end

    print(
        "["
            .. settings.MOD_NAME
            .. "] perk preload summary: packs_scanned="
            .. tostring(report.packsScanned or 0)
            .. " modules_discovered="
            .. tostring(report.modulesDiscovered or 0)
            .. " modules_loaded="
            .. tostring(report.modulesLoaded or 0)
            .. " modules_failed="
            .. tostring(report.modulesFailed or 0)
            .. " internal_modules_discovered="
            .. tostring(report.internalModulesDiscovered or 0)
            .. " internal_modules_loaded="
            .. tostring(report.internalModulesLoaded or 0)
            .. " internal_modules_failed="
            .. tostring(report.internalModulesFailed or 0)
            .. " duration_ms="
            .. tostring(report.durationMs or 0)
    )
end

local function getPerks()
    return registryState.getPerks()
end

local function getPerkIDs()
    return registryState.getPerkIDs()
end

local function getPerkIDsForSkill(skillID)
    local out = {}
    for _, id in ipairs(registryState.getPerkIDs()) do
        if registryState.getPerks()[id].skill == skillID then
            table.insert(out, id)
        end
    end
    return out
end

local function buildStartupSummary()
    local mergeStats = collectMergeStatsBySkill(pluginValidationReport)
    local mergeStatsBySkill = {}
    for _, skillMerge in ipairs(mergeStats) do
        mergeStatsBySkill[skillMerge.skillID] = skillMerge
    end

    local preloadedBySkill = type(preloadReport) == "table" and type(preloadReport.perSkill) == "table" and preloadReport.perSkill or {}
    local skillSummaries = {}
    local allSkills = core.stats and core.stats.Skill and core.stats.Skill.records

    if type(allSkills) == "table" then
        for _, skillRecord in pairs(allSkills) do
            local skillID = type(skillRecord) == "table" and skillRecord.id or skillRecord
            if type(skillID) == "string" and skillID ~= "" then
                local perkCount = 0
                for _, perkID in ipairs(registryState.getPerkIDs()) do
                    local perk = registryState.getPerks()[perkID]
                    if perk and perk.skill == skillID then
                        perkCount = perkCount + 1
                    end
                end

                local nodeCount = #treeRegistry.getTreeNodesForSkill(skillID)
                local mergeCount = 0
                local validationStatus = "ok"
                local mergeSkillStats = mergeStatsBySkill[skillID]
                if type(mergeSkillStats) == "table" then
                    mergeCount = mergeSkillStats.mergedFiles or 0
                    validationStatus = mergeSkillStats.validationStatus or "ok"
                end

                local preloadSkillStats = preloadedBySkill[skillID] or {}
                local moduleCount = preloadSkillStats.modulesLoaded or mergeCount
                local registeredPerks = preloadSkillStats.registeredPerks or perkCount
                local registeredNodes = preloadSkillStats.registeredNodes or nodeCount

                if perkCount > 0 or nodeCount > 0 or mergeCount > 0 then
                    table.insert(
                        skillSummaries,
                        skillID
                            .. "{modules="
                            .. tostring(moduleCount)
                            .. ",registered_perks="
                            .. tostring(registeredPerks)
                            .. ",registered_nodes="
                            .. tostring(registeredNodes)
                            .. ",total_perks="
                            .. tostring(perkCount)
                            .. ",total_nodes="
                            .. tostring(nodeCount)
                            .. ",merged_files="
                            .. tostring(mergeCount)
                            .. ",validation="
                            .. tostring(validationStatus)
                            .. "}"
                    )
                end
            end
        end
    end

    table.sort(skillSummaries)
    local effectCount = 0
    for _ in pairs(effectsRegistry.getEffects()) do
        effectCount = effectCount + 1
    end

    print(
        "["
            .. settings.MOD_NAME
            .. "] startup registry summary: skills="
            .. tostring(#skillSummaries)
            .. " effects="
            .. tostring(effectCount)
            .. " details=["
            .. table.concat(skillSummaries, ", ")
            .. "]"
    )
end

validateMergedTreeGraph()
buildStartupSummary()
buildPluginValidationSummary(pluginValidationReport)
buildPreloadSummary(preloadReport)

return {
    interfaceName = settings.MOD_NAME,
    interface = {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = registerPerk,
        registerTreeNode = registerTreeNode,
        registerPerkModule = registerPerkModule,
        registerEffect = registerEffect,
        registerPointSource = pluginAPI.registerPointSource,
        getPerks = getPerks,
        getPerkIDs = getPerkIDs,
        getPerkIDsForSkill = getPerkIDsForSkill,
        registerTreeNodes = treeRegistry.registerTreeNodes,
        getTreeNode = treeRegistry.getTreeNode,
        getTreeNodesForSkill = treeRegistry.getTreeNodesForSkill,
        loadSkillTree = treeRegistry.loadSkillTree,
    }
}
