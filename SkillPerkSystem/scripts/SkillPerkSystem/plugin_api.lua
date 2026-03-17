local core = require("openmw.core")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local settings = require("scripts.SkillPerkSystem.settings")

local PLUGIN_API_VERSION = 1
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

local function validationError(message, level)
    error(VALIDATION_ERROR_TAG .. ": " .. tostring(message), level or 2)
end

local function normalizeSource(source)
    if type(source) ~= "string" or source == "" then
        return "unknown"
    end
    return source
end

local function duplicatePolicyLabel()
    if settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE then
        return "override(last-write-wins)"
    end
    return "strict(error)"
end

local function hasSkillRecord(skillID)
    if core.stats.Skill.records[skillID] ~= nil then
        return true
    end
    for _, record in ipairs(core.stats.Skill.records) do
        if record.id == skillID then
            return true
        end
    end
    return false
end

local function assertCompatibleApiVersion(expectedVersion)
    if expectedVersion == nil then
        return true
    end
    if type(expectedVersion) ~= "number" or expectedVersion ~= math.floor(expectedVersion) then
        validationError("Plugin API compatibility check requires an integer version", 2)
    end
    if expectedVersion ~= PLUGIN_API_VERSION then
        validationError(
            "Incompatible SkillPerkSystem plugin API version: plugin expects v"
                .. tostring(expectedVersion)
                .. ", engine provides v"
                .. tostring(PLUGIN_API_VERSION),
            2
        )
    end
    return true
end

local function registerPerk(data, source)
    if type(data) ~= "table" then
        validationError("registerPerk() expects a table", 2)
    end
    if type(data.id) ~= "string" then
        validationError("registerPerk() missing string field 'id'", 2)
    end
    if type(data.skill) ~= "string" then
        validationError("registerPerk(" .. tostring(data.id) .. ") missing string field 'skill'", 2)
    end
    if not hasSkillRecord(data.skill) then
        validationError(
            "registerPerk(" .. tostring(data.id) .. ") has invalid skill id '" .. tostring(data.skill) .. "'",
            2
        )
    end
    if type(data.effectId) ~= "string" or data.effectId == "" then
        validationError("registerPerk(" .. tostring(data.id) .. ") missing non-empty string field 'effectId'", 2)
    end

    if data.requirements == nil then
        data.requirements = {}
    end
    if type(data.requirements) ~= "table" then
        validationError("registerPerk(" .. tostring(data.id) .. ") field 'requirements' must be a table", 2)
    end

    if data.cost == nil then
        data.cost = 1
    end
    if type(data.cost) ~= "number" or data.cost < 1 or data.cost ~= math.floor(data.cost) then
        validationError("registerPerk(" .. tostring(data.id) .. ") field 'cost' must be a positive integer", 2)
    end

    local sourceName = normalizeSource(source)
    local ok, previousSource = registryState.registerPerk(data, sourceName, settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE)
    if not ok then
        validationError(
            "registerPerk() duplicate perk id '"
                .. tostring(data.id)
                .. "' from source='"
                .. tostring(sourceName)
                .. "' conflicts with source='"
                .. tostring(previousSource)
                .. "' policy="
                .. duplicatePolicyLabel(),
            2
        )
    end
end

local function registerTreeNode(data, source)
    if type(data) ~= "table" then
        validationError("registerTreeNode() expects a table", 2)
    end
    if type(data.id) ~= "string" or data.id == "" then
        validationError("registerTreeNode() missing string field 'id'", 2)
    end
    if type(data.skill) ~= "string" or not hasSkillRecord(data.skill) then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") has invalid field 'skill'", 2)
    end
    if type(data.x) ~= "number" or type(data.y) ~= "number" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") requires numeric fields 'x' and 'y'", 2)
    end

    if data.requires == nil then
        data.requires = {}
    end
    if type(data.requires) ~= "table" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'requires' must be a list", 2)
    end
    for i, req in ipairs(data.requires) do
        if type(req) ~= "string" then
            validationError(
                "registerTreeNode(" .. tostring(data.id) .. ") requires[" .. tostring(i) .. "] must be a string",
                2
            )
        end
    end

    if data.title == nil then
        data.title = data.id
    end
    if type(data.title) ~= "string" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'title' must be a string", 2)
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'description' must be a string", 2)
    end

    local sourceName = normalizeSource(source)
    local ok, previousSource = registryState.registerTreeNode(data, sourceName, settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE)
    if not ok then
        validationError(
            "registerTreeNode() duplicate node id '"
                .. tostring(data.id)
                .. "' from source='"
                .. tostring(sourceName)
                .. "' conflicts with source='"
                .. tostring(previousSource)
                .. "' policy="
                .. duplicatePolicyLabel(),
            2
        )
    end
end

local function registerEffect(data, source)
    if type(data) ~= "table" or type(data.id) ~= "string" or data.id == "" then
        validationError("registerEffect() requires a table with non-empty string field 'id'", 2)
    end
    local sourceName = normalizeSource(source)
    effectsRegistry.registerEffect(data.id, data, sourceName)
end

local function registerPointSource(sourceId, handlers, source)
    if type(sourceId) ~= "string" or sourceId == "" then
        validationError("registerPointSource() requires non-empty string sourceId", 2)
    end
    if type(handlers) ~= "table" then
        validationError("registerPointSource(" .. tostring(sourceId) .. ") requires handlers table", 2)
    end

    local sourceName = normalizeSource(source)
    registryState.registerPointSource(sourceId, handlers, sourceName)
end

return {
    PLUGIN_API_VERSION = PLUGIN_API_VERSION,
    assertCompatibleApiVersion = assertCompatibleApiVersion,
    registerPerk = registerPerk,
    registerTreeNode = registerTreeNode,
    registerEffect = registerEffect,
    registerPointSource = registerPointSource,
}
