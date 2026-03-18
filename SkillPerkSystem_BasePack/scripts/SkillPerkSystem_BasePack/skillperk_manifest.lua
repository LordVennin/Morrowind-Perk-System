-- Bundled default perk pack manifest.
--
-- Keep an explicit module list so bundled trees load even if VFS folder-prefix
-- discovery is unavailable or path-case normalization differs across runtimes.

local PERK_MODULES = {
    "scripts.SkillPerkSystem_BasePack.perks.block.block",
    "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
}

return {
    modules = PERK_MODULES,
}
