-- Illusion player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "illusion",
    tag = "Illusion",
    refundPerk = "illusion_practiced_illusionist",
    reservoirPerk = "illusion_illusionists_reserve",
})
