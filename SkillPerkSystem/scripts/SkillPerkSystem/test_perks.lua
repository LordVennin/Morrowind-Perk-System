local settings = require("scripts.SkillPerkSystem.settings")
local builtinPerks = require("scripts.SkillPerkSystem.perks.register_builtin")

local longbladeCompatibilityModules = require("scripts.SkillPerkSystem.perks.longblade")

local registered = false

local function registerDemoPerks(registerPerk, source)
    if registered or not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    local api = {
        registerPerk = function(perk)
            return registerPerk(perk, source)
        end,
    }

    builtinPerks.registerPerkModules(api, longbladeCompatibilityModules)

    registered = true
end

return {
    registerDemoPerks = registerDemoPerks,
}
