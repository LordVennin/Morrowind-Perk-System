-- Alteration player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "alteration",
    tag = "Alteration",
    refundPerk = "alteration_practiced_shaper",
    reservoirPerk = "alteration_shapers_reserve",
})
