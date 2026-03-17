local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local settings = require("scripts.SkillPerkSystem.settings")

local LOADER_TAG = "[SkillPerkSystem][plugin_loader] "
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

local function log(message)
    print(LOADER_TAG .. tostring(message))
end

local function logVerbose(message)
    if settings.PLUGIN_VALIDATION_VERBOSE then
        log(message)
    end
end

local function pushUnique(list, seen, value)
    if type(value) == "string" and value ~= "" and not seen[value] then
        seen[value] = true
        table.insert(list, value)
    end
end

local function getNameVariants(rawName)
    local variants = {}
    local seen = {}

    pushUnique(variants, seen, rawName)
    pushUnique(variants, seen, rawName:gsub("%s+", ""))
    pushUnique(variants, seen, rawName:gsub("%s+", "_"))
    pushUnique(variants, seen, rawName:gsub("%-", "_"))

    return variants
end

local function getDetectedPackNames()
    local packs = {}
    local seen = {}

    local contentFiles = core.contentFiles
    if type(contentFiles) ~= "table" then
        return packs
    end

    for _, contentFile in ipairs(contentFiles) do
        if type(contentFile) == "string" then
            local fileName = contentFile:match("([^/\\]+)$") or contentFile
            local packName = fileName:gsub("%.[^%.]+$", "")
            for _, candidate in ipairs(getNameVariants(packName)) do
                pushUnique(packs, seen, candidate)
            end
        end
    end

    return packs
end

local function getRecordIDs(records)
    local ids = {}
    local seen = {}

    if type(records) ~= "table" then
        return ids
    end

    for key, record in pairs(records) do
        if type(key) == "string" then
            pushUnique(ids, seen, key)
        end
        if type(record) == "table" and type(record.id) == "string" then
            pushUnique(ids, seen, record.id)
        end
    end

    return ids
end

local function compactReason(err)
    local full = tostring(err)
    local reason = full:match(":%d+:%s*(.*)$") or full
    if reason == "" then
        reason = full
    end
    return reason
end

local function classifyFailure(err)
    local full = tostring(err)
    if full:find(VALIDATION_ERROR_TAG, 1, true) then
        return "validation"
    end
    return "runtime"
end

local function appendFailure(packReport, moduleName, err)
    local reason = compactReason(err)
    table.insert(packReport.moduleFailures, {
        module = moduleName,
        reason = reason,
        class = classifyFailure(err),
    })
end

local function appendModuleAttempt(packReport, moduleName, ok, err)
    table.insert(packReport.moduleAttempts, {
        module = moduleName,
        success = ok,
        reason = ok and nil or compactReason(err),
    })
end

local function isModuleNotFoundError(err, moduleName)
    local full = tostring(err)
    return full:find("module '" .. moduleName .. "' not found", 1, true) ~= nil
end

local function tryRequire(packName, moduleName, packReport)
    packReport.modulesAttemptedCount = packReport.modulesAttemptedCount + 1
    local ok, resultOrErr = pcall(require, moduleName)
    appendModuleAttempt(packReport, moduleName, ok, resultOrErr)

    if ok then
        packReport.modulesLoadedCount = packReport.modulesLoadedCount + 1
        logVerbose("loaded pack='" .. packName .. "' module='" .. moduleName .. "'")
        return true, resultOrErr
    end

    appendFailure(packReport, moduleName, resultOrErr)
    logVerbose("failed pack='" .. packName .. "' module='" .. moduleName .. "' error='" .. tostring(resultOrErr) .. "'")
    return false, nil
end

local function tryRequireOptional(packName, moduleName, packReport)
    packReport.modulesAttemptedCount = packReport.modulesAttemptedCount + 1
    local ok, resultOrErr = pcall(require, moduleName)
    appendModuleAttempt(packReport, moduleName, ok, resultOrErr)

    if ok then
        packReport.modulesLoadedCount = packReport.modulesLoadedCount + 1
        logVerbose("loaded pack='" .. packName .. "' module='" .. moduleName .. "'")
        return true, resultOrErr
    end

    if isModuleNotFoundError(resultOrErr, moduleName) then
        logVerbose("optional module missing pack='" .. packName .. "' module='" .. moduleName .. "'")
        return false, nil
    end

    appendFailure(packReport, moduleName, resultOrErr)
    logVerbose("failed pack='" .. packName .. "' module='" .. moduleName .. "' error='" .. tostring(resultOrErr) .. "'")
    return false, nil
