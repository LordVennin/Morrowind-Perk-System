local settings = require("scripts.SkillPerkSystem.settings")

local function register(api)
    api.assertCompatibleApiVersion(1)
end

local modules = settings.ENABLE_DEMO_TREE_PERKS and {
    "scripts.SkillPerkSystem.perks.block.01_core",
    "scripts.SkillPerkSystem.perks.block.10_reactive_guard",
    "scripts.SkillPerkSystem.perks.block.11_bulwark_stance",
    "scripts.SkillPerkSystem.perks.block.20_iron_wall",
    "scripts.SkillPerkSystem.perks.longblade.01_core",
    "scripts.SkillPerkSystem.perks.longblade.10_precision",
    "scripts.SkillPerkSystem.perks.longblade.11_pressure",
    "scripts.SkillPerkSystem.perks.longblade.12_cleaving",
    "scripts.SkillPerkSystem.perks.longblade.20_duelist",
    "scripts.SkillPerkSystem.perks.longblade.21_whirlwind",
    "scripts.SkillPerkSystem.perks.longblade.30_mastery",
} or {}

return {
    register = register,
    modules = modules,
}
