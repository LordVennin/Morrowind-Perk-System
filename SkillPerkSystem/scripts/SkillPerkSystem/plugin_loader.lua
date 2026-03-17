local core = require("openmw.core")
local vfs = require("openmw.vfs")
local settings = require("scripts.SkillPerkSystem.settings")

local LOADER_TAG = "[SkillPerkSystem][plugin_loader] "
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"
local REQUIRED_PERK_MODULE_SCHEMA = "skillperks.vNext"

local function log(message)
    print(LOADER_TAG .. tostring(message))
end

local function logVerbose(message)
    if settings.PLUGIN_VALIDATION_VERBOSE then
        log(message)
    end
end

local function readLoaderTimeSeconds()
    local getSimulationTime = type(core) == "table" and core.getSimulationTime or nil
    if type(getSimulationTime) ~= "function" then
        return nil
    end

    local ok, timeSeconds = pcall(getSimulationTime)
    if not ok or type(timeSeconds) ~= "number" then
        return nil
    end

    return timeSeconds
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

local function sortStringsStable(values)
    table.sort(values, function(left, right)
        return left < right
    end)
end

local function discoverSkillPerkModules(packName, skillID)
    local folderPath = "scripts/" .. tostring(packName) .. "/perks/" .. tostring(skillID) .. "/"
    local modules = {}
    local seen = {}

    if type(vfs) ~= "table" or type(vfs.pathsWithPrefix) ~= "function" then
        return folderPath, modules
    end

    for path in vfs.pathsWithPrefix(folderPath) do
        if type(path) == "string" then
            local normalizedPath = path:gsub("\\", "/")
            local relativeFile = normalizedPath:match("^" .. folderPath:gsub("%-", "%%-") .. "([^/]+)%.lua$")
            if type(relativeFile) == "string" and relativeFile ~= "" and not seen[relativeFile] then
                seen[relativeFile] = true
                table.insert(modules, {
                    moduleName = "scripts." .. tostring(packName) .. ".perks." .. tostring(skillID) .. "." .. tostring(relativeFile),
                    moduleFile = tostring(relativeFile),
                    source = folderPath .. tostring(relativeFile) .. ".lua",
                })
            end
        end
    end

    table.sort(modules, function(left, right)
        if left.moduleFile ~= right.moduleFile then
            return left.moduleFile < right.moduleFile
        end
        return left.moduleName < right.moduleName
    end)

    return folderPath, modules
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
        registerPerkModule = function(data, expectedSkill)
            return pluginAPI.registerPerkModule(data, sourceName, expectedSkill)
        end,
        registerEffect = function(data)
            return pluginAPI.registerEffect(data, sourceName)
        end,
        registerPointSource = function(sourceId, handlers)
            return pluginAPI.registerPointSource(sourceId, handlers, sourceName)
        end,
    }
end

local function validateSkillModuleSchema(packReport, skillID, skillFolderPath, moduleName, moduleData)
    if type(moduleData) ~= "table" then
        return false,
            VALIDATION_ERROR_TAG
                .. ": strict schema validation failed: pack='"
                .. tostring(packReport.packName)
                .. "' skill_folder='"
                .. tostring(skillFolderPath)
                .. "' module='"
                .. tostring(moduleName)
                .. "' must return a table"
    end

    if moduleData.schema ~= REQUIRED_PERK_MODULE_SCHEMA then
        return false,
            VALIDATION_ERROR_TAG
                .. ": strict schema validation failed: pack='"
                .. tostring(packReport.packName)
                .. "' skill_folder='"
                .. tostring(skillFolderPath)
                .. "' module='"
                .. tostring(moduleName)
                .. "' missing required schema='"
                .. REQUIRED_PERK_MODULE_SCHEMA
                .. "'"
    end

    return true, nil
end

