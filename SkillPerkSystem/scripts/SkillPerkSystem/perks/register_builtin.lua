local interfaces = require("openmw.interfaces")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local function buildRequirement(parentID)
    return {
        check = function()
            local playerInterface = interfaces[MOD_NAME .. "Player"]
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
        requirements = {},
    }

    for _, parentID in ipairs(perk.requires or {}) do
        table.insert(normalized.requirements, buildRequirement(parentID))
    end

    return normalized
end

local function registerPerkModules(api, orderedModuleNames)
    local count = 0
    for _, moduleName in ipairs(orderedModuleNames) do
        local definition = require(moduleName)
        api.registerPerk(normalizePerkDefinition(definition))
        count = count + 1
    end
    return count
end

return {
    registerPerkModules = registerPerkModules,
}
