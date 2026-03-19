local settings = require("scripts.SkillPerkSystem.settings")

local LOADER_TAG = "[SkillPerkSystem][pack_registry] "

local state = {
    packs = {},
    packOrder = {},
    frameworkStartLogged = false,
}

local function log(message)
    print(LOADER_TAG .. tostring(message))
end

local function inferPackName(source)
    if type(source) ~= "string" then
        return "unknown"
    end

    local packName = source:match("^scripts%.([^.]+)%.")
    if packName ~= nil and packName ~= "" then
        return packName
    end

    if source == "scripts.SkillPerkSystem.manifest" then
        return settings.MOD_NAME
    end

    return "unknown"
end

local function ensurePack(packName)
    local resolved = packName or "unknown"
    local pack = state.packs[resolved]
    if pack ~= nil then
        return pack
    end

    pack = {
        packName = resolved,
        modules = 0,
        perks = 0,
        nodes = 0,
        effects = 0,
        pointSources = 0,
    }
    state.packs[resolved] = pack
    table.insert(state.packOrder, resolved)
    return pack
end

local function beginFramework()
    if state.frameworkStartLogged then
        return
    end

    state.frameworkStartLogged = true
    log("framework started in explicit content-pack registration mode")
end

local function beginPackRegistration(packName)
    local pack = ensurePack(packName)
    if pack.started then
        return false
    end

    pack.started = true
    log("registering pack " .. tostring(pack.packName))
    return true
end

local function noteRegistration(kind, source, amount)
    local pack = ensurePack(inferPackName(source))
    local key = tostring(kind)
    if pack[key] == nil then
        pack[key] = 0
    end
    pack[key] = pack[key] + (tonumber(amount) or 1)
end

local function completePackRegistration(packName)
    local pack = ensurePack(packName)
    log(
        "registered pack "
            .. tostring(pack.packName)
            .. " modules="
            .. tostring(pack.modules)
            .. " perks="
            .. tostring(pack.perks)
            .. " nodes="
            .. tostring(pack.nodes)
            .. " effects="
            .. tostring(pack.effects)
    )
end

local function getSummary()
    local summary = {
        packs = {},
        totals = {
            packs = 0,
            modules = 0,
            perks = 0,
            nodes = 0,
            effects = 0,
            pointSources = 0,
        },
    }

    for _, packName in ipairs(state.packOrder) do
        local pack = state.packs[packName]
        if pack ~= nil then
            table.insert(summary.packs, pack)
            summary.totals.packs = summary.totals.packs + 1
            summary.totals.modules = summary.totals.modules + (pack.modules or 0)
            summary.totals.perks = summary.totals.perks + (pack.perks or 0)
            summary.totals.nodes = summary.totals.nodes + (pack.nodes or 0)
            summary.totals.effects = summary.totals.effects + (pack.effects or 0)
            summary.totals.pointSources = summary.totals.pointSources + (pack.pointSources or 0)
        end
    end

    return summary
end

return {
    beginFramework = beginFramework,
    beginPackRegistration = beginPackRegistration,
    noteRegistration = noteRegistration,
    completePackRegistration = completePackRegistration,
    getSummary = getSummary,
}
