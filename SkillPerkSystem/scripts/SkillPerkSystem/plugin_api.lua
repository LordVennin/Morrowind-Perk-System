local core = require("openmw.core")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")

local PLUGIN_API_VERSION = 1

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
        error("Plugin API compatibility check requires an integer version", 2)
    end
    if expectedVersion ~= PLUGIN_API_VERSION then
        error(
            "Incompatible SkillPerkSystem plugin API version: plugin expects v"
                .. tostring(expectedVersion)
                .. ", engine provides v"
                .. tostring(PLUGIN_API_VERSION),
            2
        )
    end
    return true
end

local function registerPerk(data)
    if type(data) ~= "table" then
        error("registerPerk() expects a table", 2)
    end
    if type(data.id) ~= "string" then
        error("registerPerk() missing string field 'id'", 2)
    end
    if type(data.skill) ~= "string" then
        error("registerPerk(" .. tostring(data.id) .. ") missing string field 'skill'", 2)
    end
    if not hasSkillRecord(data.skill) then
        error(
            "registerPerk(" .. tostring(data.id) .. ") has invalid skill id '" .. tostring(data.skill) .. "'",
            2
        )
    end
    if type(data.effectId) ~= "string" or data.effectId == "" then
        error("registerPerk(" .. tostring(data.id) .. ") missing non-empty string field 'effectId'", 2)
    end

    if data.requirements == nil then
        data.requirements = {}
    end
    if type(data.requirements) ~= "table" then
        error("registerPerk(" .. tostring(data.id) .. ") field 'requirements' must be a table", 2)
    end

    if data.cost == nil then
        data.cost = 1
    end
    if type(data.cost) ~= "number" or data.cost < 1 or data.cost ~= math.floor(data.cost) then
        error("registerPerk(" .. tostring(data.id) .. ") field 'cost' must be a positive integer", 2)
    end

    registryState.upsertPerk(data)
end

local function registerTreeNode(data)
    if type(data) ~= "table" then
        error("registerTreeNode() expects a table", 2)
    end
    if type(data.id) ~= "string" or data.id == "" then
        error("registerTreeNode() missing string field 'id'", 2)
    end
    if type(data.skill) ~= "string" or not hasSkillRecord(data.skill) then
        error("registerTreeNode(" .. tostring(data.id) .. ") has invalid field 'skill'", 2)
    end
    if type(data.x) ~= "number" or type(data.y) ~= "number" then
        error("registerTreeNode(" .. tostring(data.id) .. ") requires numeric fields 'x' and 'y'", 2)
    end

    if data.requires == nil then
        data.requires = {}
    end
    if type(data.requires) ~= "table" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'requires' must be a list", 2)
    end
    for i, req in ipairs(data.requires) do
        if type(req) ~= "string" then
            error("registerTreeNode(" .. tostring(data.id) .. ") requires[" .. tostring(i) .. "] must be a string", 2)
        end
    end

    if data.title == nil then
        data.title = data.id
    end
    if type(data.title) ~= "string" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'title' must be a string", 2)
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'description' must be a string", 2)
    end

    if not registryState.addTreeNode(data) then
        error("registerTreeNode() duplicate node id: " .. tostring(data.id), 2)
    end
end

local function registerEffect(data)
    if type(data) ~= "table" or type(data.id) ~= "string" or data.id == "" then
        error("registerEffect() requires a table with non-empty string field 'id'", 2)
    end
    effectsRegistry.registerEffect(data.id, data)
end

local function registerPointSource(data)
    if type(data) ~= "table" or type(data.id) ~= "string" or data.id == "" then
        error("registerPointSource() requires a table with non-empty string field 'id'", 2)
    end
    registryState.registerPointSource(data)
end

return {
    PLUGIN_API_VERSION = PLUGIN_API_VERSION,
    assertCompatibleApiVersion = assertCompatibleApiVersion,
    registerPerk = registerPerk,
    registerTreeNode = registerTreeNode,
    registerEffect = registerEffect,
    registerPointSource = registerPointSource,
}
