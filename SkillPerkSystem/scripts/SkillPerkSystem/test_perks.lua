local settings = require("scripts.SkillPerkSystem.settings")
local interfaces = require("openmw.interfaces")

local MOD_NAME = settings.MOD_NAME
local registered = false

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

local function buildRequirement(parentID)
    return {
        check = function()
            local playerInterface = interfaces[MOD_NAME .. "Player"]
            return playerInterface ~= nil and playerInterface.hasPerk(parentID)
        end,
    }
end

local function registerDemoPerks(registerPerk)
    if registered or not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    for _, record in ipairs(demoPerks) do
        local requirements = {}
        for _, parentID in ipairs(record.requires or {}) do
            table.insert(requirements, buildRequirement(parentID))
        end

        registerPerk({
            id = record.id,
            skill = record.skill,
            requirements = requirements,
            cost = record.cost,
            onAdd = function() end,
            onRemove = function() end,
        })
    end

    registered = true
    print("[" .. MOD_NAME .. "] Registered Long Blade demo tree perks (" .. tostring(#demoPerks) .. ")")
end

return {
    registerDemoPerks = registerDemoPerks,
}
