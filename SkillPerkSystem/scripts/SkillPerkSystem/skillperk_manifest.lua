local settings = require("scripts.SkillPerkSystem.settings")

local function register(api)
    api.assertCompatibleApiVersion(1)
end

local modules = settings.ENABLE_DEMO_TREE_PERKS and {
    "scripts.SkillPerkSystem.perks.block.block",
    "scripts.SkillPerkSystem.perks.longblade.longblade",
} or {}

return {
    register = register,
    modules = modules,
}
