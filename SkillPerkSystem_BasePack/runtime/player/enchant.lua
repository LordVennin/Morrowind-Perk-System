-- Enchant player runtime for SkillPerkSystem_BasePack: the opening perks only,
-- built on the shared skill base. See runtime/skillbase.lua.
return require("scripts.SkillPerkSystem_BasePack.runtime.skillbase").build({
    skillId = "enchant",
    tag = "Enchant",
    studyPerk = "enchant_attentive_enchanter",
    reservoirPerk = "enchant_enchanters_reserve",
})
