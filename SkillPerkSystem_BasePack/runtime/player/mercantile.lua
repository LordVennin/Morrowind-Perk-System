-- Mercantile player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "mercantile",
    tag = "Mercantile",
    studyPerk = "mercantile_keen_trader",
})
