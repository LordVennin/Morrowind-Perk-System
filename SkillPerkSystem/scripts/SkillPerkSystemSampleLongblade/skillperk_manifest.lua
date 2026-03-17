local interfaces = require("openmw.interfaces")
local settings = require("scripts.SkillPerkSystem.settings")

local MODULES = {
    "scripts.SkillPerkSystemSampleLongblade.perks.longblade.longblade",
}

local function buildRequirements(requires)
    local requirements = {}
    for _, perkID in ipairs(requires or {}) do
        table.insert(requirements, {
            check = function()
                local playerInterface = interfaces[settings.MOD_NAME .. "Player"]
                return playerInterface ~= nil and playerInterface.hasPerk(perkID)
            end,
        })
    end
    return requirements
end

local function register(api)
    api.assertCompatibleApiVersion(1)

    if not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    for _, moduleName in ipairs(MODULES) do
        local moduleData = require(moduleName)
        for _, perk in ipairs(moduleData.perks or {}) do
            api.registerPerk({
                id = perk.id,
                skill = perk.skill,
                effectId = perk.effectId,
                cost = perk.cost,
                requirements = buildRequirements(perk.requires),
            })

            api.registerTreeNode({
                id = perk.id,
                skill = perk.skill,
                x = perk.x,
                y = perk.y,
                requires = perk.requires,
                title = perk.title,
                description = perk.description,
            })
        end
    end
end

return {
    register = register,
    modules = MODULES,
}
