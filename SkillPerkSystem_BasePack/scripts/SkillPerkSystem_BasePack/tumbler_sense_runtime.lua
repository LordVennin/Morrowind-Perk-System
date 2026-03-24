local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.tumbler_sense.enabled"
local STACK_COUNT_KEY = "security.tumbler_sense.stack_count"
local BONUS_PER_STACK_KEY = "security.tumbler_sense.bonus_per_stack"
local MAX_STACKS_KEY = "security.tumbler_sense.max_stacks"
local SHARED_DECAY_SECONDS_KEY = "security.tumbler_sense.shared_decay_seconds"
local EXPIRY_TIMESTAMP_KEY = "security.tumbler_sense.expiry_timestamp"
local ACTIVE_BONUS_KEY = "security.tumbler_sense.active_bonus"

local DEFAULT_BONUS_PER_STACK = 0.02
local DEFAULT_MAX_STACKS = 5
local DEFAULT_DECAY_SECONDS = 10

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"
local FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local REFRESH_CHANCE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_RefreshChance"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TUMBLER_SENSE_PERK_ID = "security_tumbler_sense"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)

local function clamp(value, minValue, maxValue)
    if type(value) ~= "number" then
        return minValue
    end
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function normalizeBonus(value)
    if type(value) ~= "number" then
        return DEFAULT_BONUS_PER_STACK
    end
    if value < 0 then
        return 0
    end
    return value
end

local function nowTimestamp()
    return core.getSimulationTime()
end

local function tumblerSenseEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local hasPerk = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(TUMBLER_SENSE_PERK_ID) or false
    if not hasPerk then
        return false
    end

    local effectEnabled = type(playerApi.isPerkEffectEnabled) ~= "function"
        or playerApi.isPerkEffectEnabled(TUMBLER_SENSE_PERK_ID)
    if not effectEnabled then
        return false
    end

    if effectsSection:get(ENABLED_KEY) ~= true then
        -- Fallback for load-order/event timing issues: if the perk is owned and
        -- its effect is enabled, keep runtime state active even when the toggle
        -- event was not observed yet.
        effectsSection:set(ENABLED_KEY, true)
        if type(effectsSection:get(BONUS_PER_STACK_KEY)) ~= "number" then
            effectsSection:set(BONUS_PER_STACK_KEY, DEFAULT_BONUS_PER_STACK)
        end
        if type(effectsSection:get(MAX_STACKS_KEY)) ~= "number" then
            effectsSection:set(MAX_STACKS_KEY, DEFAULT_MAX_STACKS)
        end
        if type(effectsSection:get(SHARED_DECAY_SECONDS_KEY)) ~= "number" then
            effectsSection:set(SHARED_DECAY_SECONDS_KEY, DEFAULT_DECAY_SECONDS)
        end
        print("[SkillPerkSystem_BasePack][TumblerSense] recovered enabled state from owned perk/effect flags")
    end

    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    return true
end

local function getMaxStacks()
    local maxStacks = tonumber(effectsSection:get(MAX_STACKS_KEY))
    if type(maxStacks) ~= "number" then
        return DEFAULT_MAX_STACKS
    end
    return math.max(1, math.floor(maxStacks))
end

local function getBonusPerStack()
    return normalizeBonus(effectsSection:get(BONUS_PER_STACK_KEY))
end

local function getSharedDecaySeconds()
    local sharedDecay = tonumber(effectsSection:get(SHARED_DECAY_SECONDS_KEY))
    if type(sharedDecay) ~= "number" then
        return DEFAULT_DECAY_SECONDS
    end
    return math.max(0, sharedDecay)
end

local function clearStacks(reason)
    local stackCount = tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0
    local expiry = tonumber(effectsSection:get(EXPIRY_TIMESTAMP_KEY))

    effectsSection:set(STACK_COUNT_KEY, 0)
    effectsSection:set(EXPIRY_TIMESTAMP_KEY, nil)
    effectsSection:set(ACTIVE_BONUS_KEY, 0.0)

    if stackCount > 0 then
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] stacks expired reason=%s previousStacks=%d expiry=%s",
            tostring(reason),
            stackCount,
            tostring(expiry)
        ))
    end
end

local function clearExpiredStacks(reason)
    local stackCount = tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0
    if stackCount <= 0 then
        effectsSection:set(ACTIVE_BONUS_KEY, 0.0)
        return
    end

    local expiry = tonumber(effectsSection:get(EXPIRY_TIMESTAMP_KEY))
    local now = nowTimestamp()
    if type(expiry) == "number" and expiry > now then
        return
    end

    clearStacks(reason)
end

local function currentBonus()
    local stackCount = clamp(tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0, 0, getMaxStacks())
    local bonus = stackCount * getBonusPerStack()
    effectsSection:set(ACTIVE_BONUS_KEY, bonus)
    return stackCount, bonus
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)
    effectsSection:set(BONUS_PER_STACK_KEY, normalizeBonus(data.bonusPerFailedAttempt))
    effectsSection:set(MAX_STACKS_KEY, math.max(1, math.floor(tonumber(data.maxStacks) or DEFAULT_MAX_STACKS)))
    effectsSection:set(SHARED_DECAY_SECONDS_KEY, math.max(0, tonumber(data.sharedDecaySeconds) or DEFAULT_DECAY_SECONDS))

    if not enabled then
        clearStacks("disabled")
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] %s (bonusPerStack=%.2f maxStacks=%d decaySeconds=%.2f)",
        enabled and "enabled" or "disabled",
        getBonusPerStack(),
        getMaxStacks(),
        getSharedDecaySeconds()
    ))
end

local function handleFailure(data)
    if not tumblerSenseEnabled() then
        return
    end

    clearExpiredStacks("failure-precheck")

    local previousStacks = clamp(tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0, 0, getMaxStacks())
    local nextStacks = math.min(previousStacks + 1, getMaxStacks())
    local expiry = nowTimestamp() + getSharedDecaySeconds()
    effectsSection:set(STACK_COUNT_KEY, nextStacks)
    effectsSection:set(EXPIRY_TIMESTAMP_KEY, expiry)

    local _, bonus = currentBonus()
    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] stack gain source=%s mode=%s stacks=%d->%d bonus=%.2f",
        tostring(type(data) == "table" and data.source or "unknown"),
        tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown"),
        previousStacks,
        nextStacks,
        bonus
    ))
    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] timer refresh source=%s expiry=%.2f now=%.2f",
        tostring(type(data) == "table" and data.source or "unknown"),
        expiry,
        nowTimestamp()
    ))
end

local function handleRefreshChance(data)
    clearExpiredStacks("chance-refresh")

    if not tumblerSenseEnabled() then
        effectsSection:set(ACTIVE_BONUS_KEY, 0.0)
        return
    end

    local stackCount, bonus = currentBonus()
    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] chance bonus applied source=%s mode=%s stacks=%d bonus=%.2f",
        tostring(type(data) == "table" and data.source or "unknown"),
        tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown"),
        stackCount,
        bonus
    ))
end

local function onUpdate()
    clearExpiredStacks("onUpdate")
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        [FAILURE_EVENT] = handleFailure,
        [REFRESH_CHANCE_EVENT] = handleRefreshChance,
    },
}
