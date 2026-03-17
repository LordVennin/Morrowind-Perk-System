local settings = require("scripts.SkillPerkSystem.settings")
local builtinPerks = require("scripts.SkillPerkSystem.perks.register_builtin")

-- Built-in perk modules should follow numeric prefixes for deterministic progression order,
-- for example: 01_core.lua, 10_branch.lua, 20_capstone.lua.
local PERK_MODULES = {
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
}

table.sort(PERK_MODULES)

local function register(api)
    api.assertCompatibleApiVersion(1)

    if settings.ENABLE_DEMO_TREE_PERKS then
        local registeredCount = builtinPerks.registerPerkModules(api, PERK_MODULES)
        print("[" .. settings.MOD_NAME .. "] Registered built-in demo perks (" .. tostring(registeredCount) .. ")")
    end
end

return {
    register = register,
    modules = PERK_MODULES,
}
