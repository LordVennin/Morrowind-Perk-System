local core = require("openmw.core")
local settings = require("scripts.SkillPerkSystem.settings")

local LOADER_TAG = "[SkillPerkSystem][plugin_loader] "
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

local function log(message)
    print(LOADER_TAG .. tostring(message))
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

local function tryRequire(packName, moduleName, packReport)
    local ok, resultOrErr = pcall(require, moduleName)
    if ok then
        log("loaded pack='" .. packName .. "' module='" .. moduleName .. "'")
        packReport.modulesLoadedCount = packReport.modulesLoadedCount + 1
        return true, resultOrErr
    end

    log("failed pack='" .. packName .. "' module='" .. moduleName .. "' error='" .. tostring(resultOrErr) .. "'")
    appendFailure(packReport, moduleName, resultOrErr)
    return false, nil
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
            log("executed manifest register() for pack='" .. packName .. "'")
        else
            packReport.manifest.registerSuccess = false
            packReport.manifest.registerError = compactReason(err)
            appendFailure(packReport, manifestPath, err)
            log("manifest register() failed for pack='" .. packName .. "' error='" .. tostring(err) .. "'")
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
        modulesLoadedCount = 0,
        moduleFailures = {},
    }

    local loadedManifest, manifestModule = tryRequire(packName, report.manifest.path, report)
    report.manifest.found = loadedManifest
    if loadedManifest then
        runManifest(packName, manifestModule, pluginAPI, report.manifest.path, report)
    end

    for _, skillID in ipairs(skillIDs) do
        tryRequire(packName, "scripts." .. packName .. ".perks." .. skillID, report)
    end

    for _, effectID in ipairs(effectIDs) do
        tryRequire(packName, "scripts." .. packName .. ".effects." .. effectID, report)
    end

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
                    .. "' manifest="
                    .. tostring(packReport.manifest.found)
                    .. " register="
                    .. tostring(packReport.manifest.registerSuccess)
                    .. " modulesLoaded="
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