local function registerSkillModule(pluginAPI, skillID, moduleName, moduleData)
    local result = pluginAPI.registerPerkModule(moduleData, moduleName, skillID)
    if result == nil or result.skipped then
        logVerbose("skipped disabled skill module schema skill='" .. tostring(skillID) .. "' module='" .. tostring(moduleName) .. "'")
    else
        log("registered skill module schema for skill='" .. tostring(skillID) .. "' module='" .. tostring(moduleName) .. "' perks=" .. tostring(result.perks or 0) .. " nodes=" .. tostring(result.nodes or 0))
    end
    return true
end

local function tryRegisterSkillModule(pluginAPI, packReport, skillID, skillFolderPath, moduleName, moduleData)
    local schemaValid, schemaErr = validateSkillModuleSchema(packReport, skillID, skillFolderPath, moduleName, moduleData)
    if not schemaValid then
        appendFailure(packReport, moduleName, schemaErr)
        log("strict schema validation failed: pack='" .. tostring(packReport.packName) .. "' skill_folder='" .. tostring(skillFolderPath) .. "' module='" .. tostring(moduleName) .. "'")
        return false
    end

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
        local skillFolderPath, discoveredModules = discoverSkillPerkModules(packName, skillID)
        local skillModuleStats = {
            skillID = skillID,
            discovered = #discoveredModules,
            attempted = #discoveredModules,
            loaded = 0,
            failed = 0,
            variant = #discoveredModules > 0 and "multi-file" or "none",
        }

        for _, discoveredModule in ipairs(discoveredModules) do
            local loadedModule = tryRequire(packName, discoveredModule.moduleName, report)
            if loadedModule then
                skillModuleStats.loaded = skillModuleStats.loaded + 1
            else
                skillModuleStats.failed = skillModuleStats.failed + 1
            end
        end

        if skillModuleStats.discovered > 0 then
            table.insert(report.perkSkillModules, skillModuleStats)
        end

        log(
            "pack='"
                .. packName
                .. "' skill='"
                .. tostring(skillID)
                .. "' variant='"
                .. tostring(skillModuleStats.variant)
                .. "' perk_modules_discovered="
                .. tostring(skillModuleStats.discovered)
                .. " perk_modules_loaded="
                .. tostring(skillModuleStats.loaded)
                .. " perk_modules_failed="
                .. tostring(skillModuleStats.failed)
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
local hasPreloadedSkillModules = false
local preloadReport = nil

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

local function extractSkillModuleName(packName, moduleName)
    local prefix = "scripts." .. packName .. ".perks."
    if type(moduleName) ~= "string" or moduleName:sub(1, #prefix) ~= prefix then
        return nil, nil
    end

    local suffix = moduleName:sub(#prefix + 1)
    if suffix == "" then
        return nil, nil
    end

    local skillID = suffix:match("^([^.]+)%..+")
    if type(skillID) ~= "string" or skillID == "" then
        return nil, nil
    end

    local moduleFile = suffix:match("^[^.]+%.(.+)$")
    if type(moduleFile) ~= "string" or moduleFile == "" then
        return nil, nil
    end

    return skillID, moduleFile
end

local function sortDiscoveredPerkModules(modules)
    table.sort(modules, function(left, right)
        if left.skillID ~= right.skillID then
            return left.skillID < right.skillID
        end
        if left.moduleFile ~= right.moduleFile then
            return left.moduleFile < right.moduleFile
        end
        return left.moduleName < right.moduleName
    end)
end

local function preloadPerkModules(pluginAPI)
    if hasPreloadedSkillModules then
        return preloadReport
    end
    hasPreloadedSkillModules = true

    local timingUnavailableLogged = false
    local function logTimingUnavailableOnce()
        if not timingUnavailableLogged then
            timingUnavailableLogged = true
            log("timing unavailable in this runtime")
        end
    end

    local startTimeSeconds = readLoaderTimeSeconds()
    if startTimeSeconds == nil then
        logTimingUnavailableOnce()
    end

    local validationReport = loadInstalledPacks(pluginAPI)
    local report = {
        packsScanned = 0,
        modulesDiscovered = 0,
        modulesLoaded = 0,
        modulesFailed = 0,
        durationMs = 0,
    }
    preloadReport = report

    for _, packReport in ipairs(validationReport.packs or {}) do
        report.packsScanned = report.packsScanned + 1
        local seen = {}
        local discoveredModules = {}

        for _, moduleAttempt in ipairs(packReport.moduleAttempts or {}) do
            local skillID, moduleFile = extractSkillModuleName(packReport.packName, moduleAttempt.module)
            if skillID ~= nil and moduleFile ~= nil and not seen[moduleAttempt.module] then
                seen[moduleAttempt.module] = true
                table.insert(discoveredModules, {
                    skillID = skillID,
                    moduleFile = moduleFile,
                    moduleName = moduleAttempt.module,
                    attempt = moduleAttempt,
                })
            end
        end

        sortDiscoveredPerkModules(discoveredModules)

        local perSkillSummaries = {}
        for _, moduleInfo in ipairs(discoveredModules) do
            if perSkillSummaries[moduleInfo.skillID] == nil then
                perSkillSummaries[moduleInfo.skillID] = {
                    discovered = 0,
                    loaded = 0,
                    failed = 0,
                }
            end

            local skillSummary = perSkillSummaries[moduleInfo.skillID]
            skillSummary.discovered = skillSummary.discovered + 1
            report.modulesDiscovered = report.modulesDiscovered + 1

            local registered = false
            if moduleInfo.attempt.success then
                local ok, moduleData = pcall(require, moduleInfo.moduleName)
                local skillFolderPath =
                    "scripts/" .. tostring(packReport.packName) .. "/perks/" .. tostring(moduleInfo.skillID)
                local moduleSource = skillFolderPath .. "/" .. tostring(moduleInfo.moduleFile) .. ".lua"
                registered = ok and tryRegisterSkillModule(
                    pluginAPI,
                    packReport,
                    moduleInfo.skillID,
                    skillFolderPath,
                    moduleSource,
                    moduleData
                )
            end

            if registered then
                report.modulesLoaded = report.modulesLoaded + 1
                skillSummary.loaded = skillSummary.loaded + 1
            else
                report.modulesFailed = report.modulesFailed + 1
                skillSummary.failed = skillSummary.failed + 1
            end
        end

        local sortedSkillIDs = {}
        for skillID in pairs(perSkillSummaries) do
            table.insert(sortedSkillIDs, skillID)
        end
        sortStringsStable(sortedSkillIDs)

        for _, skillID in ipairs(sortedSkillIDs) do
            local skillSummary = perSkillSummaries[skillID]
            log(
                "pack='"
                    .. tostring(packReport.packName)
                    .. "' skill='"
                    .. tostring(skillID)
                    .. "' perk_files_discovered="
                    .. tostring(skillSummary.discovered)
                    .. " perk_files_loaded="
                    .. tostring(skillSummary.loaded)
                    .. " perk_files_failed="
                    .. tostring(skillSummary.failed)
            )
        end
    end

    local summary =
        "preload summary: packs_scanned="
        .. tostring(report.packsScanned)
        .. " modules_discovered="
        .. tostring(report.modulesDiscovered)
        .. " modules_loaded="
        .. tostring(report.modulesLoaded)
        .. " modules_failed="
        .. tostring(report.modulesFailed)

    if startTimeSeconds ~= nil then
        local endTimeSeconds = readLoaderTimeSeconds()
        if endTimeSeconds ~= nil then
            report.durationMs = math.floor((endTimeSeconds - startTimeSeconds) * 1000 + 0.5)
            summary = summary .. " duration_ms=" .. tostring(report.durationMs)
        else
            logTimingUnavailableOnce()
        end
    end

    log(summary)

    return report
end

return {
    loadInstalledPacks = loadInstalledPacks,
    preloadPerkModules = preloadPerkModules,
}
