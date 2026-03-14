local settings = require("scripts.SkillPerkSystem.settings")
local core = require("openmw.core")

local perkTable = {}
local perkIDs = {}

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
    if core.stats.Skill.records[data.skill] == nil then
        error(
            "registerPerk(" .. tostring(data.id) .. ") has invalid skill id '" .. tostring(data.skill) .. "'",
            2
        )
    end
    if type(data.onAdd) ~= "function" then
        error("registerPerk(" .. tostring(data.id) .. ") missing function field 'onAdd'", 2)
    end
    if type(data.onRemove) ~= "function" then
        error("registerPerk(" .. tostring(data.id) .. ") missing function field 'onRemove'", 2)
    end

    if data.requirements == nil then
        data.requirements = {}
    end
    if type(data.requirements) ~= "table" then
        error("registerPerk(" .. tostring(data.id) .. ") field 'requirements' must be a table", 2)
    end

    if perkTable[data.id] == nil then
        table.insert(perkIDs, data.id)
    end
    perkTable[data.id] = data
end

local function getPerks()
    return perkTable
end

local function getPerkIDs()
    return perkIDs
end

local function getPerkIDsForSkill(skillID)
    local out = {}
    for _, id in ipairs(perkIDs) do
        if perkTable[id].skill == skillID then
            table.insert(out, id)
        end
    end
    return out
end

return {
    interfaceName = settings.MOD_NAME,
    interface = {
        registerPerk = registerPerk,
        getPerks = getPerks,
        getPerkIDs = getPerkIDs,
        getPerkIDsForSkill = getPerkIDsForSkill,
    }
}
