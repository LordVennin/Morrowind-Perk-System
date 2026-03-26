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
local DEFAULT_FAILURE_SOURCE = "unknown"
local CONDITION_FAILURE_SOURCE = "drain_lockpick_event"

local FAILURE_SOURCE_ALIASES = {
    pin_skill_roll = "pin_skill_roll",
    pin_roll = "pin_skill_roll",
    auto_attempt_skill_roll = "auto_attempt_skill_roll",
    auto_attempt_roll = "auto_attempt_skill_roll",
    drain_lockpick_event = "drain_lockpick_event",
    drain_lockpick = "drain_lockpick_event",
    too_complex_gate = "too_complex_gate",
}

local ACCEPTED_FAILURE_SOURCES = {
    pin_skill_roll = true,
    auto_attempt_skill_roll = true,
    drain_lockpick_event = true,
    too_complex_gate = true,
}

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local function log(...)
end

log("[SkillPerkSystem_BasePack][TumblerSense] runtime script loaded")
local trackedToolState = nil
local appliedSkillBonus = 0

local EQUIPMENT_SLOT = (types.Actor ~= nil and types.Actor.EQUIPMENT_SLOT) or {}
local TRACKED_SLOTS = {
    {
        slot = EQUIPMENT_SLOT.CarriedRight,
        label = "CarriedRight",
    },
    {
        slot = EQUIPMENT_SLOT.CarriedLeft,
        label = "CarriedLeft",
    },
}

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

local function classifySecurityTool(item)
    if item == nil then
        return nil
    end
    if types.Lockpick.objectIsInstance(item) then
        return "Lockpick"
    end
    if types.Probe.objectIsInstance(item) then
        return "Probe"
    end
    return nil
end

local function toolMaxCondition(item)
    if item == nil then
        return nil
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    if types.Lockpick.objectIsInstance(item) and type(types.Lockpick.records) == "table" then
        local record = types.Lockpick.records[recordId]
        if type(record) == "table" and type(record.maxCondition) == "number" then
            return record.maxCondition
        end
    end

    if types.Probe.objectIsInstance(item) and type(types.Probe.records) == "table" then
        local record = types.Probe.records[recordId]
        if type(record) == "table" and type(record.maxCondition) == "number" then
            return record.maxCondition
        end
    end

    return nil
end

local function resolveItemCondition(item)
    if item == nil then
        return nil
    end

    if types.Item ~= nil and type(types.Item.itemData) == "function" then
        local ok, data = pcall(types.Item.itemData, item)
        if ok and data ~= nil and type(data.condition) == "number" then
            return data.condition
        end
    end

    if type(item.type) == "table" and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and data ~= nil and type(data.condition) == "number" then
            return data.condition
        end
    end

    return toolMaxCondition(item)
end

