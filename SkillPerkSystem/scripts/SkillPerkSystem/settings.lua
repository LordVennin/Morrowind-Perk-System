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
    -- Keep minimum at 1.0 by default so text does not overflow shrinking containers on sub-1080p displays.
    PERK_UI_SCALE_MIN = 1.0,
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
    -- Maximum visible character count for perk tree node button labels.
    -- Longer labels are truncated with an ellipsis.
    PERK_UI_TREE_NODE_MAX_LABEL_CHARS = 20,
    POINT_SOURCES = {
        levelUpRewards = {
            enabled = false,
            pointsPerLevel = 1,
            -- Level 1 is character creation; start rewards at 2 by default.
            firstRewardLevel = 2,
        },
        skillMilestoneRewards = {
            enabled = false,
            milestoneEnabled = {
                [1] = false,
                [2] = false,
                [3] = false,
            },
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

local function getBooleanValue(key, fallback)
    local value = section:get(key)
    if type(value) ~= "boolean" then
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
        l10n = MOD_NAME,
        name = "name",
        description = "modSettingsDescription",
    }

    interfaces.Settings.registerGroup {
        key = SETTINGS_GROUP_KEY,
        page = SETTINGS_PAGE_KEY,
        l10n = MOD_NAME,
        name = "gameplay",
        permanentStorage = true,
        settings = {
            {
                key = "toggleUiKey",
                name = "toggleUiKeyName",
                description = "toggleUiKeyDescription",
                default = defaults.TOGGLE_UI_KEY,
                renderer = "textLine",
                argument = {
                    trim = true,
                    maxLength = 1,
                },
            },
            {
                key = "enableLevelUpRewards",
                name = "enableLevelUpRewardsName",
                description = "enableLevelUpRewardsDescription",
                default = defaults.POINT_SOURCES.levelUpRewards.enabled,
                renderer = "checkbox",
            },
            {
                key = "pointsPerLevel",
                name = "pointsPerLevelName",
                description = "pointsPerLevelDescription",
                default = defaults.POINT_SOURCES.levelUpRewards.pointsPerLevel,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 0,
                    max = 20,
                },
            },
            {
                key = "enableSkillMilestone1",
                name = "enableSkillMilestone1Name",
                description = "enableSkillMilestone1Description",
                default = defaults.POINT_SOURCES.skillMilestoneRewards.milestoneEnabled[1],
                renderer = "checkbox",
            },
            {
                key = "skillMilestone1",
                name = "skillMilestone1Name",
                description = "skillMilestone1Description",
                default = 50,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 100,
                },
            },
            {
                key = "enableSkillMilestone2",
                name = "enableSkillMilestone2Name",
                description = "enableSkillMilestone2Description",
                default = defaults.POINT_SOURCES.skillMilestoneRewards.milestoneEnabled[2],
                renderer = "checkbox",
            },
            {
                key = "skillMilestone2",
                name = "skillMilestone2Name",
                description = "skillMilestone2Description",
                default = 75,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 100,
                },
            },
            {
                key = "enableSkillMilestone3",
                name = "enableSkillMilestone3Name",
                description = "enableSkillMilestone3Description",
                default = defaults.POINT_SOURCES.skillMilestoneRewards.milestoneEnabled[3],
                renderer = "checkbox",
            },
            {
                key = "skillMilestone3",
                name = "skillMilestone3Name",
                description = "skillMilestone3Description",
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

local function getLevelUpRewardsEnabled()
    return getBooleanValue("enableLevelUpRewards", defaults.POINT_SOURCES.levelUpRewards.enabled)
end

local function getSkillMilestoneEnabled(index)
    local key = "enableSkillMilestone" .. tostring(index)
    local fallback = defaults.POINT_SOURCES.skillMilestoneRewards.milestoneEnabled[index] == true
    return getBooleanValue(key, fallback)
end

local function getSkillMilestoneRewards()
    local rewards = {}
    local milestoneKeys = { "skillMilestone1", "skillMilestone2", "skillMilestone3" }
    local fallbackThresholds = { 50, 75, 100 }

    for index, key in ipairs(milestoneKeys) do
        if getSkillMilestoneEnabled(index) then
            local threshold = math.max(1, math.floor(getNumberValue(key, fallbackThresholds[index])))
            rewards[threshold] = 1
        end
    end

    return rewards
end

local container = {
    section = section,
    init = init,
    getToggleUiKey = getToggleUiKey,
    getPointsPerLevel = getPointsPerLevel,
    getLevelUpRewardsEnabled = getLevelUpRewardsEnabled,
    getSkillMilestoneEnabled = getSkillMilestoneEnabled,
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
