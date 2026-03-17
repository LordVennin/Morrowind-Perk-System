local interfaces = require("openmw.interfaces")

interfaces.SkillPerkSystem.registerPerk({
    id = "ern_example_longblade_mastery",
    skill = "longblade",
    cost = 1,
    effectId = "ern_example_longblade_mastery_effect",
    requirements = {},
})

interfaces.SkillPerkSystem.registerTreeNode({
    id = "ern_example_longblade_mastery",
    skill = "longblade",
    x = 1,
    y = 0,
    requires = { "ern_example_longblade_precision" },
    title = "Example: Mastery",
    description = "Skill file example that references an effect handler in a separate file.",
})
