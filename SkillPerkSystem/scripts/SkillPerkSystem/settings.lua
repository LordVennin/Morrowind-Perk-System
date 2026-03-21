local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")

local MOD_NAME = "SkillPerkSystem"
local SETTINGS_PAGE_KEY = MOD_NAME
local SETTINGS_GROUP_KEY = "Settings" .. MOD_NAME

local defaults = {
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

local section = storage.playerSection(SETTINGS_GROUP_KEY)
local initialized = false

local function getNumberValue(key, fallback)
    local value = section:get(key)
    if value == nil then
        value = fallback
    end
    return tonumber(value) or fallback
end

local function getTextValue(key, fallback)
    local value = section:get(key)
    if type(value) ~= "string" or value == "" then
        return fallback
    end
    return value
end

local function init()
    if initialized then
        return
    end

    interfaces.Settings.registerPage {
        key = SETTINGS_PAGE_KEY,
        name = "Skill Perk System",
        description = "Configure perk menu keybind and point rewards.",
    }

    interfaces.Settings.registerGroup {
        key = SETTINGS_GROUP_KEY,
        page = SETTINGS_PAGE_KEY,
        name = "Gameplay",
        permanentStorage = true,
        settings = {
            {
                key = "toggleUiKey",
                name = "Perk Menu Key",
                description = "Single letter key used to open the perk menu.",
                default = defaults.TOGGLE_UI_KEY,
                renderer = "textLine",
                argument = {
                    trim = true,
                    maxLength = 1,
                },
            },
            {
                key = "pointsPerLevel",
                name = "Points Per Level",
                description = "How many perk points are awarded on each level up.",
                default = defaults.POINT_SOURCES.levelUpRewards.pointsPerLevel,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 0,
                    max = 20,
                },
            },
            {
                key = "skillMilestone1",
                name = "Skill Milestone #1",
                description = "First skill level threshold that grants a perk point.",
                default = 50,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 100,
                },
            },
            {
                key = "skillMilestone2",
                name = "Skill Milestone #2",
                description = "Second skill level threshold that grants a perk point.",
                default = 75,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 100,
                },
            },
            {
                key = "skillMilestone3",
                name = "Skill Milestone #3",
                description = "Third skill level threshold that grants a perk point.",
                default = 100,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 100,
                },
            },
        },
    }

    initialized = true
end

local function getToggleUiKey()
    return getTextValue("toggleUiKey", defaults.TOGGLE_UI_KEY)
end

local function getPointsPerLevel()
    return math.max(0, math.floor(getNumberValue("pointsPerLevel", defaults.POINT_SOURCES.levelUpRewards.pointsPerLevel)))
end

local function getSkillMilestoneRewards()
    local rewards = {}
    local milestoneKeys = { "skillMilestone1", "skillMilestone2", "skillMilestone3" }
    local fallbackThresholds = { 50, 75, 100 }

    for index, key in ipairs(milestoneKeys) do
        local threshold = math.max(1, math.floor(getNumberValue(key, fallbackThresholds[index])))
        rewards[threshold] = 1
    end

    return rewards
end

local container = {
    section = section,
    init = init,
    getToggleUiKey = getToggleUiKey,
    getPointsPerLevel = getPointsPerLevel,
    getSkillMilestoneRewards = getSkillMilestoneRewards,
}

setmetatable(container, {
    __index = function(_, key)
        if defaults[key] ~= nil then
            return defaults[key]
        end
        return nil
    end,
})

return container