local function getEquippedItem(slot)
    if types.Actor == nil or type(types.Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local ok, item = pcall(types.Actor.getEquipment, pself, slot)
    if not ok then
        return nil
    end
    return item
end

local function findEquippedSecurityTool()
    for _, slotInfo in ipairs(TRACKED_SLOTS) do
        local item = getEquippedItem(slotInfo.slot)
        local toolType = classifySecurityTool(item)
        if toolType ~= nil then
            return {
                item = item,
                slot = slotInfo.slot,
                slotName = slotInfo.label,
                toolType = toolType,
                condition = resolveItemCondition(item),
                lastComparableCondition = nil,
            }
        end
    end
    return nil
end

local function sameItem(a, b)
    if a == nil or b == nil then
        return false
    end
    return a.item == b.item and a.slot == b.slot
end

local function withLastComparableCondition(previousState, currentState)
    if currentState == nil then
        return nil
    end

    if type(currentState.condition) == "number" then
        currentState.lastComparableCondition = currentState.condition
        return currentState
    end

    if previousState ~= nil and sameItem(previousState, currentState) and type(previousState.lastComparableCondition) == "number" then
        currentState.lastComparableCondition = previousState.lastComparableCondition
        return currentState
    end

    return currentState
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

    local currentApplied = clamp(appliedSkillBonus, 0, getMaxStacks())
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
    appliedSkillBonus = desiredApplied

    log(string.format(
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
        log(string.format(
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
        appliedSkillBonus = 0
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

    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] %s (bonusPerStack=%.2f maxStacks=%d decaySeconds=%.2f)",
        enabled and "enabled" or "disabled",
        getBonusPerStack(),
        getMaxStacks(),
        getSharedDecaySeconds()
    ))
end

local function handleFailure(data)
    if type(data) ~= "table" then
        log("[SkillPerkSystem_BasePack][TumblerSense] failure ignored reason=invalid-payload normalizedSource=unknown accepted=false")
        return
    end

    local rawSource = type(data.source) == "string" and data.source or DEFAULT_FAILURE_SOURCE
    local normalizedSource = FAILURE_SOURCE_ALIASES[rawSource] or rawSource
    local sourceAccepted = ACCEPTED_FAILURE_SOURCES[normalizedSource] == true

    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] failure source debug raw=%s normalized=%s accepted=%s",
        tostring(rawSource),
        tostring(normalizedSource),
        tostring(sourceAccepted)
    ))

    if not sourceAccepted then
        log(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] failure ignored source=%s normalizedSource=%s mode=%s accepted=%s",
            tostring(rawSource),
            tostring(normalizedSource),
            tostring(data.probe == true and "probe" or "lockpick"),
            tostring(sourceAccepted)
        ))
        return
    end

    if not tumblerSenseEnabled() then
        log(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] failure ignored source=%s normalizedSource=%s mode=%s accepted=%s reason=perk-disabled-or-missing",
            tostring(rawSource),
            tostring(normalizedSource),
            tostring(data.probe == true and "probe" or "lockpick"),
            tostring(sourceAccepted)
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
    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] stack gain source=%s normalizedSource=%s mode=%s accepted=%s stacks=%d->%d bonus=%.2f",
        tostring(rawSource),
        tostring(normalizedSource),
        tostring(data.probe == true and "probe" or "lockpick"),
        tostring(sourceAccepted),
        previousStacks,
        nextStacks,
        bonus
    ))
    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] timer refresh source=%s normalizedSource=%s accepted=%s expiry=%.2f now=%.2f",
        tostring(rawSource),
        tostring(normalizedSource),
        tostring(sourceAccepted),
        expiry,
        nowTimestamp()
    ))
end

local function handleRefreshChance(data)
    clearExpiredStacks("chance-refresh")

    if not tumblerSenseEnabled() then
        log("[SkillPerkSystem_BasePack][TumblerSense] chance refresh skipped reason=perk-disabled-or-missing")
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

    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] chance bonus applied source=%s mode=%s stacks=%d bonus=%.2f",
        tostring(type(data) == "table" and data.source or "unknown"),
        tostring(type(data) == "table" and (data.probe == true and "probe" or "lockpick") or "unknown"),
        stackCount,
        bonus
    ))
    if type(baseChance) == "number" then
        log(string.format(
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

    if not tumblerSenseEnabled() then
        trackedToolState = nil
        return
    end

    local previousState = trackedToolState
    local currentState = withLastComparableCondition(previousState, findEquippedSecurityTool())
    trackedToolState = currentState

    if previousState == nil or currentState == nil or not sameItem(previousState, currentState) then
        return
    end

    local oldCondition = previousState.lastComparableCondition
    local newCondition = currentState.condition
    if type(oldCondition) ~= "number" or type(newCondition) ~= "number" or newCondition >= oldCondition then
        return
    end

    local spentPoints = math.floor(oldCondition - newCondition)
    if spentPoints < 1 then
        spentPoints = 1
    end

    for _ = 1, spentPoints do
        handleFailure({
            source = CONDITION_FAILURE_SOURCE,
            probe = currentState.toolType == "Probe",
        })
    end
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
