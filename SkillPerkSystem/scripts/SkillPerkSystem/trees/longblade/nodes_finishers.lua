return {
    {
        id = "longblade_demo_duelist",
        skill = "longblade",
        title = "Duelist Finish",
        description = "Focused finishing sequence from precision line.",
        x = -120,
        y = 260,
        requires = { "longblade_demo_precision" },
    },
    {
        id = "longblade_demo_whirlwind",
        skill = "longblade",
        title = "Whirlwind Finish",
        description = "Momentum-based finish from cleaving line.",
        x = 120,
        y = 260,
        requires = { "longblade_demo_cleaving" },
    },
    {
        id = "longblade_demo_mastery",
        skill = "longblade",
        title = "Grandmaster Form",
        description = "Final chain node requiring both finishers and pressure control.",
        x = 0,
        y = 420,
        requires = { "longblade_demo_duelist", "longblade_demo_whirlwind", "longblade_demo_pressure" },
    },
}
