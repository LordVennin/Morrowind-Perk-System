local settings = require("scripts.SkillPerkSystem.settings")

local demoPerks = {
    { id = "longblade_demo_root", skill = "longblade", cost = 1, requires = {} },
    { id = "longblade_demo_precision", skill = "longblade", cost = 1, requires = { "longblade_demo_root" } },
    { id = "longblade_demo_pressure", skill = "longblade", cost = 1, requires = { "longblade_demo_root" } },
    { id = "longblade_demo_cleaving", skill = "longblade", cost = 1, requires = { "longblade_demo_root" } },
    { id = "longblade_demo_duelist", skill = "longblade", cost = 1, requires = { "longblade_demo_precision" } },
    { id = "longblade_demo_whirlwind", skill = "longblade", cost = 1, requires = { "longblade_demo_cleaving" } },
    {
        id = "longblade_demo_mastery",
        skill = "longblade",
        cost = 1,
        requires = { "longblade_demo_duelist", "longblade_demo_whirlwind", "longblade_demo_pressure" },
    },
}

local function register(api)
    if not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    for _, record in ipairs(demoPerks) do
        local requirements = {}
        for _, parentID in ipairs(record.requires or {}) do
            table.insert(requirements, {
                check = function()
                    return api.playerHasPerk(parentID)
                end,
            })
        end

        api.registerPerk({
            id = record.id,
            skill = record.skill,
            requirements = requirements,
            cost = record.cost,
            effectId = "demo_noop",
        })
    end
end

return {
    register = register,
}
