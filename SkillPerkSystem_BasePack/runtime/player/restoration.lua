-- Restoration player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "restoration",
    tag = "Restoration",
    refundPerk = "restoration_practiced_healer",
    reservoirPerk = "restoration_healers_reserve",
})
