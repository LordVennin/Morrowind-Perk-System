local MOD_NAME = "SkillPerkSystem"

return {
    MOD_NAME = MOD_NAME,
    MILESTONE_STEP = 25,
    DEBUG_LOGS = false,
    -- Enables detailed plugin validation logs (per-module load attempts/failures).
    PLUGIN_VALIDATION_VERBOSE = false,
    -- Duplicate registration policy:
    -- false (default) = hard-error on duplicate ids
    -- true            = last-write-wins (development convenience)
    ALLOW_DUPLICATE_REGISTRATION_OVERRIDE = false,
    TOGGLE_UI_KEY = "p",
    -- Perk UI layout tunables.
    PERK_UI_LEFT_PANE_WIDTH = 540,
    PERK_UI_RIGHT_PANE_WIDTH = 408,
    PERK_UI_SIDE_PADDING = 8,
    PERK_UI_GUTTER_WIDTH = 16,
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
