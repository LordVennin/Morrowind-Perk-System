return {
    perks = {
        {
            id = "yourpack_longblade_core_training",
            skill = "longblade",
            effectId = "yourpack_bonus_damage",
            requirements = {},
            cost = 1,
            x = 0,
            y = 0,
            title = "Core Training",
            description = "Starter tree node example co-located with perk data.",
        },
        {
            id = "yourpack_longblade_bleed_strikes",
            skill = "longblade",
            effectId = "yourpack_bonus_damage",
            requires = { "yourpack_longblade_core_training" },
            cost = 1,
            x = 120,
            y = 120,
            title = "Bleed Strikes",
            description = "Branch example with node fields embedded directly in perk.",
        },
    },
}