end

local function loadSkillFolderModuleSet(packName, pluginAPI, packReport, skillID, basePerkModule, skillModuleStats)
    local listModule = basePerkModule .. ".modules"
    local listFound, listModuleData = tryRequireOptional(packName, listModule, packReport)
    skillModuleStats.attempted = skillModuleStats.attempted + 1
    if not listFound then
        return {
            found = false,
            loaded = 0,
            registered = 0,
        }
    end

    if type(listModuleData) ~= "table" then
        appendFailure(
            packReport,
            listModule,
            VALIDATION_ERROR_TAG
                .. ": skill folder module list must return a table for skill '"
                .. tostring(skillID)
                .. "'"
        )
        return {
            found = true,
            loaded = 0,
            registered = 0,
        }
    end

    local loaded = 0
    local registered = 0
    for i, moduleSuffix in ipairs(listModuleData) do
        if type(moduleSuffix) ~= "string" or moduleSuffix == "" then
            appendFailure(
                packReport,
                listModule,
                VALIDATION_ERROR_TAG
                    .. ": skill folder module list entry #"
                    .. tostring(i)
                    .. " must be a non-empty string for skill '"
                    .. tostring(skillID)
                    .. "'"
            )
        else
            local moduleName = basePerkModule .. "." .. moduleSuffix
            local loadedNested, nestedModuleData = tryRequire(packName, moduleName, packReport)
            skillModuleStats.attempted = skillModuleStats.attempted + 1
            if loadedNested then
                loaded = loaded + 1
                skillModuleStats.loaded = skillModuleStats.loaded + 1
                if tryRegisterSkillModule(pluginAPI, packReport, skillID, moduleName, nestedModuleData) then
                    registered = registered + 1
                end
            end
        end
    end

    return {
        found = true,
        loaded = loaded,
        registered = registered,
    }
end

