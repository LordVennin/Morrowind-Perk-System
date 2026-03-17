local MOD_NAME = "SkillPerkSystem"

return {
    MOD_NAME = MOD_NAME,
    MILESTONE_STEP = 25,
    DEBUG_LOGS = false,
    -- Duplicate registration policy:
    -- false (default) = hard-error on duplicate ids
    -- true            = last-write-wins (development convenience)
    ALLOW_DUPLICATE_REGISTRATION_OVERRIDE = false,
    TOGGLE_UI_KEY = "p",
    ENABLE_DEMO_TREE_PERKS = true,
    POINT_SOURCES = {
        levelUpRewards = {
            enabled = true,
            pointsPerLevel = 1,
            -- Level 1 is character creation; start rewards at 2 by default.
            firstRewardLevel = 2,
        },
        skillMilestoneRewards = {
            enabled = true,
            rewardsBySkillLevel = {
                [50] = 1,
                [75] = 1,
                [100] = 1,
            },
        },
        questCompletionRewards = {
            enabled = true,
            defaultPoints = 1,
        },
    },
}
