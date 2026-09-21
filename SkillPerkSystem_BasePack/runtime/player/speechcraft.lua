-- Speechcraft player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "speechcraft",
    tag = "Speechcraft",
    studyPerk = "speechcraft_attentive_ear",
})