local function discoverSubmodules(modulePrefix)
    local out = {}
    local seen = {}

    local function collectFrom(source)
        if type(source) ~= "table" then
            return
        end
        for moduleName, _ in pairs(source) do
            if type(moduleName) == "string" and moduleName:find(modulePrefix, 1, true) == 1 then
                local suffix = moduleName:sub(#modulePrefix + 1)
                if suffix ~= "" and not seen[moduleName] then
                    seen[moduleName] = true
                    table.insert(out, moduleName)
                end
            end
        end
    end

    collectFrom(package.preload)
    collectFrom(package.loaded)

    table.sort(out)
    return out
end

local function buildSourceAwarePluginAPI(pluginAPI, sourceName)
    return {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = function(data)
            return pluginAPI.registerPerk(data, sourceName)
        end,
        registerTreeNode = function(data)
            return pluginAPI.registerTreeNode(data, sourceName)
        end,
        registerEffect = function(data)
            return pluginAPI.registerEffect(data, sourceName)
        end,
        registerPointSource = function(sourceId, handlers)
            return pluginAPI.registerPointSource(sourceId, handlers, sourceName)
        end,
    }
end

local function buildRequirement(parentID)
    return {
        check = function()
            local playerInterface = interfaces[settings.MOD_NAME .. "Player"]
            return playerInterface ~= nil and playerInterface.hasPerk(parentID)
        end,
    }
end

local function normalizePerkDefinition(perk)
    local normalized = {
        id = perk.id,
        skill = perk.skill,
        effectId = perk.effectId,
        cost = perk.cost,
        requirements = perk.requirements,
    }

    if normalized.requirements == nil then
        normalized.requirements = {}
        for _, parentID in ipairs(perk.requires or {}) do
            table.insert(normalized.requirements, buildRequirement(parentID))
        end
    end

    return normalized
end

local function deriveNodeFromPerk(perk, sourceName)
    local hasEmbeddedNode = type(perk.node) == "table"
    local hasInlineNodeFields = type(perk.x) == "number" or type(perk.y) == "number" or perk.title ~= nil or perk.description ~= nil

    if not hasEmbeddedNode and not hasInlineNodeFields then
        return nil
    end

    if hasEmbeddedNode and hasInlineNodeFields then
        error(
            VALIDATION_ERROR_TAG
                .. ": skill module '"
                .. tostring(sourceName)
                .. "' perk '"
                .. tostring(perk.id)
                .. "' cannot define both node table and inline node fields"
        )
    end

    local nodeData = hasEmbeddedNode and perk.node or perk
    local nodeID = nodeData.id or nodeData.nodeId or nodeData.nodeID or perk.nodeId or perk.nodeID or perk.id
    return {
        id = nodeID,
        skill = nodeData.skill or perk.skill,
        x = nodeData.x,
        y = nodeData.y,
        requires = nodeData.requires,
        title = nodeData.title,
        description = nodeData.description,
    }, nodeData.perkId or nodeData.perkID or perk.perkId or perk.perkID or perk.id
end

local function registerSkillModule(pluginAPI, skillID, moduleName, moduleData)
    if type(moduleData) ~= "table" then
        return false
    end

    if moduleData.enabled ~= nil then
        local enabled = moduleData.enabled
        if type(enabled) == "function" then
            enabled = enabled()
        end
        if not enabled then
            logVerbose("skipped disabled skill module schema skill='" .. tostring(skillID) .. "' module='" .. tostring(moduleName) .. "'")
            return true
        end
    end

    local perks = moduleData.perks
    local nodes = moduleData.nodes
    if type(perks) ~= "table" and type(nodes) ~= "table" then
        return false
    end

    local sourceAwareAPI = buildSourceAwarePluginAPI(pluginAPI, moduleName)
    local perkIds = {}
    local hasPerkEntries = false

    if type(perks) == "table" then
        for i, perk in ipairs(perks) do
            if type(perk) ~= "table" then
                error(
                    VALIDATION_ERROR_TAG
                        .. ": skill module '"
                        .. tostring(moduleName)
                        .. "' perks["
                        .. tostring(i)
                        .. "] must be a table"
                )
            end
            if type(perk.skill) == "string" and perk.skill ~= "" and perk.skill ~= skillID then
                error(
                    VALIDATION_ERROR_TAG
                        .. ": skill module '"
                        .. tostring(moduleName)
                        .. "' perk '"
                        .. tostring(perk.id)
                        .. "' declares skill '"
                        .. tostring(perk.skill)
                        .. "' but module was loaded for skill '"
                        .. tostring(skillID)
                        .. "'"
                )
            end
            sourceAwareAPI.registerPerk(normalizePerkDefinition(perk))
            perkIds[perk.id] = true
            hasPerkEntries = true

            local derivedNode, mappedPerkID = deriveNodeFromPerk(perk, moduleName)
            if derivedNode ~= nil then
                if mappedPerkID ~= nil and mappedPerkID ~= "" and mappedPerkID ~= perk.id then
                    error(
                        VALIDATION_ERROR_TAG
                            .. ": skill module '"
                            .. tostring(moduleName)
                            .. "' perk '"
                            .. tostring(perk.id)
                            .. "' derived node mapped to unexpected perk id '"
                            .. tostring(mappedPerkID)
                            .. "'"
                    )
                end
                sourceAwareAPI.registerTreeNode(derivedNode)
            end
        end
    end

    if type(nodes) == "table" then
        for i, node in ipairs(nodes) do
            if type(node) ~= "table" then
                error(
                    VALIDATION_ERROR_TAG
                        .. ": skill module '"
                        .. tostring(moduleName)
                        .. "' nodes["
                        .. tostring(i)
                        .. "] must be a table"
                )
            end
            if type(node.skill) == "string" and node.skill ~= "" and node.skill ~= skillID then
                error(
                    VALIDATION_ERROR_TAG
                        .. ": skill module '"
                        .. tostring(moduleName)
                        .. "' node '"
                        .. tostring(node.id)
                        .. "' declares skill '"
                        .. tostring(node.skill)
                        .. "' but module was loaded for skill '"
                        .. tostring(skillID)
                        .. "'"
                )
            end

            local mappedPerkID = node.perkId or node.perkID or node.id
            if hasPerkEntries and mappedPerkID ~= nil and mappedPerkID ~= "" and not perkIds[mappedPerkID] then
                error(
                    VALIDATION_ERROR_TAG
                        .. ": skill module '"
                        .. tostring(moduleName)
                        .. "' node '"
                        .. tostring(node.id)
                        .. "' maps to missing perk id '"
                        .. tostring(mappedPerkID)
                        .. "'"
                )
            end

            sourceAwareAPI.registerTreeNode(node)
        end
    end

    if type(perks) == "table" and type(nodes) == "table" then
        for _, node in ipairs(nodes) do
            local mappedPerkID = node.perkId or node.perkID or node.id
            if mappedPerkID ~= nil and mappedPerkID ~= "" and mappedPerkID ~= node.id then
                log(
                    "warning: skill module='"
                        .. tostring(moduleName)
                        .. "' node id='"
                        .. tostring(node.id)
                        .. "' mapped to perk id='"
                        .. tostring(mappedPerkID)
                        .. "'"
                )
            end
        end
    end

    log("registered skill module schema for skill='" .. tostring(skillID) .. "' module='" .. tostring(moduleName) .. "'")
    return true
end

local function tryRegisterSkillModule(pluginAPI, packReport, skillID, moduleName, moduleData)
    local ok, usedSchemaOrErr = pcall(registerSkillModule, pluginAPI, skillID, moduleName, moduleData)
    if not ok then
        appendFailure(packReport, moduleName, usedSchemaOrErr)
        logVerbose(
            "skill module schema failed pack='"
                .. tostring(packReport.packName)
                .. "' skill='"
                .. tostring(skillID)
                .. "' module='"
                .. tostring(moduleName)
                .. "' error='"
                .. tostring(usedSchemaOrErr)
                .. "'"
        )
        return false
    end

    return usedSchemaOrErr == true
end

local function runManifest(packName, manifestModule, pluginAPI, manifestPath, packReport)
    if type(manifestModule) ~= "table" then
        return
    end

    if type(manifestModule.register) == "function" then
        local sourceAwareAPI = buildSourceAwarePluginAPI(pluginAPI, manifestPath)
        local ok, err = pcall(manifestModule.register, sourceAwareAPI)
        packReport.manifest.registerAttempted = true
        if ok then
            packReport.manifest.registerSuccess = true
            logVerbose("executed manifest register() for pack='" .. packName .. "'")
        else
            packReport.manifest.registerSuccess = false
            packReport.manifest.registerError = compactReason(err)
            appendFailure(packReport, manifestPath, err)
            logVerbose("manifest register() failed for pack='" .. packName .. "' error='" .. tostring(err) .. "'")
        end
    end

    if type(manifestModule.modules) == "table" then
        for _, moduleName in ipairs(manifestModule.modules) do
            if type(moduleName) == "string" and moduleName ~= "" then
                tryRequire(packName, moduleName, packReport)
            end
        end
    end
end

local function finalizePackStatus(packReport)
    if not packReport.manifest.found then
        packReport.status = "skipped"
        packReport.reason = "manifest missing"
        return
    end

    if packReport.manifest.registerAttempted and packReport.manifest.registerSuccess == false then
        packReport.status = "failed"
        packReport.reason = "manifest register failed: " .. tostring(packReport.manifest.registerError)
        return
    end

    if #packReport.moduleFailures > 0 then
        local firstFailure = packReport.moduleFailures[1]
        packReport.status = "failed"
        packReport.reason = "module load failed: " .. tostring(firstFailure.module) .. " - " .. tostring(firstFailure.reason)
        return
    end

    packReport.status = "loaded"
    packReport.reason = "ok"
end

local function loadPack(packName, skillIDs, effectIDs, pluginAPI)
    local report = {
        packName = packName,
        manifest = {
            path = "scripts." .. packName .. ".skillperk_manifest",
            found = false,
            registerAttempted = false,
            registerSuccess = nil,
            registerError = nil,
        },
        modulesAttemptedCount = 0,
        modulesLoadedCount = 0,
        moduleAttempts = {},
        moduleFailures = {},
        perkSkillModules = {},
        status = "unknown",
        reason = nil,
    }

    local loadedManifest, manifestModule = tryRequire(packName, report.manifest.path, report)
    report.manifest.found = loadedManifest
    if loadedManifest then
        runManifest(packName, manifestModule, pluginAPI, report.manifest.path, report)
    end

    for _, skillID in ipairs(skillIDs) do
        local skillModuleStats = {
            skillID = skillID,
            attempted = 0,
            loaded = 0,
            variant = "none",
        }

        -- Primary convention: one module per skill at scripts.<PackName>.perks.<skillId>
        local basePerkModule = "scripts." .. packName .. ".perks." .. skillID
        local loadedBase, baseModuleData = tryRequireOptional(packName, basePerkModule, report)
        skillModuleStats.attempted = skillModuleStats.attempted + 1
        local usedPrimarySkillModule = false
        local folderModuleSetResult = loadSkillFolderModuleSet(packName, pluginAPI, report, skillID, basePerkModule, skillModuleStats)
        if loadedBase then
            skillModuleStats.loaded = skillModuleStats.loaded + 1
            usedPrimarySkillModule = tryRegisterSkillModule(pluginAPI, report, skillID, basePerkModule, baseModuleData)
        end

        if usedPrimarySkillModule then
            skillModuleStats.variant = "single-file"
            if folderModuleSetResult.found then
                log(
                    "pack='"
                        .. packName
                        .. "' skill='"
                        .. tostring(skillID)
                        .. "' found both skill module variants (single-file + folder-module-set); precedence=single-file"
                )
            end
        elseif folderModuleSetResult.found then
            if loadedBase then
                log(
                    "pack='"
                        .. packName
                        .. "' skill='"
                        .. tostring(skillID)
                        .. "' found both skill module variants (single-file + folder-module-set); single-file missing schema so folder-module-set used"
                )
            end

            if folderModuleSetResult.loaded > 0 then
                skillModuleStats.variant = "folder-module-set"
            end
        else
            local namespacedModules = discoverSubmodules(basePerkModule .. ".")
            for _, moduleName in ipairs(namespacedModules) do
                local loadedNested, nestedModuleData = tryRequire(packName, moduleName, report)
                skillModuleStats.attempted = skillModuleStats.attempted + 1
                if loadedNested then
                    skillModuleStats.loaded = skillModuleStats.loaded + 1
                    if tryRegisterSkillModule(pluginAPI, report, skillID, moduleName, nestedModuleData) then
                        skillModuleStats.variant = "legacy-nested"
                    end
                end
            end
        end

        if skillModuleStats.attempted > 0 and skillModuleStats.loaded > 0 then
            table.insert(report.perkSkillModules, skillModuleStats)
        end

        log(
            "pack='"
                .. packName
                .. "' skill='"
                .. tostring(skillID)
                .. "' variant='"
                .. tostring(skillModuleStats.variant)
                .. "' perk_modules_loaded="
                .. tostring(skillModuleStats.loaded)
                .. " perk_modules_attempted="
                .. tostring(skillModuleStats.attempted)
        )
    end

    for _, effectID in ipairs(effectIDs) do
        tryRequire(packName, "scripts." .. packName .. ".effects." .. effectID, report)
    end

    finalizePackStatus(report)
    return report
end

local hasLoaded = false
local lastReport = nil

local function loadInstalledPacks(pluginAPI)
    if hasLoaded then
        return lastReport
    end
    hasLoaded = true

    local packs = getDetectedPackNames()
    local report = {
        totalPacksDetected = #packs,
        packs = {},
    }
    lastReport = report

    if #packs == 0 then
        log("no content files detected; skipping plugin discovery")
        return report
    end

    local skillIDs = getRecordIDs(core.stats and core.stats.Skill and core.stats.Skill.records)
    local effectIDs = getRecordIDs(
        (core.magic and core.magic.Effect and core.magic.Effect.records)
            or (core.magic and core.magic.MagicEffect and core.magic.MagicEffect.records)
    )

    for _, packName in ipairs(packs) do
        table.insert(report.packs, loadPack(packName, skillIDs, effectIDs, pluginAPI))
    end

    if settings.PLUGIN_VALIDATION_VERBOSE then
        for _, packReport in ipairs(report.packs) do
            log(
                "report pack='"
                    .. packReport.packName
                    .. "' status="
                    .. tostring(packReport.status)
                    .. " reason='"
                    .. tostring(packReport.reason)
                    .. "' manifest="
                    .. tostring(packReport.manifest.found)
                    .. " register="
                    .. tostring(packReport.manifest.registerSuccess)
                    .. " modules_attempted="
                    .. tostring(packReport.modulesAttemptedCount)
                    .. " modules_loaded="
                    .. tostring(packReport.modulesLoadedCount)
                    .. " failures="
                    .. tostring(#packReport.moduleFailures)
            )
        end
    end

    return report
end

return {
    loadInstalledPacks = loadInstalledPacks,
}
