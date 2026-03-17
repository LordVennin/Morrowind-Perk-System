local settings = require("scripts.SkillPerkSystem.settings")
local longbladeSkillModule = require("scripts.SkillPerkSystem.perks.longblade.longblade")

local registered = false

local function registerDemoPerks(registerPerk, source)
    if registered or not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    if type(longbladeSkillModule) == "table" and type(longbladeSkillModule.perks) == "table" then
        for _, perk in ipairs(longbladeSkillModule.perks) do
            registerPerk(perk, source)
        end
    end

    registered = true
end

return {
    registerDemoPerks = registerDemoPerks,
}
