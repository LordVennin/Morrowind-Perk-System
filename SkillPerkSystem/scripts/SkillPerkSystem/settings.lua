local MOD_NAME = "SkillPerkSystem"

return {
    MOD_NAME = MOD_NAME,
    MILESTONE_STEP = 25,
    DEBUG_LOGS = false,
    -- Strict modular architecture guard:
    -- true  = startup fails loudly when no external perk modules are loaded.
    -- false = allow framework-only startup with an empty registry.
    REQUIRE_EXTERNAL_PERK_PACKS = false,
    -- Duplicate registration policy:
    -- false (default) = hard-error on duplicate ids
    -- true            = last-write-wins (development convenience)
    ALLOW_DUPLICATE_REGISTRATION_OVERRIDE = false,
    TOGGLE_UI_KEY = "p",
    -- Perk UI global scaling controls.
    -- Automatic scaling uses current screen width relative to PERK_UI_SCALE_REFERENCE_WIDTH.
    PERK_UI_AUTO_SCALE = true,
    PERK_UI_SCALE_REFERENCE_WIDTH = 1920,
    PERK_UI_SCALE_MIN = 0.75,
    PERK_UI_SCALE_MAX = 1.6,
    -- Additional multiplier applied after auto-scaling (1.0 = no change).
    PERK_UI_SCALE_MULTIPLIER = 1.0,
    -- Perk UI layout tunables.
    PERK_UI_LEFT_PANE_WIDTH = 540,
    PERK_UI_RIGHT_PANE_WIDTH = 408,
    PERK_UI_SIDE_PADDING = 0,
    PERK_UI_GUTTER_WIDTH = 16,
    -- Compensates for outer template frame thickness so inner panes visually reach the right edge.
    PERK_UI_FRAME_EDGE_COMPENSATION = 10,
    -- Additional right-side expansion for the main body box (tree + description + exit row).
    PERK_UI_BODY_RIGHT_EXPANSION = 18,
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
