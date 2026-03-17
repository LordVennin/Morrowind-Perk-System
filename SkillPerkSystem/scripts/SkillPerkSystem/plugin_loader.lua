local core = require("openmw.core")

local LOADER_TAG = "[SkillPerkSystem][plugin_loader] "

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

local function tryRequire(packName, moduleName)
    local ok, resultOrErr = pcall(require, moduleName)
    if ok then
        log("loaded pack='" .. packName .. "' module='" .. moduleName .. "'")
        return true, resultOrErr
    end

    log("failed pack='" .. packName .. "' module='" .. moduleName .. "' error='" .. tostring(resultOrErr) .. "'")
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
        registerPointSource = pluginAPI.registerPointSource,
    }
end

local function runManifest(packName, manifestModule, pluginAPI, manifestPath)
    if type(manifestModule) ~= "table" then
        return
    end

    if type(manifestModule.register) == "function" then
        local sourceAwareAPI = buildSourceAwarePluginAPI(pluginAPI, manifestPath)
        local ok, err = pcall(manifestModule.register, sourceAwareAPI)
        if ok then
            log("executed manifest register() for pack='" .. packName .. "'")
        else
            log("manifest register() failed for pack='" .. packName .. "' error='" .. tostring(err) .. "'")
        end
    end

    if type(manifestModule.modules) == "table" then
        for _, moduleName in ipairs(manifestModule.modules) do
            if type(moduleName) == "string" and moduleName ~= "" then
                tryRequire(packName, moduleName)
            end
        end
    end
end

local function loadPack(packName, skillIDs, effectIDs, pluginAPI)
    local manifestPath = "scripts." .. packName .. ".skillperk_manifest"
    local loadedManifest, manifestModule = tryRequire(packName, manifestPath)
    if loadedManifest then
        runManifest(packName, manifestModule, pluginAPI, manifestPath)
    end

    for _, skillID in ipairs(skillIDs) do
        tryRequire(packName, "scripts." .. packName .. ".perks." .. skillID)
    end

    for _, effectID in ipairs(effectIDs) do
        tryRequire(packName, "scripts." .. packName .. ".effects." .. effectID)
    end
end

local hasLoaded = false

local function loadInstalledPacks(pluginAPI)
    if hasLoaded then
        return
    end
    hasLoaded = true

    local packs = getDetectedPackNames()
    if #packs == 0 then
        log("no content files detected; skipping plugin discovery")
        return
    end

    local skillIDs = getRecordIDs(core.stats and core.stats.Skill and core.stats.Skill.records)
    local effectIDs = getRecordIDs(
        (core.magic and core.magic.Effect and core.magic.Effect.records)
            or (core.magic and core.magic.MagicEffect and core.magic.MagicEffect.records)
    )

    for _, packName in ipairs(packs) do
        loadPack(packName, skillIDs, effectIDs, pluginAPI)
    end
end

return {
    loadInstalledPacks = loadInstalledPacks,
}
