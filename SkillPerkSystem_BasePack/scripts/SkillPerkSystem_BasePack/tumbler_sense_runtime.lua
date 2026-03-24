local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.tumbler_sense.enabled"
local STACK_COUNT_KEY = "security.tumbler_sense.stack_count"
local BONUS_PER_STACK_KEY = "security.tumbler_sense.bonus_per_stack"
local MAX_STACKS_KEY = "security.tumbler_sense.max_stacks"
local INITIAL_STACKS_KEY = "security.tumbler_sense.initial_stacks"
local SHARED_DECAY_SECONDS_KEY = "security.tumbler_sense.shared_decay_seconds"
local EXPIRY_TIMESTAMP_KEY = "security.tumbler_sense.expiry_timestamp"
local ACTIVE_BONUS_KEY = "security.tumbler_sense.active_bonus"
local APPLIED_SKILL_BONUS_KEY = "security.tumbler_sense.applied_skill_bonus"

local DEFAULT_BONUS_PER_STACK = 0.01
local DEFAULT_MAX_STACKS = 5
local DEFAULT_INITIAL_STACKS = 1
local DEFAULT_DECAY_SECONDS = 10

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"
local FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local REFRESH_CHANCE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_RefreshChance"
local RUNTIME_INTERFACE_NAME = "SkillPerkSystem_BasePack_TumblerSenseRuntime"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TUMBLER_SENSE_PERK_ID = "security_tumbler_sense"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
print("[SkillPerkSystem_BasePack][TumblerSense] runtime script loaded")

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
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(TUMBLER_SENSE_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(TUMBLER_SENSE_PERK_ID) then
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


local function applySecuritySkillBonus(targetBonus)
    local accessor = types.NPC.stats.skills.security
    if type(accessor) ~= "function" then
        return
    end

    local currentApplied = clamp(tonumber(effectsSection:get(APPLIED_SKILL_BONUS_KEY)) or 0, 0, getMaxStacks())
    local desiredApplied = clamp(math.floor(tonumber(targetBonus) or 0), 0, getMaxStacks())
    if currentApplied == desiredApplied then
        return
    end

    local stat = accessor(pself)
    if stat == nil or type(stat.base) ~= "number" then
        return
    end

    local newBase = math.max(0, math.floor(stat.base - currentApplied + desiredApplied))
    stat.base = newBase
    effectsSection:set(APPLIED_SKILL_BONUS_KEY, desiredApplied)

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] security base adjusted appliedBonus=%d->%d resultingBase=%d",
        currentApplied,
        desiredApplied,
        newBase
    ))
end

local function clearStacks(reason)
    local stackCount = tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0
    local expiry = tonumber(effectsSection:get(EXPIRY_TIMESTAMP_KEY))

    effectsSection:set(STACK_COUNT_KEY, 0)
    effectsSection:set(EXPIRY_TIMESTAMP_KEY, nil)
    effectsSection:set(ACTIVE_BONUS_KEY, 0.0)
    applySecuritySkillBonus(0)

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
    applySecuritySkillBonus(stackCount)
    return stackCount, bonus
end

local function getActiveBonusFraction()
    clearExpiredStacks("runtime-get-active-bonus")

    if not tumblerSenseEnabled() then
        clearStacks("perk-disabled-or-missing")
        return 0.0
    end

    local _, bonus = currentBonus()
    return bonus
end

local function getActiveBonusPercentPoints()
    return getActiveBonusFraction() * 100
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)
    effectsSection:set(BONUS_PER_STACK_KEY, normalizeBonus(data.bonusPerFailedAttempt))
    effectsSection:set(MAX_STACKS_KEY, math.max(1, math.floor(tonumber(data.maxStacks) or DEFAULT_MAX_STACKS)))
    effectsSection:set(INITIAL_STACKS_KEY, math.max(0, math.floor(tonumber(data.initialStacks) or DEFAULT_INITIAL_STACKS)))
    effectsSection:set(SHARED_DECAY_SECONDS_KEY, math.max(0, tonumber(data.sharedDecaySeconds) or DEFAULT_DECAY_SECONDS))

    if enabled then
        local initialStacks = clamp(
            tonumber(effectsSection:get(INITIAL_STACKS_KEY)) or DEFAULT_INITIAL_STACKS,
            0,
            getMaxStacks()
        )
        local expiry = nil
        if initialStacks > 0 and getSharedDecaySeconds() > 0 then
            expiry = nowTimestamp() + getSharedDecaySeconds()
        end
        effectsSection:set(STACK_COUNT_KEY, initialStacks)
        effectsSection:set(EXPIRY_TIMESTAMP_KEY, expiry)
        currentBonus()
    else
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
    local source = type(data) == "table" and data.source or "unknown"
    if source ~= "pin_skill_roll" and source ~= "auto_attempt_skill_roll" then
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] failure ignored source=%s mode=%s",
            tostring(source),
            tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown")
        ))
        return
    end

    if not tumblerSenseEnabled() then
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] failure ignored source=%s mode=%s reason=perk-disabled-or-missing",
            tostring(source),
            tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown")
        ))
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
        tostring(source),
        tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown"),
        previousStacks,
        nextStacks,
        bonus
    ))
    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] timer refresh source=%s expiry=%.2f now=%.2f",
        tostring(source),
        expiry,
        nowTimestamp()
    ))
end

local function handleRefreshChance(data)
    clearExpiredStacks("chance-refresh")

    if not tumblerSenseEnabled() then
        print("[SkillPerkSystem_BasePack][TumblerSense] chance refresh skipped reason=perk-disabled-or-missing")
        clearStacks("perk-disabled-or-missing")
        return
    end

    local stackCount, bonus = currentBonus()
    local baseChance = type(data) == "table" and tonumber(data.baseChance) or nil
    local chanceMax = type(data) == "table" and tonumber(data.chanceMax) or 100
    local chanceMin = type(data) == "table" and tonumber(data.chanceMin) or 0
    local bonusPctPoints = bonus * 100
    local finalChance = nil
    if type(baseChance) == "number" then
        finalChance = clamp(baseChance + bonusPctPoints, chanceMin, chanceMax)
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] chance bonus applied source=%s mode=%s stacks=%d bonus=%.2f",
        tostring(type(data) == "table" and data.source or "unknown"),
        tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown"),
        stackCount,
        bonus
    ))
    if type(baseChance) == "number" then
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] chance debug source=%s base=%.2f perkBonus=%.2f final=%.2f bounds=%.2f..%.2f",
            tostring(type(data) == "table" and data.source or "unknown"),
            baseChance,
            bonusPctPoints,
            finalChance,
            chanceMin,
            chanceMax
        ))
    end
end

local function requestRefreshChance(data)
    handleRefreshChance(data)
    return getActiveBonusPercentPoints()
end

local function onUpdate()
    clearExpiredStacks("onUpdate")
end

return {
    interfaceName = RUNTIME_INTERFACE_NAME,
    interface = {
        requestRefreshChance = requestRefreshChance,
        getActiveBonusFraction = getActiveBonusFraction,
        getActiveBonusPercentPoints = getActiveBonusPercentPoints,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        [FAILURE_EVENT] = handleFailure,
        [REFRESH_CHANCE_EVENT] = handleRefreshChance,
    },
}
