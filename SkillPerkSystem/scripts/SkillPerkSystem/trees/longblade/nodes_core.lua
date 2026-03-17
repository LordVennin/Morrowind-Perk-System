-- Demo Long Blade tree used to validate chain layout + panning.
-- These node ids match demo perks in scripts/SkillPerkSystem/perks/longblade/*.lua.

return {
    {
        id = "longblade_demo_root",
        skill = "longblade",
        title = "Long Blade Fundamentals",
        description = "Core stance training for all long blade techniques.",
        x = 0,
        y = 0,
        requires = {},
    },
    {
        id = "longblade_demo_precision",
        skill = "longblade",
        title = "Precision Cuts",
        description = "Improves spacing and tip-control for measured strikes.",
        x = -180,
        y = 120,
        requires = { "longblade_demo_root" },
    },
    {
        id = "longblade_demo_pressure",
        skill = "longblade",
        title = "Pressure Rhythm",
        description = "Keeps tempo through chained attacks.",
        x = 0,
        y = 120,
        requires = { "longblade_demo_root" },
    },
    {
        id = "longblade_demo_cleaving",
        skill = "longblade",
        title = "Cleaving Arc",
        description = "Adds broad sweeps to control space.",
        x = 180,
        y = 120,
        requires = { "longblade_demo_root" },
    },
}
