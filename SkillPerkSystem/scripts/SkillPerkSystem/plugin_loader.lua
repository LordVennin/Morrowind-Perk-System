local core = require("openmw.core")
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
        }

        local basePerkModule = "scripts." .. packName .. ".perks." .. skillID
        local loadedBase = tryRequireOptional(packName, basePerkModule, report)
        skillModuleStats.attempted = skillModuleStats.attempted + 1
        if loadedBase then
            skillModuleStats.loaded = skillModuleStats.loaded + 1
        end

        local namespacedModules = discoverSubmodules(basePerkModule .. ".")
        for _, moduleName in ipairs(namespacedModules) do
            local loadedNested = tryRequire(packName, moduleName, report)
            skillModuleStats.attempted = skillModuleStats.attempted + 1
            if loadedNested then
                skillModuleStats.loaded = skillModuleStats.loaded + 1
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
