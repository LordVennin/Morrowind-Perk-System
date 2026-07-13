-- Consolidated PLAYER runtime for SkillPerkSystem_BasePack.
-- Supersedes the individual *_runtime.lua PLAYER scripts; keep register.lua separate.

local __basepack_subsystems = {}
local __basepack_repair_tool_state = {
    item = nil,
    recordId = nil,
    lastCondition = nil,
    source = nil,
}

----------------------------------------------------------------------
-- steady hands logic (from steady_hands_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local ui = require("openmw.ui")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local DEFAULT_NO_CONSUME_CHANCE = 0.15
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_SteadyHands_Toggle"
local TOOL_DRAIN_EVENT = "SkillPerkSystem_BasePack_SteadyHands_ToolDrain"
local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local STEADY_HANDS_PERK_ID = "security_steady_hands"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local function log(...)
end


local trackedToolState = nil
local conditionDebugFramesRemaining = 1
local conditionSourceDebugFramesRemaining = 60
local slotLabel
local TOOL_TRACKING_SCAN_WINDOW = 1.0
local TOOL_TRACKING_SCAN_INTERVAL = 0.2
local TOOL_EQUIP_POLL_INTERVAL = 0.2
local toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
local toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
local toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
-- Fallback condition tracking can miss intermediate onUpdate frames. When that
-- happens we treat each lost condition point as one consumed-use attempt, but
-- cap rolls per update to avoid runaway refunds after large desyncs.
local MAX_CONDITION_ROLLS_PER_UPDATE = 8

local EQUIPMENT_SLOT = types.Actor.EQUIPMENT_SLOT or {}

local function clampChance(value)
    if type(value) ~= "number" then
        return DEFAULT_NO_CONSUME_CHANCE
    end
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function steadyHandsEnabled()
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(STEADY_HANDS_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(STEADY_HANDS_PERK_ID) then
        return false
    end

    return true
end

local function steadyHandsNoConsumeChance()
    return clampChance(effectsSection:get(NO_CONSUME_CHANCE_KEY))
end

local function classifyTool(item)
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

local function itemData(item)
    if item == nil then
        return nil
    end

    local function isReadableItemData(data)
        if data == nil then
            return false
        end

        if type(data) == "table" then
            return true
        end

        local ok = pcall(function()
            return data.condition
        end)
        return ok
    end

    if type(item.type) == "table" and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and isReadableItemData(data) then
            return data
        end
    end

    if types.Item ~= nil and type(types.Item.itemData) == "function" then
        local ok, data = pcall(types.Item.itemData, item)
        if ok and isReadableItemData(data) then
            return data
        end
    end

    if item.type ~= nil and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and isReadableItemData(data) then
            return data
        end
    end

    if isReadableItemData(item.itemData) then
        return item.itemData
    end

    return nil
end

local function itemDataCondition(item)
    local data = itemData(item)
    if data == nil then
        return nil
    end

    local ok, condition = pcall(function()
        return data.condition
    end)
    if ok and type(condition) == "number" then
        return condition
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

    -- Primary fallback source for max condition:
    -- item.recordId + types.Lockpick.records[...] / types.Probe.records[...]
    -- Defensive guards remain in place for absent recordId or missing record entries.
    local recordTable = nil
    if types.Lockpick.objectIsInstance(item) then
        local records = types.Lockpick.records
        if type(records) == "table" then
            recordTable = records
        end
    elseif types.Probe.objectIsInstance(item) then
        local records = types.Probe.records
        if type(records) == "table" then
            recordTable = records
        end
    end

    if recordTable == nil then
        return nil
    end

    local record = recordTable[recordId]
    if type(record) == "table" and type(record.maxCondition) == "number" then
        return record.maxCondition
    end

    return nil
end

local function normalizeCondition(value)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function resolveItemCondition(item)
    local rawCondition = normalizeCondition(itemDataCondition(item))
    local maxConditionFallback = nil
    local effectiveCondition = rawCondition
    if effectiveCondition == nil then
        maxConditionFallback = normalizeCondition(toolMaxCondition(item))
        effectiveCondition = maxConditionFallback
    end

    return effectiveCondition, {
        rawCondition = rawCondition,
        maxConditionFallback = maxConditionFallback,
        effectiveCondition = effectiveCondition,
        recordId = item ~= nil and item.recordId or nil,
        toolType = classifyTool(item),
    }
end

local function itemCondition(item)
    -- Keep condition normalization and fallback logic in one place so callers
    -- only see nil when no numeric condition can be derived at all.
    local effectiveCondition = resolveItemCondition(item)
    return effectiveCondition
end

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

local function getEquippedItemForSlot(slotInfo)
    if type(slotInfo) ~= "table" then
        return nil
    end

    local slot = slotInfo.slot
    if slot == nil then
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
        local item = getEquippedItemForSlot(slotInfo)
        local toolType = classifyTool(item)
        if toolType ~= nil then
            local condition, conditionDebug = resolveItemCondition(item)
            return {
                slot = slotInfo.slot,
                slotName = slotInfo.label,
                item = item,
                toolType = toolType,
                condition = condition,
                conditionDebug = conditionDebug,
            }
        end
    end

    return nil
end

local function logConditionDebugForFrame(iteratedState)
    if conditionDebugFramesRemaining <= 0 then
        return
    end

    local carriedRight = getEquippedItemForSlot({
        slot = EQUIPMENT_SLOT.CarriedRight,
        label = "CarriedRight",
    })

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands][debug] frame compare iteratedCondition=%s iteratedSlot=%s explicitCarriedRightCondition=%s",
        tostring(iteratedState ~= nil and iteratedState.condition or nil),
        tostring(iteratedState ~= nil and slotLabel(iteratedState.slot, iteratedState.slotName) or nil),
        tostring(itemCondition(carriedRight))
    ))

    conditionDebugFramesRemaining = conditionDebugFramesRemaining - 1
    if conditionDebugFramesRemaining == 0 then
        log("[SkillPerkSystem_BasePack][SteadyHands][debug] condition comparison diagnostics complete; disabling debug output")
    end
end

local function logConditionSourceDebugForFrame(iteratedState)
    if conditionSourceDebugFramesRemaining <= 0 then
        return
    end

    local debugInfo = iteratedState ~= nil and iteratedState.conditionDebug or nil
    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands][debug] condition source rawCondition=%s maxConditionFallback=%s effectiveCondition=%s recordId=%s toolType=%s",
        tostring(debugInfo ~= nil and debugInfo.rawCondition or nil),
        tostring(debugInfo ~= nil and debugInfo.maxConditionFallback or nil),
        tostring(debugInfo ~= nil and debugInfo.effectiveCondition or nil),
        tostring(debugInfo ~= nil and debugInfo.recordId or nil),
        tostring(debugInfo ~= nil and debugInfo.toolType or nil)
    ))

    conditionSourceDebugFramesRemaining = conditionSourceDebugFramesRemaining - 1
    if conditionSourceDebugFramesRemaining == 0 then
        log("[SkillPerkSystem_BasePack][SteadyHands][debug] condition source diagnostics complete; disabling debug output")
    end
end

local function sameItem(a, b)
    if a == nil or b == nil then
        return false
    end
    return a.item == b.item and a.slot == b.slot
end

slotLabel = function(slot, slotName)
    if type(slotName) == "string" and slotName ~= "" then
        return slotName
    end

    for name, value in pairs(EQUIPMENT_SLOT) do
        if value == slot then
            return name
        end
    end
    return tostring(slot)
end

local function logToolState(prefix, state)
    if state == nil then
        log("[SkillPerkSystem_BasePack][SteadyHands] " .. prefix .. " no equipped lockpick/probe detected")
        return
    end

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] %s slot=%s type=%s condition=%s",
        prefix,
        slotLabel(state.slot, state.slotName),
        tostring(state.toolType),
        tostring(state.condition)
    ))
end

local handleModifyToolConditionEvent

local function applyToolConditionRefund(toolState, refundCount)
    if toolState == nil or toolState.item == nil then
        return false
    end

    if type(refundCount) ~= "number" or refundCount <= 0 then
        return false
    end

    local toolType = classifyTool(toolState.item)
    if toolType == nil then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] refund skipped (tool no longer lockpick/probe) slot=%s type=%s amount=%d",
            slotLabel(toolState.slot, toolState.slotName),
            tostring(toolState.toolType),
            refundCount
        ))
        return false
    end

    core.sendGlobalEvent(MODIFY_SECURITY_TOOL_CONDITION_EVENT, {
        player = pself,
        slot = toolState.slot,
        amount = refundCount,
    })
    return true
end

local function resolveToolFromEventData(data)
    if type(data) ~= "table" then
        return nil, nil
    end

    local tool = data.item
    if tool ~= nil then
        return tool, data.slot
    end

    local slot = data.slot
    if slot == nil then
        return nil, nil
    end

    local ok, equipped = pcall(types.Actor.getEquipment, pself, slot)
    if not ok then
        return nil, slot
    end
    return equipped, slot
end

handleModifyToolConditionEvent = function(data)
    if type(data) ~= "table" then
        return false
    end

    local amount = tonumber(data.amount) or 0
    if amount == 0 then
        return false
    end

    local tool, slot = resolveToolFromEventData(data)
    if tool == nil then
        return false
    end

    local toolType = classifyTool(tool)
    if toolType == nil then
        return false
    end

    local dataView = itemData(tool)
    if dataView == nil then
        return false
    end

    local currentCondition = itemCondition(tool)
    if type(currentCondition) ~= "number" then
        return false
    end

    local maxCondition = normalizeCondition(toolMaxCondition(tool))
    if maxCondition ~= nil and currentCondition >= maxCondition and amount > 0 then
        return false
    end

    local newCondition = currentCondition + amount
    if maxCondition ~= nil and newCondition > maxCondition then
        newCondition = maxCondition
    end

    if newCondition <= 0 then
        local okRemove = pcall(function()
            tool:remove()
        end)
        return okRemove
    end

    local okWrite = pcall(function()
        dataView.condition = newCondition
    end)
    if not okWrite then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] refund write failed slot=%s type=%s amount=%s current=%s target=%s",
            slotLabel(slot, data.slotName),
            tostring(toolType),
            tostring(amount),
            tostring(currentCondition),
            tostring(newCondition)
        ))
    end
    return okWrite
end

local function rollAndRefund(toolState, contextLabel, attempts)
    if toolState == nil or toolState.item == nil then
        return
    end

    local toolType = classifyTool(toolState.item)
    if toolType == nil then
        return
    end

    if not steadyHandsEnabled() then
        log(string.format("[SkillPerkSystem_BasePack][SteadyHands] perk disabled; skipping refund roll (%s)", tostring(contextLabel)))
        return
    end

    local rollAttempts = tonumber(attempts) or 1
    if rollAttempts < 1 then
        return
    end

    local chance = steadyHandsNoConsumeChance()
    local refundCount = 0
    for _ = 1, rollAttempts do
        if math.random() < chance then
            refundCount = refundCount + 1
        end
    end

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] refund roll source=%s slot=%s type=%s attempts=%d chance=%.2f refunded=%d",
        tostring(contextLabel),
        slotLabel(toolState.slot, toolState.slotName),
        tostring(toolType),
        rollAttempts,
        chance,
        refundCount
    ))

    if refundCount <= 0 then
        return
    end

    local applied = applyToolConditionRefund(toolState, refundCount)

    if applied then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] refund fired source=%s slot=%s type=%s amount=%d",
            tostring(contextLabel),
            slotLabel(toolState.slot, toolState.slotName),
            tostring(toolType),
            refundCount
        ))
        return
    end

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] refund failed source=%s slot=%s type=%s amount=%d",
        tostring(contextLabel),
        slotLabel(toolState.slot, toolState.slotName),
        tostring(toolType),
        refundCount
    ))
end

local withLastComparableCondition

local function handleToolDrainEvent(data)
    if type(data) ~= "table" then
        return
    end

    local item, slot = resolveToolFromEventData(data)
    local toolType = classifyTool(item)
    if toolType == nil then
        return
    end

    local toolState = {
        slot = slot or data.slot,
        slotName = data.slotName,
        item = item,
        toolType = toolType,
        condition = itemCondition(item),
    }

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] tool drain event received slot=%s type=%s condition=%s",
        slotLabel(toolState.slot, toolState.slotName),
        tostring(toolType),
        tostring(toolState.condition)
    ))

    rollAndRefund(toolState, "event")
    toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
    trackedToolState = withLastComparableCondition(trackedToolState, toolState)
end

withLastComparableCondition = function(previousState, currentState)
    if currentState == nil then
        return nil
    end

    local state = {
        slot = currentState.slot,
        slotName = currentState.slotName,
        item = currentState.item,
        toolType = currentState.toolType,
        condition = currentState.condition,
        conditionDebug = currentState.conditionDebug,
        lastComparableCondition = nil,
    }

    if type(currentState.condition) == "number" then
        state.lastComparableCondition = currentState.condition
        return state
    end

    if previousState ~= nil and sameItem(previousState, currentState) and type(previousState.lastComparableCondition) == "number" then
        state.lastComparableCondition = previousState.lastComparableCondition
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] condition read nil; keeping previous comparable condition slot=%s type=%s previousCondition=%s",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            tostring(previousState.lastComparableCondition)
        ))
        return state
    end

    return state
end

local function maybeRefundCondition(previousState, currentState)
    if previousState == nil then
        return
    end

    if currentState == nil then
        -- Fallback for edge cases where the equipped tool disappears before the
        -- next frame comparison (e.g., final durability consumed and item removed).
        -- We only treat this as a break/consume event when we had a comparable
        -- condition value and it was at or below one use remaining.
        local previousCondition = previousState.lastComparableCondition
        if type(previousCondition) ~= "number" then
            return
        end

        if previousCondition <= 1 then
            log(string.format(
                "[SkillPerkSystem_BasePack][SteadyHands] tool disappeared before compare; treating as break-consume event slot=%s type=%s previousCondition=%s",
                slotLabel(previousState.slot, previousState.slotName),
                tostring(previousState.toolType),
                tostring(previousCondition)
            ))
            rollAndRefund(previousState, "onUpdate-disappeared-tool", 1)
        else
            log(string.format(
                "[SkillPerkSystem_BasePack][SteadyHands] tool disappeared before compare; no break refund (previousCondition=%s > 1) slot=%s type=%s",
                tostring(previousCondition),
                slotLabel(previousState.slot, previousState.slotName),
                tostring(previousState.toolType)
            ))
        end
        return
    end

    if not sameItem(previousState, currentState) then
        return
    end

    local oldCondition = previousState.lastComparableCondition
    local newCondition = currentState.condition

    if type(oldCondition) == "number" and type(newCondition) ~= "number" then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] condition transitioned number->nil slot=%s type=%s previousCondition=%s",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            tostring(oldCondition)
        ))
        return
    end

    if type(oldCondition) ~= "number" and type(newCondition) == "number" then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] condition transitioned nil->number slot=%s type=%s condition=%s",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            tostring(newCondition)
        ))
        return
    end

    if type(oldCondition) ~= "number" or type(newCondition) ~= "number" then
        return
    end

    if newCondition >= oldCondition then
        return
    end

    log(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] tool use detected slot=%s type=%s conditionBefore=%d conditionAfter=%d",
        slotLabel(currentState.slot, currentState.slotName),
        tostring(currentState.toolType),
        oldCondition,
        newCondition
    ))

    local delta = oldCondition - newCondition
    if delta <= 0 then
        return
    end

    local spentPoints = math.floor(delta)
    if spentPoints < 1 then
        spentPoints = 1
    end

    -- Chosen policy: one roll per lost condition point (consumed use), with a
    -- per-update cap. This preserves expected value for multi-point drops while
    -- still bounding refunds if several updates were skipped.
    local rollAttempts = math.min(spentPoints, MAX_CONDITION_ROLLS_PER_UPDATE)
    if spentPoints > rollAttempts then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] multi-point drop detected source=onUpdate-fallback slot=%s type=%s delta=%d policy=per-point-with-cap cap=%d",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            spentPoints,
            MAX_CONDITION_ROLLS_PER_UPDATE
        ))
    elseif spentPoints > 1 then
        log(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] multi-point drop detected source=onUpdate-fallback slot=%s type=%s delta=%d policy=per-point",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            spentPoints
        ))
    end

    rollAndRefund(currentState, "onUpdate-fallback", rollAttempts)
end

local function shouldUpdate(dt)
    if conditionDebugFramesRemaining > 0 or conditionSourceDebugFramesRemaining > 0 then
        return true
    end

    if not steadyHandsEnabled() then
        trackedToolState = nil
        return false
    end

    local deltaTime = tonumber(dt) or 0
    toolTrackingScanRemaining = math.max(0, toolTrackingScanRemaining - deltaTime)

    if toolTrackingScanRemaining <= 0 then
        toolEquipPollTimer = toolEquipPollTimer + deltaTime
        if toolEquipPollTimer < TOOL_EQUIP_POLL_INTERVAL then
            return false
        end

        toolEquipPollTimer = 0
        if findEquippedSecurityTool() == nil then
            trackedToolState = nil
            return false
        end

        -- A security tool is currently equipped, so keep the condition
        -- comparison fallback alive while the pick/probe can actually lose uses.
        toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
        toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
        toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
    end

    toolTrackingScanTimer = toolTrackingScanTimer + deltaTime
    if toolTrackingScanTimer < TOOL_TRACKING_SCAN_INTERVAL then
        return false
    end

    toolTrackingScanTimer = 0
    return true
end

local function onUpdate()
    local currentState = findEquippedSecurityTool()
    logConditionDebugForFrame(currentState)
    logConditionSourceDebugForFrame(currentState)

    local previousState = trackedToolState
    local normalizedCurrentState = withLastComparableCondition(previousState, currentState)

    if previousState == nil and normalizedCurrentState ~= nil then
        logToolState("tracking started", normalizedCurrentState)
    elseif previousState ~= nil and normalizedCurrentState == nil then
        logToolState("tracking stopped", nil)
    elseif previousState ~= nil and normalizedCurrentState ~= nil and not sameItem(previousState, normalizedCurrentState) then
        logToolState("tracking switched", normalizedCurrentState)
    end

    maybeRefundCondition(previousState, normalizedCurrentState)
    trackedToolState = normalizedCurrentState
end

local function handleSteadyHandsToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)
    if enabled then
        effectsSection:set(NO_CONSUME_CHANCE_KEY, clampChance(data.chance))
        toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
        toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
    else
        effectsSection:set(NO_CONSUME_CHANCE_KEY, 0.0)
        trackedToolState = nil
        toolTrackingScanRemaining = 0
        toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
    end

    log(string.format("[SkillPerkSystem_BasePack] Steady Hands %s (chance=%.2f)", enabled and "enabled" or "disabled", effectsSection:get(NO_CONSUME_CHANCE_KEY) or 0.0))
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleSteadyHandsToggle,
        [TOOL_DRAIN_EVENT] = handleToolDrainEvent,
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = handleModifyToolConditionEvent,
    },
}

end

----------------------------------------------------------------------
-- tumbler sense logic (from tumbler_sense_runtime.lua)
----------------------------------------------------------------------
do
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
local TOOL_TRACKING_SCAN_WINDOW = 1.0
local TOOL_TRACKING_SCAN_INTERVAL = 0.2
local TOOL_EQUIP_POLL_INTERVAL = 0.2
local toolTrackingScanRemaining = 0
local toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
local toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL

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

local function getActorObject()
    return pself.object or pself
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

local function getBonusPerFailedAttempt()
    local increment = tonumber(effectsSection:get(BONUS_PER_STACK_KEY))
    if type(increment) ~= "number" then
        return 1
    end
    return math.max(1, math.floor(increment))
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

    local currentApplied = clamp(tonumber(appliedSkillBonus) or 0, 0, getMaxStacks())
    local desiredApplied = clamp(tonumber(targetBonus) or 0, 0, getMaxStacks())
    if currentApplied == desiredApplied then
        return
    end

    local okStat, stat = pcall(accessor, pself)
    if not okStat or stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    -- Apply stack bonus via non-base modifier channel so Security base is never mutated.
    local newModifier = stat.modifier - currentApplied + desiredApplied
    local okWrite = pcall(function()
        stat.modifier = newModifier
    end)
    if not okWrite then
        return
    end
    appliedSkillBonus = desiredApplied

    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] security modifier adjusted appliedBonus=%d->%d resultingModifier=%d",
        currentApplied,
        desiredApplied,
        newModifier
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
    local bonus = stackCount / 100
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
        toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
        toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
        toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
        if (tonumber(appliedSkillBonus) or 0) > 0 then
            applySecuritySkillBonus(0)
        end
        effectsSection:set(STACK_COUNT_KEY, 0)
        effectsSection:set(EXPIRY_TIMESTAMP_KEY, nil)
        effectsSection:set(ACTIVE_BONUS_KEY, 0.0)

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
        trackedToolState = nil
        toolTrackingScanRemaining = 0
        toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
    end

    log(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] %s (bonusPerFailedAttempt=%.2f maxStacks=%d decaySeconds=%.2f)",
        enabled and "enabled" or "disabled",
        getBonusPerFailedAttempt(),
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
    local nextStacks = math.min(previousStacks + getBonusPerFailedAttempt(), getMaxStacks())
    local expiry = nowTimestamp() + getSharedDecaySeconds()
    effectsSection:set(STACK_COUNT_KEY, nextStacks)
    effectsSection:set(EXPIRY_TIMESTAMP_KEY, expiry)

    local _, bonus = currentBonus()
    toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
    toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
    toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
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

local function shouldUpdate(dt)
    local stackCount = tonumber(effectsSection:get(STACK_COUNT_KEY)) or 0
    if stackCount > 0 or appliedSkillBonus ~= 0 then
        return true
    end

    if not tumblerSenseEnabled() then
        trackedToolState = nil
        return false
    end

    local deltaTime = tonumber(dt) or 0
    toolTrackingScanRemaining = math.max(0, toolTrackingScanRemaining - deltaTime)

    if toolTrackingScanRemaining <= 0 then
        toolEquipPollTimer = toolEquipPollTimer + deltaTime
        if toolEquipPollTimer < TOOL_EQUIP_POLL_INTERVAL then
            return false
        end

        toolEquipPollTimer = 0
        if findEquippedSecurityTool() == nil then
            trackedToolState = nil
            return false
        end

        -- Keep Tumbler Sense's consolidated fallback active while a pick/probe
        -- is equipped, so vanilla or non-bridged lockpick drains still grant stacks.
        toolTrackingScanRemaining = TOOL_TRACKING_SCAN_WINDOW
        toolTrackingScanTimer = TOOL_TRACKING_SCAN_INTERVAL
        toolEquipPollTimer = TOOL_EQUIP_POLL_INTERVAL
    end

    toolTrackingScanTimer = toolTrackingScanTimer + deltaTime
    if toolTrackingScanTimer < TOOL_TRACKING_SCAN_INTERVAL then
        return false
    end

    toolTrackingScanTimer = 0
    return true
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

__basepack_subsystems[#__basepack_subsystems + 1] = {
    interfaceName = RUNTIME_INTERFACE_NAME,
    interface = {
        requestRefreshChance = requestRefreshChance,
        getActiveBonusFraction = getActiveBonusFraction,
        getActiveBonusPercentPoints = getActiveBonusPercentPoints,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        [FAILURE_EVENT] = handleFailure,
        [REFRESH_CHANCE_EVENT] = handleRefreshChance,
    },
}

end

----------------------------------------------------------------------
-- quick pick logic (from quick_pick_runtime.lua)
----------------------------------------------------------------------
local function animationStringMethod(value, methodName)
    if type(value) ~= "string" then
        return nil
    end

    return value[methodName]
end

local function animationKeyLower(value)
    local lower = animationStringMethod(value, "lower")
    if type(lower) ~= "function" then
        return ""
    end

    return lower(value)
end

local function animationStringContains(value, needle)
    local find = animationStringMethod(value, "find")
    return type(find) == "function" and find(value, needle, 1, true) ~= nil
end

local function animationStringEndsWith(value, suffix)
    local sub = animationStringMethod(value, "sub")
    if type(sub) ~= "function" or #value < #suffix then
        return false
    end

    return sub(value, #value - #suffix + 1) == suffix
end

local function multiplyAnimationSpeed(options, multiplier)
    if type(options) ~= "table" then
        return
    end

    local currentSpeed = type(options.speed) == "number" and options.speed or 1.0
    options.speed = currentSpeed * multiplier
end

local function classifyBlendedAnimationEvent(groupName, options)
    local hasOptions = type(options) == "table"
    local hasGroupName = type(groupName) == "string"
    local groupLower = animationKeyLower(groupName)
    local startKeyRaw = hasOptions and (options.startkey or options.startKey) or nil
    local stopKeyRaw = hasOptions and (options.stopkey or options.stopKey) or nil
    local startKeyLower = animationKeyLower(startKeyRaw)
    local stopKeyLower = animationKeyLower(stopKeyRaw)
    local isAttackGroup = animationStringContains(groupLower, "attack")
    local isMaxAttack = animationStringEndsWith(stopKeyLower, " max attack")
    local isHit = animationStringEndsWith(stopKeyLower, "hit") and not animationStringEndsWith(stopKeyLower, "min hit")
    local isChopStart = startKeyLower == "chop start"
    local isSlashStart = startKeyLower == "slash start"
    local isThrustStart = startKeyLower == "thrust start"
    local isChopMaxAttack = stopKeyLower == "chop max attack"
    local isSlashMaxAttack = stopKeyLower == "slash max attack"
    local isThrustMaxAttack = stopKeyLower == "thrust max attack"

    return {
        groupName = groupName,
        groupLower = groupLower,
        hasGroupName = hasGroupName,
        options = options,
        hasOptions = hasOptions,
        startKey = startKeyRaw,
        stopKey = stopKeyRaw,
        startKeyLower = startKeyLower,
        stopKeyLower = stopKeyLower,
        isAttackGroup = isAttackGroup,
        isMaxAttack = isMaxAttack,
        isHit = isHit,
        isWeaponAttackWindup = hasOptions and (isMaxAttack or isAttackGroup),
        isChopAttackWindup = hasOptions and (isChopStart or isChopMaxAttack),
        isBluntAttackShape = hasOptions and (
            isChopStart
            or isSlashStart
            or isThrustStart
            or isChopMaxAttack
            or isSlashMaxAttack
            or isThrustMaxAttack
        ),
        isHandToHandAttackShape = hasOptions and (
            (animationStringEndsWith(startKeyLower, " start") and animationStringContains(startKeyLower, "attack"))
            or isMaxAttack
            or isHit
            or isAttackGroup
        ),
        isToolUseShape = hasGroupName and (
            animationStringContains(groupLower, "pick")
            or animationStringContains(groupLower, "probe")
            or animationStringContains(groupLower, "lock")
            or animationStringContains(groupLower, "security")
            or animationStringContains(startKeyLower, "pick")
            or animationStringContains(startKeyLower, "probe")
            or animationStringContains(stopKeyLower, "pick")
            or animationStringContains(stopKeyLower, "probe")
        ),
    }
end

local __basepack_animation_handlers = {}
local dispatchBasepackAnimationTextKey = nil

local function registerBasepackAnimationHandler(handler)
    __basepack_animation_handlers[#__basepack_animation_handlers + 1] = handler
end

do
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local I = interfaces
local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.quick_pick.enabled"
local TOOL_SPEED_MULTIPLIER_KEY = "security.quick_pick.tool_speed_multiplier"
local DEFAULT_TOOL_SPEED_MULTIPLIER = 1.75
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_QuickPick_Toggle"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local QUICK_PICK_PERK_ID = "security_quick_pick"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local function quickPickEnabled()
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(QUICK_PICK_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(QUICK_PICK_PERK_ID) then
        return false
    end

    return true
end

local function toolSpeedMultiplier()
    local value = tonumber(effectsSection:get(TOOL_SPEED_MULTIPLIER_KEY))
    if type(value) ~= "number" or value < 1 then
        return DEFAULT_TOOL_SPEED_MULTIPLIER
    end
    return value
end

local function getEquippedSecurityTool()
    local right = nil
    local left = nil

    local okRight, rightItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if okRight then
        right = rightItem
    end

    local okLeft, leftItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedLeft)
    if okLeft then
        left = leftItem
    end

    if right and (Lockpick.objectIsInstance(right) or Probe.objectIsInstance(right)) then
        return right
    end

    if left and (Lockpick.objectIsInstance(left) or Probe.objectIsInstance(left)) then
        return left
    end

    return nil
end

local function handleSecurityToolAnimation(event)
    if not event.isToolUseShape then
        return
    end
    if not quickPickEnabled() then
        return
    end
    if getEquippedSecurityTool() == nil then
        return
    end

    multiplyAnimationSpeed(event.options, toolSpeedMultiplier())
end
registerBasepackAnimationHandler(handleSecurityToolAnimation)

local function handleQuickPickToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)

    if enabled then
        local value = tonumber(data.toolSpeedMultiplier)
        if type(value) ~= "number" or value < 1 then
            value = DEFAULT_TOOL_SPEED_MULTIPLIER
        end
        effectsSection:set(TOOL_SPEED_MULTIPLIER_KEY, value)
    else
        effectsSection:set(TOOL_SPEED_MULTIPLIER_KEY, 1.0)
    end
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    eventHandlers = {
        [TOGGLE_EVENT] = handleQuickPickToggle,
    },
}

end

----------------------------------------------------------------------
-- lucky find player logic (from lucky_find_player_runtime.lua)
----------------------------------------------------------------------
do
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local COIN_RECORD_ID_KEY = "security.lucky_find.coin_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"
local DEBUG_LUCKY_FIND = true

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)
local appliedLuckBonus = 0
local lastLoggedCoinCount = nil
local enabledOverride = nil
local luckBonusDirty = true
local luckBonusScanRemaining = 0
local luckBonusScanTimer = 0
local LUCKY_COIN_SCAN_WINDOW = 1.5
local LUCKY_COIN_SCAN_INTERVAL = 0.5

local function log(message)
    if not DEBUG_LUCKY_FIND then
        return
    end
    print("[SkillPerkSystem_BasePack][LuckyFind][Player] " .. tostring(message))
end

local function luckyFindEnabled()
    if enabledOverride ~= nil then
        return enabledOverride == true
    end
    return effectsSection:get(ENABLED_KEY) == true
end

local function clampNonNegativeInteger(value)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then
        return 0
    end
    return n
end

local function countLuckyCoinsInInventory()
    if types.Actor == nil or type(types.Actor.inventory) ~= "function" then
        return 0
    end

    local coinRecordId = effectsSection:get(COIN_RECORD_ID_KEY)
    if type(coinRecordId) ~= "string" or coinRecordId == "" then
        return 0
    end

    local okInventory, inventory = pcall(types.Actor.inventory, pself)
    if not okInventory or inventory == nil or type(inventory.countOf) ~= "function" then
        return 0
    end

    local count = nil

    local okCountA, countA = pcall(function()
        return inventory:countOf(coinRecordId)
    end)
    if okCountA and type(countA) == "number" then
        count = countA
    end

    if (count == nil or count <= 0) and types.Miscellaneous ~= nil then
        local okRecord, record = pcall(function()
            return types.Miscellaneous.records[coinRecordId]
        end)
        if okRecord and record ~= nil then
            local okCountB, countB = pcall(function()
                return inventory:countOf(record)
            end)
            if okCountB and type(countB) == "number" then
                count = countB
            end
        end
    end

    local normalized = clampNonNegativeInteger(count or 0)
    if lastLoggedCoinCount ~= normalized then
        log(string.format("inventory lucky coin count=%d record=%s", normalized, tostring(coinRecordId)))
        lastLoggedCoinCount = normalized
    end

    return normalized
end

local function resolveLuckStat()
    local function tryLuckGetter(t)
        if t == nil then
            return nil
        end

        local okStats, stats = pcall(function()
            return t.stats
        end)
        if not okStats or stats == nil then
            return nil
        end

        local okAttrs, attrs = pcall(function()
            return stats.attributes
        end)
        if not okAttrs or attrs == nil then
            return nil
        end

        local okFn, fn = pcall(function()
            return attrs.luck
        end)
        if not okFn or type(fn) ~= "function" then
            return nil
        end

        local okStat, stat = pcall(fn, pself)
        if not okStat then
            return nil
        end

        return stat
    end

    local okType, actorType = pcall(function()
        return pself.type
    end)
    if not okType then
        return nil
    end

    local stat = tryLuckGetter(actorType)
    if stat ~= nil then
        return stat
    end

    local okBase, baseType = pcall(function()
        return actorType.baseType
    end)
    if okBase and baseType ~= nil then
        return tryLuckGetter(baseType)
    end

    return nil
end

local function applyLuckBonus(targetBonus)
    local desired = clampNonNegativeInteger(targetBonus)
    if desired > 0 and not luckyFindEnabled() then
        desired = 0
    end
    local current = clampNonNegativeInteger(appliedLuckBonus)
    if desired == current then
        return
    end

    local stat = resolveLuckStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        log("unable to resolve writable luck modifier stat for player")
        return
    end

    -- Apply Lucky Coin bonus through the dedicated non-base modifier channel
    -- so base Luck is untouched and only our tracked coin contribution changes.
    local newModifier = math.floor(stat.modifier - current + desired)
    stat.modifier = newModifier
    appliedLuckBonus = desired
    log(string.format("applied luck bonus %d -> %d (new modifier=%d)", current, desired, newModifier))
end

local function markLuckBonusDirty(scanWindow)
    luckBonusDirty = true
    luckBonusScanRemaining = math.max(luckBonusScanRemaining, tonumber(scanWindow) or LUCKY_COIN_SCAN_WINDOW)
    luckBonusScanTimer = LUCKY_COIN_SCAN_INTERVAL
end

local function refreshLuckBonus()
    luckBonusDirty = false
    if not luckyFindEnabled() then
        applyLuckBonus(0)
        return
    end

    applyLuckBonus(countLuckyCoinsInInventory())
end

local function shouldUpdateLuckBonus(dt)
    if luckBonusDirty or appliedLuckBonus ~= 0 and not luckyFindEnabled() then
        return true
    end

    luckBonusScanRemaining = math.max(0, luckBonusScanRemaining - (tonumber(dt) or 0))
    if luckBonusScanRemaining <= 0 then
        return false
    end

    luckBonusScanTimer = luckBonusScanTimer + (tonumber(dt) or 0)
    if luckBonusScanTimer < LUCKY_COIN_SCAN_INTERVAL then
        return false
    end

    luckBonusScanTimer = 0
    return true
end

local function handleToggle(data)
    if type(data) == "table" then
        enabledOverride = data.enable == true
        log(string.format("toggle enable=%s", tostring(data.enable == true)))
    end
    markLuckBonusDirty(LUCKY_COIN_SCAN_WINDOW)
    refreshLuckBonus()
end

local function handleInventoryMaybeChanged()
    markLuckBonusDirty(LUCKY_COIN_SCAN_WINDOW)
end

local function onLoad(data)
    appliedLuckBonus = math.max(0, math.floor(tonumber(type(data) == "table" and data.appliedLuckBonus) or 0))
    lastLoggedCoinCount = nil
    enabledOverride = nil
    markLuckBonusDirty(LUCKY_COIN_SCAN_WINDOW)
    refreshLuckBonus()
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = refreshLuckBonus,
        shouldUpdate = shouldUpdateLuckBonus,
        onLoad = onLoad,
        onSave = function()
            return {
                appliedLuckBonus = appliedLuckBonus,
            }
        end,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        UiModeChanged = handleInventoryMaybeChanged,
    },
}

end

----------------------------------------------------------------------
-- unseen hand player logic (from unseen_hand_runtime.lua)
----------------------------------------------------------------------
do
local interfaces = require("openmw.interfaces")
local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local PERK_ID = "security_unseen_hand"
local PLAYER_TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle"
local LOG_TAG = "[SkillPerkSystem_BasePack][UnseenHand]"

local addSpellFailureLogged = false
local removeSpellFailureLogged = false
local playerSpellsFailureState = nil
local enabledOverride = nil
local spellAddedByRuntime = false
local burglarsInstinctDirty = true
local burglarsInstinctScanRemaining = 0
local burglarsInstinctScanTimer = 0
local BURGLARS_INSTINCT_SCAN_WINDOW = 1.5
local BURGLARS_INSTINCT_SCAN_INTERVAL = 0.25

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function interfaceSaysEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(PERK_ID) then
        return false
    end

    return true
end

local function unseenHandEnabled()
    if enabledOverride ~= nil then
        return enabledOverride == true
    end

    return interfaceSaysEnabled()
end

local function getEquippedSecurityTool()
    local okRight, rightItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if okRight and rightItem and (Lockpick.objectIsInstance(rightItem) or Probe.objectIsInstance(rightItem)) then
        return rightItem
    end

    local okLeft, leftItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedLeft)
    if okLeft and leftItem and (Lockpick.objectIsInstance(leftItem) or Probe.objectIsInstance(leftItem)) then
        return leftItem
    end

    return nil
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if playerSpellsFailureState ~= "unavailable" then
            playerSpellsFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust burglar's instinct state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if playerSpellsFailureState ~= "error" then
            playerSpellsFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust burglar's instinct state")
        end
        return nil
    end

    playerSpellsFailureState = nil
    return spells
end

local function resolveSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[SPELL_RECORD_ID]
end

local function spellBookHasSpell(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(SPELL_RECORD_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveSpellRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == SPELL_RECORD_ID then
            return true
        end
    end

    return false
end

local function addSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(SPELL_RECORD_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(SPELL_RECORD_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function refreshBurglarsInstinctAbility(forceDisable)
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local equippedTool = getEquippedSecurityTool()
    local shouldHave = (not forceDisable) and unseenHandEnabled() and (equippedTool ~= nil)
    local hasSpell = spellBookHasSpell(spells)

    if shouldHave and not hasSpell then
        local okAdd, addError = addSpell(spells)
        if not okAdd then
            if not addSpellFailureLogged then
                addSpellFailureLogged = true
                logDebug(string.format("failed to add %s: %s", SPELL_RECORD_ID, tostring(addError)))
            end
            return
        end
        addSpellFailureLogged = false
        spellAddedByRuntime = true
    elseif (not shouldHave) and (hasSpell or spellAddedByRuntime) then
        local okRemove, removeError = removeSpell(spells)
        if not okRemove then
            if not removeSpellFailureLogged then
                removeSpellFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", SPELL_RECORD_ID, tostring(removeError)))
            end
            return
        end
        removeSpellFailureLogged = false
        spellAddedByRuntime = false
    end
end

local function markBurglarsInstinctDirty(scanWindow)
    burglarsInstinctDirty = true
    burglarsInstinctScanRemaining = math.max(burglarsInstinctScanRemaining, tonumber(scanWindow) or BURGLARS_INSTINCT_SCAN_WINDOW)
    burglarsInstinctScanTimer = BURGLARS_INSTINCT_SCAN_INTERVAL
end

local function onPlayerToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledOverride = data.enable == true
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
    if not enabledOverride then
        refreshBurglarsInstinctAbility(true)
        return
    end

    refreshBurglarsInstinctAbility(false)
end

local function handleBurglarsInventoryMaybeChanged()
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
end

local function shouldUpdateBurglarsInstinct(dt)
    if burglarsInstinctDirty
        or addSpellFailureLogged
        or removeSpellFailureLogged
        or (spellAddedByRuntime and not unseenHandEnabled()) then
        return true
    end

    burglarsInstinctScanRemaining = math.max(0, burglarsInstinctScanRemaining - (tonumber(dt) or 0))
    if burglarsInstinctScanRemaining <= 0 then
        return false
    end

    burglarsInstinctScanTimer = burglarsInstinctScanTimer + (tonumber(dt) or 0)
    if burglarsInstinctScanTimer < BURGLARS_INSTINCT_SCAN_INTERVAL then
        return false
    end

    burglarsInstinctScanTimer = 0
    return true
end

local function onLoad(data)
    enabledOverride = nil
    spellAddedByRuntime = type(data) == "table" and data.spellAddedByRuntime == true
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
    refreshBurglarsInstinctAbility(false)
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function()
            burglarsInstinctDirty = false
            refreshBurglarsInstinctAbility(false)
        end,
        shouldUpdate = shouldUpdateBurglarsInstinct,
        onLoad = onLoad,
        onSave = function()
            return {
                spellAddedByRuntime = spellAddedByRuntime,
            }
        end,
    },
    eventHandlers = {
        [PLAYER_TOGGLE_EVENT] = onPlayerToggle,
        UiModeChanged = handleBurglarsInventoryMaybeChanged,
    },
}

end

----------------------------------------------------------------------
-- block runtime logic (from block_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon
local Lockpick = types.Lockpick
local Probe = types.Probe
local Repair = types.Repair

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LOG_TAG = "[SkillPerkSystem_BasePack][BlockEnchant]"

local HALLOWED_GUARD_PERK_ID = "block_hallowed_guard"
local SHIELD_FUNDAMENTALS_PERK_ID = "block_shield_fundamentals"
local GUARDIANS_HABIT_PERK_ID = "block_guardians_habit"
local STEADY_WALL_PERK_ID = "block_steady_wall"
local BULWARK_OF_LIGHT_PERK_ID = "block_bulwark_of_light"
local AEGIS_RITE_PERK_ID = "block_aegis_rite"
local SPEAR_LONG_GUARD_PERK_ID = "spear_long_guard"
local UNARMORED_UNBURDENED_FORM_PERK_ID = "unarmored_unburdened_form"
local UNARMORED_FLOWING_STEP_PERK_ID = "unarmored_flowing_step"
local UNARMORED_SILK_GUARD_PERK_ID = "unarmored_silk_guard"
local UNARMORED_EMPTY_MAIL_PERK_ID = "unarmored_empty_mail"
local UNARMORED_MASTER_OF_MOTION_PERK_ID = "unarmored_master_of_motion"

local CONFIG_SECTION_ID = "SkillPerkSystem_BasePack_BlockEnchant"
local DEBUG_LOGGING_KEY = "block.enchant.debug"

local DEFAULT_DEBUG_LOGGING = false

local STEADY_WALL_MAX_STACKS = 5
local STEADY_WALL_DURATION = 5.0
local STEADY_WALL_BLOCK_PER_STACK = 4
local STEADY_WALL_ARMOR_PER_STACK = 3
local BLOCK_STATE_REFRESH_INTERVAL = 0.5
local UNARMORED_FLOWING_STEP_AGILITY_BONUS = 5
local UNARMORED_FLOWING_STEP_HIGH_FATIGUE_AGILITY_BONUS = 10
local UNARMORED_FLOWING_STEP_HIGH_FATIGUE_THRESHOLD = 0.75
local UNARMORED_SILK_GUARD_ATTRIBUTE_BONUS = 3
local UNARMORED_SILK_GUARD_HIGH_FATIGUE_ATTRIBUTE_BONUS = 5
local UNARMORED_SILK_GUARD_HIGH_FATIGUE_THRESHOLD = 0.75
local UNARMORED_MASTER_OF_MOTION_FATIGUE_RESTORE_PER_SECOND = 1
local UNARMORED_MASTER_OF_MOTION_MIN_FATIGUE_THRESHOLD = 0.5
local UNARMORED_FLOWING_STEP_APPLIED_KEY = "unarmored.flowing_step.applied_agility_bonus"
local UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY = "unarmored.silk_guard.applied_endurance_bonus"
local UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY = "unarmored.silk_guard.applied_willpower_bonus"

local HALLOWED_GUARD_ABILITY_ID = "sps_hallowedguard"
local UNARMORED_EMPTY_MAIL_ABILITY_ID = "sps_unarmoredbuff"
local BULWARK_SELF_SPELL_ID = "sps_bullightself"
local AEGIS_RITE_WINDOW = 3.0
local AEGIS_RITE_MAGICKA_COST = 5

local configSection = storage.playerSection(CONFIG_SECTION_ID)
local unarmoredRuntimeSection = storage.playerSection(CONFIG_SECTION_ID .. "_Unarmored")
local baseCombatInterface = nil
local momentumExpirations = {}
local runtimeTime = 0
local hallowedGuardApplied = false
local hallowedGuardAddFailureLogged = false
local hallowedGuardRemoveFailureLogged = false
local unarmoredEmptyMailApplied = false
local unarmoredEmptyMailAddFailureLogged = false
local unarmoredEmptyMailRemoveFailureLogged = false
local hallowedGuardSpellBookFailureState = nil
local blockStateRefreshTimer = BLOCK_STATE_REFRESH_INTERVAL
local blockStateRefreshDue = false
local appliedUnarmoredFlowingStepAgilityBonus = tonumber(unarmoredRuntimeSection:get(UNARMORED_FLOWING_STEP_APPLIED_KEY)) or 0
local appliedUnarmoredSilkGuardEnduranceBonus = tonumber(unarmoredRuntimeSection:get(UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY)) or 0
local appliedUnarmoredSilkGuardWillpowerBonus = tonumber(unarmoredRuntimeSection:get(UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY)) or 0

local function logDebug(message)
    if configSection:get(DEBUG_LOGGING_KEY) == true then
        print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
    end
end

local function getBaseCombatFunction(name)
    if baseCombatInterface == nil then
        return nil
    end

    local fn = baseCombatInterface[name]
    if type(fn) == "function" then
        return fn
    end

    return nil
end

local function passthrough(name)
    return function(...)
        local fn = getBaseCombatFunction(name)
        if fn ~= nil then
            return fn(...)
        end
        return nil
    end
end

local function getEquippedItem(actor, slot)
    if actor == nil or Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local ok, equipped = pcall(Actor.getEquipment, actor, slot)
    if not ok then
        return nil
    end

    return equipped
end

local function getEquippedShield(actor)
    if actor == nil or Actor == nil then
        return nil, nil
    end

    local carriedLeftSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedLeft or nil
    if carriedLeftSlot == nil then
        return nil, nil
    end

    local equipped = getEquippedItem(actor, carriedLeftSlot)
    if equipped == nil then
        return nil, nil
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return nil, nil
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, equipped)
        if okRecord then
            record = value
        end
    end

    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil, nil
    end

    return equipped, record
end

local function getEquippedRightHand(actor)
    if actor == nil or Actor == nil then
        return nil
    end

    local rightSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedRight or nil
    if rightSlot == nil then
        return nil
    end

    return getEquippedItem(actor, rightSlot)
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local ok, record = pcall(Weapon.record, item)
        if ok and record ~= nil then
            return record
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    return nil
end

local function isOneHandedWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil then
        return true
    end

    local weaponType = tonumber(record.type)
    if weaponType == nil then
        return true
    end

    if weaponType == 2 then return false end
    if weaponType == 4 then return false end
    if weaponType == 5 then return false end
    if weaponType == 6 then return false end
    if weaponType == 8 then return false end
    if weaponType == 9 then return false end
    if weaponType == 10 then return false end
    if weaponType == 11 then return false end
    if weaponType == 12 then return false end
    if weaponType == 13 then return false end

    return true
end

local function isSpearWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.SpearTwoWide)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isTool(item)
    if item == nil then
        return false
    end

    if Lockpick ~= nil and type(Lockpick.objectIsInstance) == "function" and Lockpick.objectIsInstance(item) then
        return true
    end
    if Probe ~= nil and type(Probe.objectIsInstance) == "function" and Probe.objectIsInstance(item) then
        return true
    end
    if Repair ~= nil and type(Repair.objectIsInstance) == "function" and Repair.objectIsInstance(item) then
        return true
    end

    return false
end

local function perkOwned(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    return type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId) or false
end

local function perkEffectEnabled(perkId)
    if not perkOwned(perkId) then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkId)
    end

    return true
end

local function hallowedGuardEnabled()
    return perkEffectEnabled(HALLOWED_GUARD_PERK_ID)
end

local function shieldFundamentalsEnabled()
    return perkEffectEnabled(SHIELD_FUNDAMENTALS_PERK_ID)
end

local function guardiansHabitEnabled()
    return perkEffectEnabled(GUARDIANS_HABIT_PERK_ID)
end

local function steadyWallEnabled()
    return perkEffectEnabled(STEADY_WALL_PERK_ID)
end

local function bulwarkOfLightEnabled()
    return perkEffectEnabled(BULWARK_OF_LIGHT_PERK_ID)
end

local function aegisRiteEnabled()
    return perkEffectEnabled(AEGIS_RITE_PERK_ID)
end

local function spearLongGuardEnabled()
    return perkEffectEnabled(SPEAR_LONG_GUARD_PERK_ID)
end

local function unarmoredUnburdenedFormEnabled()
    return perkEffectEnabled(UNARMORED_UNBURDENED_FORM_PERK_ID)
end

local function unarmoredFlowingStepEnabled()
    return perkEffectEnabled(UNARMORED_FLOWING_STEP_PERK_ID)
end

local function unarmoredSilkGuardEnabled()
    return perkEffectEnabled(UNARMORED_SILK_GUARD_PERK_ID)
end

local function unarmoredEmptyMailEnabled()
    return perkEffectEnabled(UNARMORED_EMPTY_MAIL_PERK_ID)
end

local function unarmoredMasterOfMotionEnabled()
    return perkEffectEnabled(UNARMORED_MASTER_OF_MOTION_PERK_ID)
end

local function hasValidShieldSetup()
    local shield = getEquippedShield(pself)
    if shield == nil then
        return false
    end

    local rightHand = getEquippedRightHand(pself)
    if rightHand == nil then
        return false
    end

    return isOneHandedWeapon(rightHand) or isTool(rightHand)
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if hallowedGuardSpellBookFailureState ~= "unavailable" then
            hallowedGuardSpellBookFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust hallowed guard state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if hallowedGuardSpellBookFailureState ~= "error" then
            hallowedGuardSpellBookFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust hallowed guard state")
        end
        return nil
    end

    hallowedGuardSpellBookFailureState = nil
    return spells
end

local function resolveHallowedGuardSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[HALLOWED_GUARD_ABILITY_ID]
end

local function spellBookHasHallowedGuard(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(HALLOWED_GUARD_ABILITY_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveHallowedGuardSpellRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == HALLOWED_GUARD_ABILITY_ID then
            return true
        end
    end

    return false
end

local function addHallowedGuardSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(HALLOWED_GUARD_ABILITY_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveHallowedGuardSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeHallowedGuardSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(HALLOWED_GUARD_ABILITY_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveHallowedGuardSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateHallowedGuardAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHaveAbility = hallowedGuardEnabled() and hasValidShieldSetup()
    local hasSpell = spellBookHasHallowedGuard(spells)

    if shouldHaveAbility and not hasSpell then
        local okAdd, addError = addHallowedGuardSpell(spells)
        if not okAdd then
            if not hallowedGuardAddFailureLogged then
                hallowedGuardAddFailureLogged = true
                logDebug(string.format("failed to add %s: %s", HALLOWED_GUARD_ABILITY_ID, tostring(addError)))
            end
            return
        end
        hallowedGuardAddFailureLogged = false
        hallowedGuardApplied = true
    elseif (not shouldHaveAbility) and (hasSpell or hallowedGuardApplied) then
        local okRemove, removeError = removeHallowedGuardSpell(spells)
        if not okRemove then
            if not hallowedGuardRemoveFailureLogged then
                hallowedGuardRemoveFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", HALLOWED_GUARD_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        hallowedGuardRemoveFailureLogged = false
        hallowedGuardApplied = false
    end
end

local function resolveUnarmoredEmptyMailSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[UNARMORED_EMPTY_MAIL_ABILITY_ID]
end

local function spellBookHasUnarmoredEmptyMail(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(UNARMORED_EMPTY_MAIL_ABILITY_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == UNARMORED_EMPTY_MAIL_ABILITY_ID then
            return true
        end
    end

    return false
end

local function addUnarmoredEmptyMailSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(UNARMORED_EMPTY_MAIL_ABILITY_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeUnarmoredEmptyMailSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(UNARMORED_EMPTY_MAIL_ABILITY_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateUnarmoredEmptyMailAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHaveAbility = unarmoredEmptyMailEnabled()
    local hasSpell = spellBookHasUnarmoredEmptyMail(spells)

    if shouldHaveAbility and not hasSpell then
        local okAdd, addError = addUnarmoredEmptyMailSpell(spells)
        if not okAdd then
            if not unarmoredEmptyMailAddFailureLogged then
                unarmoredEmptyMailAddFailureLogged = true
                logDebug(string.format("failed to add %s: %s", UNARMORED_EMPTY_MAIL_ABILITY_ID, tostring(addError)))
            end
            return
        end
        unarmoredEmptyMailAddFailureLogged = false
        unarmoredEmptyMailApplied = true
    elseif (not shouldHaveAbility) and (hasSpell or unarmoredEmptyMailApplied) then
        local okRemove, removeError = removeUnarmoredEmptyMailSpell(spells)
        if not okRemove then
            if not unarmoredEmptyMailRemoveFailureLogged then
                unarmoredEmptyMailRemoveFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", UNARMORED_EMPTY_MAIL_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        unarmoredEmptyMailRemoveFailureLogged = false
        unarmoredEmptyMailApplied = false
    end
end

local function getBlockSkillBonus()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return 0
    end

    local blockStat = blockAccessor(pself)
    local blockSkill = blockStat ~= nil and tonumber(blockStat.base) or 0
    if blockSkill <= 0 then
        return 0
    end

    return math.floor(blockSkill / 7)
end

local function getSpearSkillBonus()
    local spearAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.spear
    if type(spearAccessor) ~= "function" then
        return 0
    end

    local spearStat = spearAccessor(pself)
    local spearSkill = spearStat ~= nil and tonumber(spearStat.base) or 0
    if spearSkill <= 0 then
        return 0
    end

    return math.floor(spearSkill / 10)
end

local function getUnarmoredSkillBonus()
    local unarmoredAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.unarmored
    if type(unarmoredAccessor) ~= "function" then
        return 0
    end

    local unarmoredStat = unarmoredAccessor(pself)
    local unarmoredSkill = unarmoredStat ~= nil and tonumber(unarmoredStat.base) or 0
    if unarmoredSkill <= 0 then
        return 0
    end

    return math.floor(unarmoredSkill / 10)
end

local function getGuardiansHabitFatigueRestore()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return 1
    end

    local blockStat = blockAccessor(pself)
    local blockSkill = blockStat ~= nil and tonumber(blockStat.base) or 0
    return math.max(1, math.floor(blockSkill / 5))
end

local function pruneMomentumStacks()
    local kept = {}
    for _, expiresAt in ipairs(momentumExpirations) do
        if expiresAt > runtimeTime then
            kept[#kept + 1] = expiresAt
        end
    end
    momentumExpirations = kept
end

local function getMomentumStackCount()
    pruneMomentumStacks()
    return #momentumExpirations
end

local function getMomentumArmorBonus()
    if not steadyWallEnabled() then
        return 0
    end
    if not hasValidShieldSetup() then
        return 0
    end
    return getMomentumStackCount() * STEADY_WALL_ARMOR_PER_STACK
end

local function getMomentumBlockBonus()
    if not steadyWallEnabled() then
        return 0
    end
    if not hasValidShieldSetup() then
        return 0
    end
    return getMomentumStackCount() * STEADY_WALL_BLOCK_PER_STACK
end

local function applyMomentumBlockModifier()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return
    end

    local blockStat = blockAccessor(pself)
    if blockStat == nil then
        return
    end

    local desiredModifier = getMomentumBlockBonus()
    local currentModifier = tonumber(blockStat.modifier) or 0
    if currentModifier ~= desiredModifier then
        blockStat.modifier = desiredModifier
    end
end

local function shouldApplyShieldFundamentalsBonus()
    if not shieldFundamentalsEnabled() then
        return false
    end

    return hasValidShieldSetup()
end

local function shouldApplySpearLongGuardBonus()
    if not spearLongGuardEnabled() then
        return false
    end

    if getEquippedShield(pself) ~= nil then
        return false
    end

    return isSpearWeapon(getEquippedRightHand(pself))
end

local function isArmoredCuirassGreavesOrShield(equipped, slot)
    if equipped == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return false
    end

    local armorType = nil
    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, equipped)
        if okRecord and record ~= nil then
            armorType = record.type
        end
    end

    if Armor.TYPE ~= nil then
        if armorType == Armor.TYPE.Cuirass or armorType == Armor.TYPE.Greaves or armorType == Armor.TYPE.Shield then
            return true
        end
    end

    if Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil then
        return slot == Actor.EQUIPMENT_SLOT.Cuirass
            or slot == Actor.EQUIPMENT_SLOT.Greaves
            or slot == Actor.EQUIPMENT_SLOT.CarriedLeft
    end

    return false
end

local function hasArmoredCuirassGreavesOrShieldEquipped()
    if Actor == nil or type(Actor.getEquipment) ~= "function" then
        return false
    end

    local okEquipment, equipment = pcall(Actor.getEquipment, pself)
    if not okEquipment or type(equipment) ~= "table" then
        return false
    end

    for slot, equipped in pairs(equipment) do
        if isArmoredCuirassGreavesOrShield(equipped, slot) then
            return true
        end
    end

    return false
end

local function isEquippedArmorOrShield(equipped)
    return equipped ~= nil
        and Armor ~= nil
        and type(Armor.objectIsInstance) == "function"
        and Armor.objectIsInstance(equipped)
end

local function hasArmorOrShieldEquipped()
    if Actor == nil or type(Actor.getEquipment) ~= "function" then
        return false
    end

    local okEquipment, equipment = pcall(Actor.getEquipment, pself)
    if not okEquipment or type(equipment) ~= "table" then
        return false
    end

    for _, equipped in pairs(equipment) do
        if isEquippedArmorOrShield(equipped) then
            return true
        end
    end

    return false
end

local function getBlockRuntimeFatiguePercent()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return 0
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return 0
    end

    return current / maxFatigue
end

local function resolveBlockRuntimeAttributeStat(attributeID)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes[attributeID]
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end


local function restoreUnarmoredMasterOfMotionFatigue(dt)
    if not unarmoredMasterOfMotionEnabled() or hasArmoredCuirassGreavesOrShieldEquipped() then
        return
    end

    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 or current <= maxFatigue * UNARMORED_MASTER_OF_MOTION_MIN_FATIGUE_THRESHOLD then
        return
    end

    local restoreAmount = math.max(0, tonumber(dt) or 0) * UNARMORED_MASTER_OF_MOTION_FATIGUE_RESTORE_PER_SECOND
    if restoreAmount <= 0 then
        return
    end

    fatigue.current = math.min(maxFatigue, current + restoreAmount)
end

local function applyUnarmoredFlowingStepAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedUnarmoredFlowingStepAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveBlockRuntimeAttributeStat("agility")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedUnarmoredFlowingStepAgilityBonus = desired
    unarmoredRuntimeSection:set(UNARMORED_FLOWING_STEP_APPLIED_KEY, desired)
end

local function getUnarmoredFlowingStepAgilityBonus()
    if not unarmoredFlowingStepEnabled() or hasArmorOrShieldEquipped() then
        return 0
    end

    if getBlockRuntimeFatiguePercent() > UNARMORED_FLOWING_STEP_HIGH_FATIGUE_THRESHOLD then
        return UNARMORED_FLOWING_STEP_HIGH_FATIGUE_AGILITY_BONUS
    end

    return UNARMORED_FLOWING_STEP_AGILITY_BONUS
end

local function refreshUnarmoredFlowingStepAgilityBonus()
    applyUnarmoredFlowingStepAgilityBonus(getUnarmoredFlowingStepAgilityBonus())
end

local function applyUnarmoredSilkGuardAttributeBonus(attributeID, currentBonus, appliedKey, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(currentBonus) or 0))
    if desired == current then
        return current
    end

    local stat = resolveBlockRuntimeAttributeStat(attributeID)
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    unarmoredRuntimeSection:set(appliedKey, desired)
    return desired
end

local function getUnarmoredSilkGuardAttributeBonus()
    if not unarmoredSilkGuardEnabled() or hasArmoredCuirassGreavesOrShieldEquipped() then
        return 0
    end

    if getBlockRuntimeFatiguePercent() > UNARMORED_SILK_GUARD_HIGH_FATIGUE_THRESHOLD then
        return UNARMORED_SILK_GUARD_HIGH_FATIGUE_ATTRIBUTE_BONUS
    end

    return UNARMORED_SILK_GUARD_ATTRIBUTE_BONUS
end

local function refreshUnarmoredSilkGuardAttributeBonuses()
    local bonus = getUnarmoredSilkGuardAttributeBonus()
    appliedUnarmoredSilkGuardEnduranceBonus = applyUnarmoredSilkGuardAttributeBonus(
        "endurance",
        appliedUnarmoredSilkGuardEnduranceBonus,
        UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY,
        bonus
    )
    appliedUnarmoredSilkGuardWillpowerBonus = applyUnarmoredSilkGuardAttributeBonus(
        "willpower",
        appliedUnarmoredSilkGuardWillpowerBonus,
        UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY,
        bonus
    )
end

local function shouldApplyUnarmoredUnburdenedFormBonus()
    if not unarmoredUnburdenedFormEnabled() then
        return false
    end

    return not hasArmoredCuirassGreavesOrShieldEquipped()
end

local function getTotalPassiveArmorBonus()
    local bonus = 0
    if shouldApplyShieldFundamentalsBonus() then
        bonus = bonus + getBlockSkillBonus()
    end
    if shouldApplySpearLongGuardBonus() then
        bonus = bonus + getSpearSkillBonus()
    end
    if shouldApplyUnarmoredUnburdenedFormBonus() then
        bonus = bonus + getUnarmoredSkillBonus()
    end
    bonus = bonus + getMomentumArmorBonus()
    return bonus
end

local function adjustDamageForArmorWithShieldBonuses(damage, actor)
    local fn = getBaseCombatFunction("adjustDamageForArmor")
    if fn == nil then
        return damage
    end

    local actualActor = actor or pself
    local adjusted = fn(damage, actualActor)

    if actualActor ~= pself then
        return adjusted
    end

    local bonusArmor = getTotalPassiveArmorBonus()

    if bonusArmor <= 0 then
        return adjusted
    end

    local result = (tonumber(adjusted) or 0) * 100 / (100 + bonusArmor)

    logDebug(string.format(
        "shield bonus damage reduction in=%.3f bonusArmor=%d out=%.3f",
        tonumber(adjusted) or 0,
        bonusArmor,
        result
    ))

    return result
end

local function getArmorRecord(item)
    if item == nil or Armor == nil or type(Armor.record) ~= "function" then
        return nil
    end

    local ok, record = pcall(Armor.record, item)
    if ok then
        return record
    end
    return nil
end

local function getArmorRatingWithShieldBonuses(actor)
    local fn = getBaseCombatFunction("getArmorRating")
    if fn == nil then
        return nil
    end

    local actualActor = actor or pself
    local baseArmor = fn(actualActor)
    if actualActor ~= pself then
        return baseArmor
    end

    local bonus = getTotalPassiveArmorBonus()

    if bonus <= 0 then
        return baseArmor
    end

    return (tonumber(baseArmor) or 0) + bonus
end

local function getEffectiveArmorRatingWithShieldBonuses(item, actor)
    local fn = getBaseCombatFunction("getEffectiveArmorRating")
    if fn == nil then
        return nil
    end

    local actualActor = actor or pself
    local baseArmor = fn(item, actualActor)
    if actualActor ~= pself then
        return baseArmor
    end

    if item == nil then
        return baseArmor
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return baseArmor
    end

    local record = getArmorRecord(item)
    if record == nil or record.type ~= Armor.TYPE.Shield then
        return baseArmor
    end

    local bonus = 0
    if shouldApplyShieldFundamentalsBonus() then
        bonus = bonus + getBlockSkillBonus()
    end
    bonus = bonus + getMomentumArmorBonus()

    if bonus <= 0 then
        return baseArmor
    end

    return (tonumber(baseArmor) or 0) + bonus
end

local function wasSuccessfulShieldBlock(attack)
    if type(attack) ~= "table" then
        return false
    end

    local blockedFlag = attack.blocked == true or attack.isBlocked == true or attack.block == true
    local blockedBy = string.lower(tostring(attack.blockedBy or attack.blockType or attack.defenseType or ""))
    local isParry = attack.parried == true or attack.isParry == true or blockedBy:find("parry", 1, true) ~= nil

    if isParry then
        return false
    end

    if blockedBy:find("shield", 1, true) ~= nil then
        return true
    end

    if blockedFlag then
        return true
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local healthDamage = tonumber(damage.health) or 0
    local fatigueDamage = tonumber(damage.fatigue) or 0
    local magickaDamage = tonumber(damage.magicka) or 0
    local totalDamage = healthDamage + fatigueDamage + magickaDamage

    if attack.successful == true and totalDamage <= 0 then
        return true
    end

    return false
end

local function trySpendMagicka(amount)
    if amount <= 0 then
        return true
    end

    local magickaAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.magicka

    if type(magickaAccessor) ~= "function" then
        return false
    end

    local magickaStat = magickaAccessor(pself)
    if magickaStat == nil then
        return false
    end

    local current = tonumber(magickaStat.current) or 0
    if current < amount then
        return false
    end

    magickaStat.current = current - amount
    return true
end

local function onTryConsumeAegisRite(data)
    if not aegisRiteEnabled() then
        return
    end
    if type(data) ~= "table" or data.target == nil then
        return
    end
    if not trySpendMagicka(AEGIS_RITE_MAGICKA_COST) then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyAegisRiteEffect", {
        attacker = pself,
        target = data.target,
    })
end

local function applyGuardiansHabit(attack)
    if not guardiansHabitEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    local shield = getEquippedShield(pself)
    if shield == nil then
        return
    end

    local fatigueRestore = getGuardiansHabitFatigueRestore()

    local fatigueStatAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue

    if type(fatigueStatAccessor) == "function" then
        local fatigueStat = fatigueStatAccessor(pself)
        if fatigueStat ~= nil then
            local current = tonumber(fatigueStat.current) or 0
            local base = tonumber(fatigueStat.base) or current
            local modifier = tonumber(fatigueStat.modifier) or 0
            local maxFatigue = math.max(0, base + modifier)
            fatigueStat.current = math.min(current + fatigueRestore, maxFatigue)
        end
    end

    core.sendGlobalEvent("ModifyItemCondition", {
        actor = pself,
        item = shield,
        amount = math.max(1, math.floor(getBlockSkillBonus() / 2)),
    })
end

local function applySteadyWallMomentum(attack)
    if not steadyWallEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    pruneMomentumStacks()
    if #momentumExpirations < STEADY_WALL_MAX_STACKS then
        momentumExpirations[#momentumExpirations + 1] = runtimeTime + STEADY_WALL_DURATION
    else
        local oldestIndex = 1
        local oldestTime = momentumExpirations[1]
        for i = 2, #momentumExpirations do
            if momentumExpirations[i] < oldestTime then
                oldestTime = momentumExpirations[i]
                oldestIndex = i
            end
        end
        momentumExpirations[oldestIndex] = runtimeTime + STEADY_WALL_DURATION
    end
end

local function primeAegisRite(attack)
    if not aegisRiteEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    if attack.attacker == nil then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_PrimeAegisRite", {
        blocker = pself,
        attacker = attack.attacker,
        duration = AEGIS_RITE_WINDOW,
    })
end

local function applyBulwarkOfLight(attack)
    if not bulwarkOfLightEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    Actor.activeSpells(pself):add({
        id = BULWARK_SELF_SPELL_ID,
        effects = { 0 },
        caster = pself,
        stackable = false,
    })

    core.sendGlobalEvent("SkillPerkSystem_ApplyBulwarkOfLight", {
        blocker = pself,
    })
end

local function initializeDefaults()
    if configSection:get(DEBUG_LOGGING_KEY) == nil then
        configSection:set(DEBUG_LOGGING_KEY, DEFAULT_DEBUG_LOGGING)
    end
end

local function processBlockPerks(attack)
    applyGuardiansHabit(attack)
    applySteadyWallMomentum(attack)
    primeAegisRite(attack)
    applyBulwarkOfLight(attack)
end

local function shouldUpdateBlock(dt)
    if #momentumExpirations > 0 or hallowedGuardAddFailureLogged or hallowedGuardRemoveFailureLogged then
        return true
    end

    local needsHallowedGuardRefresh = hallowedGuardApplied or hallowedGuardEnabled()
    local needsFlowingStepRefresh = appliedUnarmoredFlowingStepAgilityBonus ~= 0 or unarmoredFlowingStepEnabled()
    local needsSilkGuardRefresh = appliedUnarmoredSilkGuardEnduranceBonus ~= 0
        or appliedUnarmoredSilkGuardWillpowerBonus ~= 0
        or unarmoredSilkGuardEnabled()
    local needsEmptyMailRefresh = unarmoredEmptyMailApplied or unarmoredEmptyMailEnabled()
    local needsMasterOfMotionRefresh = unarmoredMasterOfMotionEnabled()
    if needsMasterOfMotionRefresh then
        return true
    end

    if not needsHallowedGuardRefresh
        and not needsFlowingStepRefresh
        and not needsSilkGuardRefresh
        and not needsEmptyMailRefresh
        and not needsMasterOfMotionRefresh then
        return false
    end

    blockStateRefreshTimer = blockStateRefreshTimer + (tonumber(dt) or 0)
    if blockStateRefreshTimer < BLOCK_STATE_REFRESH_INTERVAL then
        return false
    end

    blockStateRefreshTimer = 0
    blockStateRefreshDue = true
    return true
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(processBlockPerks)
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    interfaceName = "Combat",
    interface = {
        version = 1,

        addOnHitHandler = passthrough("addOnHitHandler"),
        adjustDamageForArmor = adjustDamageForArmorWithShieldBonuses,
        adjustDamageForDifficulty = passthrough("adjustDamageForDifficulty"),
        applyArmor = passthrough("applyArmor"),

        getArmorRating = getArmorRatingWithShieldBonuses,
        getArmorSkill = passthrough("getArmorSkill"),
        getEffectiveArmorRating = getEffectiveArmorRatingWithShieldBonuses,
        getSkillAdjustedArmorRating = passthrough("getSkillAdjustedArmorRating"),

        onHit = passthrough("onHit"),
        pickRandomArmor = passthrough("pickRandomArmor"),
        spawnBloodEffect = passthrough("spawnBloodEffect"),
    },
    eventHandlers = {
        SkillPerkSystem_TryConsumeAegisRite = onTryConsumeAegisRite,
    },
    engineHandlers = {
        onLoad = function()
            initializeDefaults()
            runtimeTime = 0
            momentumExpirations = {}
            hallowedGuardApplied = false
            unarmoredEmptyMailApplied = false
            blockStateRefreshTimer = BLOCK_STATE_REFRESH_INTERVAL
            blockStateRefreshDue = false
            applyMomentumBlockModifier()
            refreshUnarmoredFlowingStepAgilityBonus()
            refreshUnarmoredSilkGuardAttributeBonuses()
            updateHallowedGuardAbility()
            updateUnarmoredEmptyMailAbility()
        end,
        onUpdate = function(dt)
            runtimeTime = runtimeTime + (tonumber(dt) or 0)
            pruneMomentumStacks()
            applyMomentumBlockModifier()
            refreshUnarmoredFlowingStepAgilityBonus()
            refreshUnarmoredSilkGuardAttributeBonuses()
            restoreUnarmoredMasterOfMotionFatigue(dt)
            blockStateRefreshTimer = blockStateRefreshTimer + (tonumber(dt) or 0)
            if blockStateRefreshDue
                or blockStateRefreshTimer >= BLOCK_STATE_REFRESH_INTERVAL
                or hallowedGuardAddFailureLogged
                or hallowedGuardRemoveFailureLogged
                or unarmoredEmptyMailAddFailureLogged
                or unarmoredEmptyMailRemoveFailureLogged then
                blockStateRefreshTimer = 0
                blockStateRefreshDue = false
                updateHallowedGuardAbility()
                updateUnarmoredEmptyMailAbility()
            end
        end,
        shouldUpdate = shouldUpdateBlock,
        onInterfaceOverride = function(base)
            baseCombatInterface = base
        end,
    },
}

end

----------------------------------------------------------------------
-- longblade runtime logic (from longblade_runtime.lua)
----------------------------------------------------------------------
do
local interfaces = require("openmw.interfaces")
local ui = require("openmw.ui")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LONG_BLADE_FUNDAMENTALS_PERK_ID = "longblade_fundamentals"
local DUELISTS_TEMPO_PERK_ID = "longblade_demo_precision"
local GREATBLADE_FORM_PERK_ID = "longblade_greatblade_form"
local DUELISTS_FORM_PERK_ID = "longblade_demo_duelist"
local GREATBLADE_CRITICALS_PERK_ID = "longblade_demo_whirlwind"
local KEEN_EDGE_PERK_ID = "longblade_keen_edge"
local GRANDMASTER_FORM_PERK_ID = "longblade_demo_mastery"
local FATIGUE_THRESHOLD = 0.8
local LONG_BLADE_BONUS = 5
local LONG_BLADE_STATE_REFRESH_INTERVAL = 0.5
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_LongBlade"
local APPLIED_BONUS_KEY = "fundamentals.applied_bonus"
local DUELISTS_TEMPO_APPLIED_KEY = "duelists_tempo.applied_agility_bonus"
local DUELISTS_FORM_ABILITY_ID = "sps_duelistbuff"
local GREATBLADE_FORM_ABILITY_ID = "sps_greatbladeform"
local LOG_TAG = "[SkillPerkSystem_BasePack][LongBlade]"

local DUELISTS_TEMPO_MAX_STACKS = 5
local DUELISTS_TEMPO_DURATION = 4.0
local DUELISTS_TEMPO_AGILITY_PER_STACK = 3
local GREATBLADE_CRITICAL_CHANCE = 0.25
local GREATBLADE_CRITICAL_DAMAGE = 20
local GREATBLADE_CRITICAL_MESSAGE = "Critical hit!"
local KEEN_EDGE_CRITICAL_CHANCE = 0.05
local KEEN_EDGE_CRITICAL_DAMAGE = 20
local KEEN_EDGE_CRITICAL_MESSAGE = "Keen Edge critical hit!"
local GRANDMASTER_HEAVY_CRITICAL_MAX_CHANCE = 0.10
local GRANDMASTER_HEAVY_CRITICAL_MIN_FATIGUE = 0.05
local GRANDMASTER_HEAVY_CRITICAL_DAMAGE = 25
local GRANDMASTER_HEAVY_CRITICAL_MESSAGE = "Heavy crit!"

local storageSection = storage.playerSection(STORAGE_SECTION_ID)
local appliedLongBladeBonus = tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0
local duelistTempoStacks = 0
local duelistTempoRemaining = 0
local appliedDuelistTempoAgilityBonus = tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0
local runtimeTime = 0
local lastDuelistTempoTarget = nil
local lastDuelistTempoApplyTime = -1
local lastGreatbladeCriticalTarget = nil
local lastGreatbladeCriticalApplyTime = -1
local lastKeenEdgeCriticalTarget = nil
local lastKeenEdgeCriticalApplyTime = -1
local lastGrandmasterHeavyCriticalTarget = nil
local lastGrandmasterHeavyCriticalApplyTime = -1
local duelistsFormAbilityApplied = false
local greatbladeFormAbilityApplied = false
local spellAbilityFailureStates = {}
local playerSpellBookFailureState = nil
local longBladeStateRefreshTimer = LONG_BLADE_STATE_REFRESH_INTERVAL
local longBladeStateRefreshDue = false

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function longBladeFundamentalsEnabled()
    return hasEnabledPerk(LONG_BLADE_FUNDAMENTALS_PERK_ID)
end

local function duelistsTempoEnabled()
    return hasEnabledPerk(DUELISTS_TEMPO_PERK_ID)
end

local function greatbladeFormEnabled()
    return hasEnabledPerk(GREATBLADE_FORM_PERK_ID)
end

local function duelistsFormEnabled()
    return hasEnabledPerk(DUELISTS_FORM_PERK_ID)
end

local function greatbladeCriticalsEnabled()
    return hasEnabledPerk(GREATBLADE_CRITICALS_PERK_ID)
end

local function keenEdgeEnabled()
    return hasEnabledPerk(KEEN_EDGE_PERK_ID)
end

local function grandmasterFormEnabled()
    return hasEnabledPerk(GRANDMASTER_FORM_PERK_ID)
end

local function getFatiguePercent()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return 0
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return 0
    end

    return current / maxFatigue
end

local function resolveLongBladeStat()
    local accessor = types.NPC ~= nil
        and types.NPC.stats ~= nil
        and types.NPC.stats.skills ~= nil
        and types.NPC.stats.skills.longblade
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyLongBladeBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedLongBladeBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveLongBladeStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedLongBladeBonus = desired
    storageSection:set(APPLIED_BONUS_KEY, desired)
end

local function resolveAgilityStat(actor)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" or actor == nil then
        return nil
    end

    return accessor(actor)
end

local function applyDuelistTempoAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedDuelistTempoAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat(pself)
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedDuelistTempoAgilityBonus = desired
    storageSection:set(DUELISTS_TEMPO_APPLIED_KEY, desired)
end

local function clearDuelistTempoBonus()
    duelistTempoStacks = 0
    duelistTempoRemaining = 0
    applyDuelistTempoAgilityBonus(0)
end

local function refreshLongBladeFundamentals()
    local desiredBonus = 0
    if longBladeFundamentalsEnabled() and getFatiguePercent() > FATIGUE_THRESHOLD then
        desiredBonus = LONG_BLADE_BONUS
    end

    applyLongBladeBonus(desiredBonus)
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    local recordId = type(item) == "string" and item or item.recordId
    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[recordId]
    end

    if type(item) == "table" and item.type ~= nil and type(item.type.records) == "table" and type(recordId) == "string" then
        return item.type.records[recordId]
    end

    return nil
end

local function getArmorRecord(item)
    if item == nil or Armor == nil then
        return nil
    end

    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Armor.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Armor.records) == "table" then
        return Armor.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function isLongBladeOneHandRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local weaponType = tonumber(record.type)
    local oneHandLongBladeType = tonumber(Weapon.TYPE.LongBladeOneHand)
    return weaponType ~= nil and oneHandLongBladeType ~= nil and weaponType == oneHandLongBladeType
end

local function isLongBladeTwoHandRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local weaponType = tonumber(record.type)
    local twoHandLongBladeType = tonumber(Weapon.TYPE.LongBladeTwoHand)
    return weaponType ~= nil and twoHandLongBladeType ~= nil and weaponType == twoHandLongBladeType
end

local function getEquippedItem(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getEquippedLongBladeWeapon(matcher)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil or type(matcher) ~= "function" then
        return nil
    end

    local slot = Actor.EQUIPMENT_SLOT.CarriedRight
    if slot == nil then
        return nil
    end

    local weapon = getEquippedItem(slot)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not matcher(record) then
        return nil
    end

    return weapon
end

local function getEquippedOneHandedLongBlade()
    return getEquippedLongBladeWeapon(isLongBladeOneHandRecord)
end

local function getEquippedTwoHandedLongBlade()
    return getEquippedLongBladeWeapon(isLongBladeTwoHandRecord)
end

local function isLongBladeRecord(record)
    return isLongBladeOneHandRecord(record) or isLongBladeTwoHandRecord(record)
end

local function getEquippedLongBlade()
    return getEquippedLongBladeWeapon(isLongBladeRecord)
end

local function hasEquippedOffHandShield()
    if Actor == nil or Armor == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local leftSlot = Actor.EQUIPMENT_SLOT.CarriedLeft
    if leftSlot == nil then
        return false
    end

    local offHand = getEquippedItem(leftSlot)
    if offHand == nil then
        return false
    end

    if type(Armor.objectIsInstance) == "function" and not Armor.objectIsInstance(offHand) then
        return false
    end

    local record = getArmorRecord(offHand)
    return record ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE.Shield
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if playerSpellBookFailureState ~= "unavailable" then
            playerSpellBookFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust long blade ability state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if playerSpellBookFailureState ~= "error" then
            playerSpellBookFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust long blade ability state")
        end
        return nil
    end

    playerSpellBookFailureState = nil
    return spells
end

local function resolveAbilityRecord(abilityId)
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[abilityId]
end

local function spellBookHasAbility(spells, abilityId)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(abilityId)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveAbilityRecord(abilityId)
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == abilityId then
            return true
        end
    end

    return false
end

local function addAbility(spells, abilityId)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(abilityId)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveAbilityRecord(abilityId)
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeAbility(spells, abilityId)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(abilityId)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveAbilityRecord(abilityId)
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateConditionalAbility(spells, abilityId, shouldHaveAbility, applied)
    local hasAbility = spellBookHasAbility(spells, abilityId)
    local failureState = spellAbilityFailureStates[abilityId] or {}

    if shouldHaveAbility and not hasAbility then
        local okAdd, addError = addAbility(spells, abilityId)
        if not okAdd then
            if not failureState.add then
                failureState.add = true
                logDebug(string.format("failed to add %s: %s", abilityId, tostring(addError)))
            end
            spellAbilityFailureStates[abilityId] = failureState
            return applied
        end
        failureState.add = false
        spellAbilityFailureStates[abilityId] = failureState
        return true
    elseif (not shouldHaveAbility) and (hasAbility or applied) then
        local okRemove, removeError = removeAbility(spells, abilityId)
        if not okRemove then
            if not failureState.remove then
                failureState.remove = true
                logDebug(string.format("failed to remove %s: %s", abilityId, tostring(removeError)))
            end
            spellAbilityFailureStates[abilityId] = failureState
            return applied
        end
        failureState.remove = false
        spellAbilityFailureStates[abilityId] = failureState
        return false
    end

    return applied
end

local function updateLongBladeAbilities()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    greatbladeFormAbilityApplied = updateConditionalAbility(
        spells,
        GREATBLADE_FORM_ABILITY_ID,
        greatbladeFormEnabled() and getEquippedTwoHandedLongBlade() ~= nil,
        greatbladeFormAbilityApplied
    )

    duelistsFormAbilityApplied = updateConditionalAbility(
        spells,
        DUELISTS_FORM_ABILITY_ID,
        duelistsFormEnabled() and getEquippedOneHandedLongBlade() ~= nil and not hasEquippedOffHandShield(),
        duelistsFormAbilityApplied
    )
end

local function hasLongBladeAbilityFailure()
    if playerSpellBookFailureState ~= nil then
        return true
    end

    for _, state in pairs(spellAbilityFailureStates) do
        if type(state) == "table" and (state.add == true or state.remove == true) then
            return true
        end
    end

    return false
end

local function anyLongBladeStatePerkEnabled()
    return longBladeFundamentalsEnabled()
        or greatbladeFormEnabled()
        or duelistsFormEnabled()
end

local function refreshLongBladeStaticState()
    refreshLongBladeFundamentals()
    updateLongBladeAbilities()
end

local function isValidDuelistTempoTarget(target)
    return target ~= nil and type(target.isValid) == "function" and target:isValid()
end

local function applyDuelistTempoToTarget(target, stacks)
    if not isValidDuelistTempoTarget(target) then
        return
    end

    local initData = {
        stacks = stacks,
        duration = DUELISTS_TEMPO_DURATION,
        agilityPerStack = DUELISTS_TEMPO_AGILITY_PER_STACK,
    }
    local targetScript = "scripts/SkillPerkSystem_BasePack/basepack_actor_target.lua"
    if type(target.hasScript) == "function" and type(target.addScript) == "function" and not target:hasScript(targetScript) then
        target:addScript(targetScript, initData)
        return
    end

    target:sendEvent("SkillPerkSystem_DuelistsTempoRefresh", initData)
end

local function recentlyAppliedDuelistTempo(target)
    return target ~= nil and target == lastDuelistTempoTarget and (runtimeTime - lastDuelistTempoApplyTime) < 0.05
end

local function rememberDuelistTempoApplication(target)
    lastDuelistTempoTarget = target
    lastDuelistTempoApplyTime = runtimeTime
end

local function recentlyAppliedCritical(target, lastTarget, lastApplyTime)
    return target ~= nil and target == lastTarget and (runtimeTime - lastApplyTime) < 0.05
end

local function rememberGreatbladeCriticalApplication(target)
    lastGreatbladeCriticalTarget = target
    lastGreatbladeCriticalApplyTime = runtimeTime
end

local function rememberKeenEdgeCriticalApplication(target)
    lastKeenEdgeCriticalTarget = target
    lastKeenEdgeCriticalApplyTime = runtimeTime
end

local function rememberGrandmasterHeavyCriticalApplication(target)
    lastGrandmasterHeavyCriticalTarget = target
    lastGrandmasterHeavyCriticalApplyTime = runtimeTime
end

local function showMessage(text)
    ui.showMessage(text, { showInDialogue = false })
end

local function applyLongBladeCriticalDamage(target, damage)
    if target == nil or type(target.sendEvent) ~= "function" then
        return
    end

    target:sendEvent("SkillPerkSystem_ApplyLongBladeCriticalDamage", {
        damage = damage,
    })
end

local function tryApplyDuelistTempo(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
        return
    end
    if recentlyAppliedDuelistTempo(target) then
        return
    end

    rememberDuelistTempoApplication(target)
    longBladeStateRefreshDue = true
    duelistTempoStacks = math.min(DUELISTS_TEMPO_MAX_STACKS, duelistTempoStacks + 1)
    duelistTempoRemaining = DUELISTS_TEMPO_DURATION
    applyDuelistTempoAgilityBonus(duelistTempoStacks * DUELISTS_TEMPO_AGILITY_PER_STACK)
    applyDuelistTempoToTarget(target, duelistTempoStacks)
end


local function tryApplyGreatbladeCritical(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not greatbladeCriticalsEnabled() or getEquippedTwoHandedLongBlade() == nil then
        return
    end
    if recentlyAppliedCritical(target, lastGreatbladeCriticalTarget, lastGreatbladeCriticalApplyTime) then
        return
    end
    if math.random() >= GREATBLADE_CRITICAL_CHANCE then
        return
    end

    rememberGreatbladeCriticalApplication(target)
    showMessage(GREATBLADE_CRITICAL_MESSAGE)
    applyLongBladeCriticalDamage(target, GREATBLADE_CRITICAL_DAMAGE)
end

local function getGrandmasterHeavyCriticalChance()
    local fatiguePercent = math.max(0, math.min(1, getFatiguePercent()))
    if fatiguePercent <= GRANDMASTER_HEAVY_CRITICAL_MIN_FATIGUE then
        return 0
    end

    return GRANDMASTER_HEAVY_CRITICAL_MAX_CHANCE
        * ((fatiguePercent - GRANDMASTER_HEAVY_CRITICAL_MIN_FATIGUE) / (1 - GRANDMASTER_HEAVY_CRITICAL_MIN_FATIGUE))
end

local function tryApplyKeenEdgeCritical(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not keenEdgeEnabled() or getEquippedLongBlade() == nil then
        return
    end
    if recentlyAppliedCritical(target, lastKeenEdgeCriticalTarget, lastKeenEdgeCriticalApplyTime) then
        return
    end
    if math.random() >= KEEN_EDGE_CRITICAL_CHANCE then
        return
    end

    rememberKeenEdgeCriticalApplication(target)
    showMessage(KEEN_EDGE_CRITICAL_MESSAGE)
    applyLongBladeCriticalDamage(target, KEEN_EDGE_CRITICAL_DAMAGE)
end

local function tryApplyGrandmasterHeavyCritical(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not grandmasterFormEnabled() or getEquippedLongBlade() == nil then
        return
    end
    if recentlyAppliedCritical(target, lastGrandmasterHeavyCriticalTarget, lastGrandmasterHeavyCriticalApplyTime) then
        return
    end

    local chance = getGrandmasterHeavyCriticalChance()
    if chance <= 0 or math.random() >= chance then
        return
    end

    rememberGrandmasterHeavyCriticalApplication(target)
    showMessage(GRANDMASTER_HEAVY_CRITICAL_MESSAGE)
    applyLongBladeCriticalDamage(target, GRANDMASTER_HEAVY_CRITICAL_DAMAGE)
end

local function getAttackTarget(attack)
    if type(attack) ~= "table" then
        return nil
    end

    return attack.target or attack.victim or attack.defender or attack.hitObject or attack.object
end

local function isSuccessfulPlayerMeleeHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
        return false
    end

    local meleeType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Melee
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return true
end

local function onHit(attack)
    if not isSuccessfulPlayerMeleeHit(attack) then
        return
    end

    longBladeStateRefreshDue = true
    local target = getAttackTarget(attack)
    tryApplyDuelistTempo({
        target = target,
    })
    tryApplyKeenEdgeCritical({
        target = target,
    })
    tryApplyGreatbladeCritical({
        target = target,
    })
    tryApplyGrandmasterHeavyCritical({
        target = target,
    })
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

local function onLoad()
    appliedLongBladeBonus = math.max(0, math.floor(tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0))
    appliedDuelistTempoAgilityBonus = math.max(0, math.floor(tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0))
    clearDuelistTempoBonus()
    runtimeTime = 0
    lastDuelistTempoTarget = nil
    lastDuelistTempoApplyTime = -1
    lastGreatbladeCriticalTarget = nil
    lastGreatbladeCriticalApplyTime = -1
    lastKeenEdgeCriticalTarget = nil
    lastKeenEdgeCriticalApplyTime = -1
    lastGrandmasterHeavyCriticalTarget = nil
    lastGrandmasterHeavyCriticalApplyTime = -1
    longBladeStateRefreshTimer = LONG_BLADE_STATE_REFRESH_INTERVAL
    longBladeStateRefreshDue = false
    refreshLongBladeStaticState()

    if duelistTempoRemaining > 0 then
        duelistTempoRemaining = math.max(0, duelistTempoRemaining - (tonumber(dt) or 0))
        if duelistTempoRemaining <= 0 or not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
            clearDuelistTempoBonus()
        end
    elseif appliedDuelistTempoAgilityBonus ~= 0 then
        clearDuelistTempoBonus()
    end
end

local function onUpdate(dt)
    runtimeTime = runtimeTime + (tonumber(dt) or 0)
    longBladeStateRefreshTimer = longBladeStateRefreshTimer + (tonumber(dt) or 0)
    if longBladeStateRefreshDue
        or longBladeStateRefreshTimer >= LONG_BLADE_STATE_REFRESH_INTERVAL
        or hasLongBladeAbilityFailure() then
        longBladeStateRefreshDue = false
        longBladeStateRefreshTimer = 0
        refreshLongBladeStaticState()
    end

    if duelistTempoRemaining > 0 then
        duelistTempoRemaining = math.max(0, duelistTempoRemaining - (tonumber(dt) or 0))
        if duelistTempoRemaining <= 0 or not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
            clearDuelistTempoBonus()
        end
    elseif appliedDuelistTempoAgilityBonus ~= 0 then
        clearDuelistTempoBonus()
    end
end

local function shouldUpdateLongBlade(dt)
    if duelistTempoRemaining > 0
        or appliedDuelistTempoAgilityBonus ~= 0
        or longBladeStateRefreshDue
        or hasLongBladeAbilityFailure() then
        return true
    end

    if appliedLongBladeBonus == 0
        and not duelistsFormAbilityApplied
        and not greatbladeFormAbilityApplied
        and not anyLongBladeStatePerkEnabled() then
        return false
    end

    longBladeStateRefreshTimer = longBladeStateRefreshTimer + (tonumber(dt) or 0)
    if longBladeStateRefreshTimer < LONG_BLADE_STATE_REFRESH_INTERVAL then
        return false
    end

    longBladeStateRefreshTimer = 0
    longBladeStateRefreshDue = true
    return true
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    eventHandlers = {
        SkillPerkSystem_TryDuelistsTempo = tryApplyDuelistTempo,
        SkillPerkSystem_TryGreatbladeCritical = tryApplyGreatbladeCritical,
        SkillPerkSystem_TryKeenEdgeCritical = tryApplyKeenEdgeCritical,
        SkillPerkSystem_TryGrandmasterHeavyCritical = tryApplyGrandmasterHeavyCritical,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdateLongBlade,
        onLoad = onLoad,
    },
}

end


----------------------------------------------------------------------
-- short blade runtime logic
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local VITAL_STRIKE_PERK_ID = "shortblade_vital_strike"
local FLASH_CUT_PERK_ID = "shortblade_flash_cut"
local CLOSE_MEASURE_PERK_ID = "shortblade_close_measure"
local SHADOW_STEP_PERK_ID = "shortblade_shadow_step"
local MASTER_OF_KNIVES_PERK_ID = "shortblade_master_of_knives"
local SHADOW_STEP_ABILITY_ID = "sps_daggersense"
local SHADOW_STEP_REFRESH_INTERVAL = 0.5
local SHORT_BLADE_STATE_EVENT = "SkillPerkSystem_ShortBladeState"
local CLOSE_MEASURE_TRIGGER_EVENT = "SkillPerkSystem_CloseMeasureTriggered"
local MASTER_OF_KNIVES_TRIGGER_EVENT = "SkillPerkSystem_MasterOfKnivesTriggered"
local SHORT_BLADE_STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_ShortBlade"
local CLOSE_MEASURE_APPLIED_KEY = "close_measure.applied_agility_bonus"
local CLOSE_MEASURE_MAX_STACKS = 5
local CLOSE_MEASURE_DURATION = 5.0
local CLOSE_MEASURE_AGILITY_PER_STACK = 2
local MASTER_OF_KNIVES_AGILITY_APPLIED_KEY = "master_of_knives.applied_agility_bonus"
local MASTER_OF_KNIVES_LUCK_APPLIED_KEY = "master_of_knives.applied_luck_bonus"
local MASTER_OF_KNIVES_DURATION = 5.0
local MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK = 2

local Actor = types.Actor
local Weapon = types.Weapon
local shortBladeStorageSection = storage.playerSection(SHORT_BLADE_STORAGE_SECTION_ID)
local shortBladeStateDirty = true
local lastShortBladeStateKey = nil
local closeMeasureStacks = 0
local closeMeasureRemaining = 0
local appliedCloseMeasureAgilityBonus = tonumber(shortBladeStorageSection:get(CLOSE_MEASURE_APPLIED_KEY)) or 0
local masterOfKnivesStacks = {}
local appliedMasterOfKnivesAgilityBonus = tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_AGILITY_APPLIED_KEY)) or 0
local appliedMasterOfKnivesLuckBonus = tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_LUCK_APPLIED_KEY)) or 0
local shadowStepAbilityApplied = false
local shadowStepRefreshTimer = SHADOW_STEP_REFRESH_INTERVAL
local shadowStepRefreshDue = true

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end



local function shadowStepEnabled()
    return hasEnabledPerk(SHADOW_STEP_PERK_ID)
end

local function getEquippedItem(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    local recordId = type(item) == "string" and item or item.recordId
    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[recordId]
    end

    if type(item) == "table" and item.type ~= nil and type(item.type.records) == "table" and type(recordId) == "string" then
        return item.type.records[recordId]
    end

    return nil
end

local function isShortBladeRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.ShortBladeOneHand)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function hasEquippedShortBlade()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return false
    end

    return isShortBladeRecord(getWeaponRecord(weapon))
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        return nil
    end

    return spells
end

local function resolveAbilityRecord(abilityId)
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[abilityId]
end

local function spellBookHasAbility(spells, abilityId)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, hasById = pcall(function() return spells:has(abilityId) end)
        if okHasById and hasById == true then
            return true
        end

        local record = resolveAbilityRecord(abilityId)
        if record ~= nil then
            local okHasByRecord, hasByRecord = pcall(function() return spells:has(record) end)
            if okHasByRecord and hasByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == abilityId then
            return true
        end
    end

    return false
end

local function addAbility(spells, abilityId)
    if type(spells.add) ~= "function" then
        return false
    end

    local okAddById = pcall(function() spells:add(abilityId) end)
    if okAddById then
        return true
    end

    local record = resolveAbilityRecord(abilityId)
    if record == nil then
        return false
    end

    local okAddByRecord = pcall(function() spells:add(record) end)
    return okAddByRecord == true
end

local function removeAbility(spells, abilityId)
    if type(spells.remove) ~= "function" then
        return false
    end

    local okRemoveById = pcall(function() spells:remove(abilityId) end)
    if okRemoveById then
        return true
    end

    local record = resolveAbilityRecord(abilityId)
    if record == nil then
        return false
    end

    local okRemoveByRecord = pcall(function() spells:remove(record) end)
    return okRemoveByRecord == true
end

local function updateShadowStepAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHave = shadowStepEnabled() and hasEquippedShortBlade()
    local hasAbility = spellBookHasAbility(spells, SHADOW_STEP_ABILITY_ID)
    if shouldHave and not hasAbility then
        if addAbility(spells, SHADOW_STEP_ABILITY_ID) then
            shadowStepAbilityApplied = true
        end
    elseif (not shouldHave) and (hasAbility or shadowStepAbilityApplied) then
        if removeAbility(spells, SHADOW_STEP_ABILITY_ID) then
            shadowStepAbilityApplied = false
        end
    else
        shadowStepAbilityApplied = hasAbility and shouldHave
    end
end

local function resolveAttributeStat(attributeName)
    local attributes = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes
    local accessor = attributes ~= nil and attributes[attributeName] or nil
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function resolveAgilityStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function resolveLuckStat()
    return resolveAttributeStat("luck")
end

local function applyCloseMeasureAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedCloseMeasureAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedCloseMeasureAgilityBonus = desired
    shortBladeStorageSection:set(CLOSE_MEASURE_APPLIED_KEY, desired)
end

local function clearCloseMeasureBonus()
    closeMeasureStacks = 0
    closeMeasureRemaining = 0
    applyCloseMeasureAgilityBonus(0)
end


local function applyMasterOfKnivesAttributeBonus(statResolver, appliedBonus, storageKey, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBonus) or 0))
    if desired == current then
        return current
    end

    local stat = statResolver()
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    shortBladeStorageSection:set(storageKey, desired)
    return desired
end

local function applyMasterOfKnivesBonus(targetBonus)
    appliedMasterOfKnivesAgilityBonus = applyMasterOfKnivesAttributeBonus(
        resolveAgilityStat,
        appliedMasterOfKnivesAgilityBonus,
        MASTER_OF_KNIVES_AGILITY_APPLIED_KEY,
        targetBonus
    )
    appliedMasterOfKnivesLuckBonus = applyMasterOfKnivesAttributeBonus(
        resolveLuckStat,
        appliedMasterOfKnivesLuckBonus,
        MASTER_OF_KNIVES_LUCK_APPLIED_KEY,
        targetBonus
    )
end

local function clearMasterOfKnivesBonus()
    masterOfKnivesStacks = {}
    applyMasterOfKnivesBonus(0)
end

local function refreshMasterOfKnivesBonus(dt)
    local elapsed = math.max(0, tonumber(dt) or 0)
    for index = #masterOfKnivesStacks, 1, -1 do
        local remaining = math.max(0, tonumber(masterOfKnivesStacks[index]) or 0) - elapsed
        if remaining <= 0 then
            table.remove(masterOfKnivesStacks, index)
        else
            masterOfKnivesStacks[index] = remaining
        end
    end

    if #masterOfKnivesStacks == 0 then
        applyMasterOfKnivesBonus(0)
    else
        applyMasterOfKnivesBonus(#masterOfKnivesStacks * MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK)
    end
end

local function markShortBladeStateDirty()
    shortBladeStateDirty = true
end

local function publishShortBladeState(force)
    local vitalStrikeEnabled = hasEnabledPerk(VITAL_STRIKE_PERK_ID)
    local flashCutEnabled = hasEnabledPerk(FLASH_CUT_PERK_ID)
    local closeMeasureEnabled = hasEnabledPerk(CLOSE_MEASURE_PERK_ID)
    local masterOfKnivesEnabled = hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID)
    local stateKey = tostring(vitalStrikeEnabled) .. ":" .. tostring(flashCutEnabled) .. ":" .. tostring(closeMeasureEnabled) .. ":" .. tostring(masterOfKnivesEnabled)
    if not force and stateKey == lastShortBladeStateKey then
        return
    end

    lastShortBladeStateKey = stateKey
    core.sendGlobalEvent(SHORT_BLADE_STATE_EVENT, {
        playerId = pself.id,
        vitalStrikeEnabled = vitalStrikeEnabled,
        flashCutEnabled = flashCutEnabled,
        closeMeasureEnabled = closeMeasureEnabled,
        masterOfKnivesEnabled = masterOfKnivesEnabled,
    })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" then
        return
    end
    if data.perkID == VITAL_STRIKE_PERK_ID or data.perkID == FLASH_CUT_PERK_ID or data.perkID == CLOSE_MEASURE_PERK_ID or data.perkID == SHADOW_STEP_PERK_ID or data.perkID == MASTER_OF_KNIVES_PERK_ID then
        markShortBladeStateDirty()
        if data.perkID == SHADOW_STEP_PERK_ID then
            shadowStepRefreshDue = true
        end
        if data.perkID == CLOSE_MEASURE_PERK_ID and not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
            clearCloseMeasureBonus()
        end
        if data.perkID == MASTER_OF_KNIVES_PERK_ID and not hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
            clearMasterOfKnivesBonus()
        end
    end
end

local function handleMasterOfKnivesTrigger(data)
    if type(data) ~= "table" or data.playerId ~= pself.id then
        return
    end
    if not hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
        clearMasterOfKnivesBonus()
        return
    end

    masterOfKnivesStacks[#masterOfKnivesStacks + 1] = MASTER_OF_KNIVES_DURATION
    applyMasterOfKnivesBonus(#masterOfKnivesStacks * MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK)
end

local function handleCloseMeasureTrigger(data)
    if type(data) ~= "table" or data.playerId ~= pself.id then
        return
    end
    if not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
        clearCloseMeasureBonus()
        return
    end

    closeMeasureStacks = math.min(CLOSE_MEASURE_MAX_STACKS, closeMeasureStacks + 1)
    closeMeasureRemaining = CLOSE_MEASURE_DURATION
    applyCloseMeasureAgilityBonus(closeMeasureStacks * CLOSE_MEASURE_AGILITY_PER_STACK)
end


__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function(dt)
            if #masterOfKnivesStacks > 0 then
                if hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
                    refreshMasterOfKnivesBonus(dt)
                else
                    clearMasterOfKnivesBonus()
                end
            elseif appliedMasterOfKnivesAgilityBonus ~= 0 or appliedMasterOfKnivesLuckBonus ~= 0 then
                clearMasterOfKnivesBonus()
            end

            if closeMeasureRemaining > 0 then
                closeMeasureRemaining = math.max(0, closeMeasureRemaining - (tonumber(dt) or 0))
                if closeMeasureRemaining <= 0 or not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
                    clearCloseMeasureBonus()
                end
            elseif appliedCloseMeasureAgilityBonus ~= 0 then
                clearCloseMeasureBonus()
            end

            if shadowStepRefreshDue or shadowStepAbilityApplied then
                shadowStepRefreshDue = false
                shadowStepRefreshTimer = 0
                updateShadowStepAbility()
            end

            if shortBladeStateDirty then
                shortBladeStateDirty = false
                publishShortBladeState(false)
            end
        end,
        shouldUpdate = function(dt)
            if shortBladeStateDirty or closeMeasureRemaining > 0 or appliedCloseMeasureAgilityBonus ~= 0 or #masterOfKnivesStacks > 0 or appliedMasterOfKnivesAgilityBonus ~= 0 or appliedMasterOfKnivesLuckBonus ~= 0 or shadowStepRefreshDue or shadowStepAbilityApplied then
                return true
            end

            if not shadowStepEnabled() then
                return false
            end

            shadowStepRefreshTimer = shadowStepRefreshTimer + (tonumber(dt) or 0)
            if shadowStepRefreshTimer < SHADOW_STEP_REFRESH_INTERVAL then
                return false
            end

            shadowStepRefreshDue = true
            return true
        end,
        onLoad = function()
            lastShortBladeStateKey = nil
            shortBladeStateDirty = true
            appliedCloseMeasureAgilityBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(CLOSE_MEASURE_APPLIED_KEY)) or 0))
            appliedMasterOfKnivesAgilityBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_AGILITY_APPLIED_KEY)) or 0))
            appliedMasterOfKnivesLuckBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_LUCK_APPLIED_KEY)) or 0))
            clearCloseMeasureBonus()
            clearMasterOfKnivesBonus()
            shadowStepAbilityApplied = false
            shadowStepRefreshTimer = SHADOW_STEP_REFRESH_INTERVAL
            shadowStepRefreshDue = true
            updateShadowStepAbility()
            publishShortBladeState(true)
            shortBladeStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        [CLOSE_MEASURE_TRIGGER_EVENT] = handleCloseMeasureTrigger,
        [MASTER_OF_KNIVES_TRIGGER_EVENT] = handleMasterOfKnivesTrigger,
        SkillPerkSystem_ShortBladeStateDirty = function() markShortBladeStateDirty() end,
        UiModeChanged = function()
            markShortBladeStateDirty()
            shadowStepRefreshDue = true
        end,
    },
}

end


----------------------------------------------------------------------
-- axe runtime logic (from axe_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BLOODLETTER_PERK_ID = "axe_bloodletter"
local THROWN_FUNDAMENTALS_PERK_ID = "marksman_thrown_fundamentals"
local PINNING_SHOT_PERK_ID = "marksman_pinning_shot"
local TRICK_THROW_PERK_ID = "marksman_trick_throw"
local DEADEYE_MASTERY_PERK_ID = "marksman_deadeye_mastery"
local DRAGGING_WOUND_PERK_ID = "axe_dragging_wound"
local HEWER_HEART_PERK_ID = "axe_hewer_heart"
local CRIMSON_CLEAVE_PERK_ID = "axe_crimson_cleave"
local IRON_CANOPY_PERK_ID = "axe_iron_canopy"
local FELLSTAR_CROWN_PERK_ID = "axe_fellstar_crown"
local EXECUTION_DAMAGE_PERK_IDS = {
    "axe_kindling_grip",
    "axe_crescent_hook",
}
local STATE_EVENT = "SkillPerkSystem_AxeKindlingGripState"
local FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER = 1.10
local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local FELLSTAR_CROWN_FEATHER_KEY = "axe.fellstar_crown.feather"

local axeStateDirty = true
local axeFeatherDirty = true
local lastStateKey = nil
local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local appliedAxeFeather = math.max(0, tonumber(effectsSection:get(FELLSTAR_CROWN_FEATHER_KEY)) or 0)

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function executionDamagePerkCount()
    local count = 0
    for _, perkID in ipairs(EXECUTION_DAMAGE_PERK_IDS) do
        if hasEnabledPerk(perkID) then
            count = count + 1
        end
    end
    return count
end

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function weaponTypeEquals(record, typeName)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE[typeName])
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isAxeRecord(record)
    return weaponTypeEquals(record, "AxeOneHand") or weaponTypeEquals(record, "AxeTwoHand")
end

local function getEquippedAxeRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isAxeRecord(record) then
        return nil
    end

    return record
end

local function getEquippedAxeWeight()
    local record = getEquippedAxeRecord()
    if record == nil then
        return 0
    end

    return math.max(0, tonumber(record.weight) or 0)
end

local function modifyFeather(delta)
    if Actor == nil or type(Actor.activeEffects) ~= "function" then
        return false
    end

    local effectType = core.magic and core.magic.EFFECT_TYPE and core.magic.EFFECT_TYPE.Feather
    if effectType == nil then
        return false
    end

    local okEffects, activeEffects = pcall(Actor.activeEffects, pself)
    if not okEffects or activeEffects == nil or type(activeEffects.modify) ~= "function" then
        return false
    end

    local okModify = pcall(activeEffects.modify, activeEffects, delta, effectType)
    return okModify
end

local function refreshFellstarCrownFeather()
    local targetFeather = 0
    if hasEnabledPerk(FELLSTAR_CROWN_PERK_ID) then
        targetFeather = getEquippedAxeWeight()
    end

    if targetFeather == appliedAxeFeather then
        return
    end

    local delta = targetFeather - appliedAxeFeather
    if modifyFeather(delta) then
        appliedAxeFeather = targetFeather
        effectsSection:set(FELLSTAR_CROWN_FEATHER_KEY, appliedAxeFeather)
    end
end

local function markAxeStateDirty()
    axeStateDirty = true
    axeFeatherDirty = true
end

local function handleAxeAnimation(event)
    markAxeStateDirty()
    if not event.isWeaponAttackWindup then
        return
    end
    if not hasEnabledPerk(FELLSTAR_CROWN_PERK_ID) then
        return
    end
    if getEquippedAxeRecord() == nil then
        return
    end

    multiplyAnimationSpeed(event.options, FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER)
end
registerBasepackAnimationHandler(handleAxeAnimation)

local AXE_STATE_PERKS = {
    axe_kindling_grip = true,
    axe_crescent_hook = true,
    axe_bloodletter = true,
    axe_dragging_wound = true,
    axe_hewer_heart = true,
    axe_crimson_cleave = true,
    axe_iron_canopy = true,
    axe_fellstar_crown = true,
    marksman_thrown_fundamentals = true,
    marksman_pinning_shot = true,
    marksman_trick_throw = true,
    marksman_deadeye_mastery = true,
}

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or AXE_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markAxeStateDirty()
end

local function publishState(force)
    local enabledCount = executionDamagePerkCount()
    local bloodletterEnabled = hasEnabledPerk(BLOODLETTER_PERK_ID)
    local draggingWoundEnabled = hasEnabledPerk(DRAGGING_WOUND_PERK_ID)
    local hewerHeartEnabled = hasEnabledPerk(HEWER_HEART_PERK_ID)
    local crimsonCleaveEnabled = hasEnabledPerk(CRIMSON_CLEAVE_PERK_ID)
    local ironCanopyEnabled = hasEnabledPerk(IRON_CANOPY_PERK_ID)
    local thrownFundamentalsEnabled = hasEnabledPerk(THROWN_FUNDAMENTALS_PERK_ID)
    local trickThrowEnabled = hasEnabledPerk(TRICK_THROW_PERK_ID)
    local pinningShotEnabled = hasEnabledPerk(PINNING_SHOT_PERK_ID)
    local deadeyeMasteryEnabled = hasEnabledPerk(DEADEYE_MASTERY_PERK_ID)
    local stateKey = tostring(enabledCount) .. ":" .. tostring(bloodletterEnabled) .. ":" .. tostring(draggingWoundEnabled) .. ":" .. tostring(hewerHeartEnabled) .. ":" .. tostring(crimsonCleaveEnabled) .. ":" .. tostring(ironCanopyEnabled) .. ":" .. tostring(thrownFundamentalsEnabled) .. ":" .. tostring(trickThrowEnabled) .. ":" .. tostring(pinningShotEnabled) .. ":" .. tostring(deadeyeMasteryEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        enabled = enabledCount > 0,
        damageBonusCount = enabledCount,
        bloodletterEnabled = bloodletterEnabled,
        draggingWoundEnabled = draggingWoundEnabled,
        hewerHeartEnabled = hewerHeartEnabled,
        crimsonCleaveEnabled = crimsonCleaveEnabled,
        ironCanopyEnabled = ironCanopyEnabled,
        thrownFundamentalsEnabled = thrownFundamentalsEnabled,
        trickThrowEnabled = trickThrowEnabled,
        pinningShotEnabled = pinningShotEnabled,
        deadeyeMasteryEnabled = deadeyeMasteryEnabled,
    })
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function()
            if axeFeatherDirty then
                axeFeatherDirty = false
                refreshFellstarCrownFeather()
            end
            if axeStateDirty then
                axeStateDirty = false
                publishState(false)
            end
        end,
        shouldUpdate = function()
            return axeFeatherDirty or axeStateDirty
        end,
        onLoad = function()
            lastStateKey = nil
            appliedAxeFeather = math.max(0, tonumber(effectsSection:get(FELLSTAR_CROWN_FEATHER_KEY)) or 0)
            markAxeStateDirty()
            refreshFellstarCrownFeather()
            publishState(true)
            axeFeatherDirty = false
            axeStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_AxeStateDirty = function() markAxeStateDirty() end,
        UiModeChanged = function() markAxeStateDirty() end,
    },
}

end

----------------------------------------------------------------------
-- marksman runtime logic (from marksman_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local input = require("openmw.input")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BOW_FUNDAMENTALS_PERK_ID = "marksman_bow_fundamentals"
local QUICK_CAST_PERK_ID = "marksman_quick_cast"
local STEADY_DRAW_PERK_ID = "marksman_steady_draw"
local DEADEYE_MASTERY_PERK_ID = "marksman_deadeye_mastery"
local BOW_FUNDAMENTALS_DRAW_SPEED_MULTIPLIER = 1.20
local BOW_FUNDAMENTALS_AGILITY_BONUS = 5
local DEADEYE_MASTERY_AGILITY_BONUS = 10
local QUICK_CAST_ATTACK_SPEED_MULTIPLIER = 1.80
local STEADY_DRAW_MAX_HOLD_SECONDS = 4.0
local STEADY_DRAW_MAX_DAMAGE_BONUS = 0.30
local STEADY_DRAW_PENDING_SHOT_WINDOW = 5.0
local STEADY_DRAW_STATE_EVENT = "SkillPerkSystem_MarksmanSteadyDrawState"
local MARKSMAN_STATE_REFRESH_INTERVAL = 0.5
local STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL = 0.25
local MARKSMAN_EQUIPMENT_SCAN_WINDOW = 1.5
local appliedBowFundamentalsAgilityBonus = 0
local bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
local steadyDrawIdleFrameCheckTimer = STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL
local marksmanAgilityDirty = true
local marksmanEquipmentScanRemaining = 0
local steadyDrawArmedWindowRemaining = 0
local steadyDrawHoldSeconds = 0
local steadyDrawWasHoldingAttack = false
local steadyDrawShotSequence = 0

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function weaponTypeEquals(record, typeName)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE[typeName])
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isBowRecord(record)
    return weaponTypeEquals(record, "MarksmanBow")
end

local function isCrossbowRecord(record)
    return weaponTypeEquals(record, "MarksmanCrossbow")
end

local function isBowOrCrossbowRecord(record)
    return isBowRecord(record) or isCrossbowRecord(record)
end

local function getEquippedBowRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isBowRecord(record) then
        return nil
    end

    return record
end

local function getEquippedBowOrCrossbowRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isBowOrCrossbowRecord(record) then
        return nil
    end

    return record
end

local function resolveAgilityStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyBowFundamentalsAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBowFundamentalsAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedBowFundamentalsAgilityBonus = desired
end

local function refreshBowFundamentalsAgilityBonus()
    local desiredBonus = 0
    local bowOrCrossbowRecord = getEquippedBowOrCrossbowRecord()
    if hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) and bowOrCrossbowRecord ~= nil then
        desiredBonus = desiredBonus + BOW_FUNDAMENTALS_AGILITY_BONUS
    end

    if hasEnabledPerk(DEADEYE_MASTERY_PERK_ID) and bowOrCrossbowRecord ~= nil then
        desiredBonus = desiredBonus + DEADEYE_MASTERY_AGILITY_BONUS
    end

    applyBowFundamentalsAgilityBonus(desiredBonus)
end

local function markMarksmanEquipmentDirty(scanWindow)
    marksmanAgilityDirty = true
    marksmanEquipmentScanRemaining = math.max(marksmanEquipmentScanRemaining, tonumber(scanWindow) or MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
end

local MARKSMAN_STATE_PERKS = {
    marksman_bow_fundamentals = true,
    marksman_deadeye_mastery = true,
    marksman_steady_draw = true,
}

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or MARKSMAN_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    if data.perkID == STEADY_DRAW_PERK_ID then
        steadyDrawArmedWindowRemaining = math.max(steadyDrawArmedWindowRemaining, MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    end
end

local function shouldUpdateBowFundamentals(dt)
    if marksmanAgilityDirty then
        return true
    end

    if appliedBowFundamentalsAgilityBonus ~= 0
        and (not (hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) or hasEnabledPerk(DEADEYE_MASTERY_PERK_ID))
            or getEquippedBowOrCrossbowRecord() == nil) then
        return true
    end

    marksmanEquipmentScanRemaining = math.max(0, marksmanEquipmentScanRemaining - (tonumber(dt) or 0))
    if marksmanEquipmentScanRemaining <= 0 then
        return false
    end

    bowFundamentalsRefreshTimer = bowFundamentalsRefreshTimer + (tonumber(dt) or 0)
    return bowFundamentalsRefreshTimer >= MARKSMAN_STATE_REFRESH_INTERVAL
end

local function getEquippedThrownMarksmanRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not weaponTypeEquals(record, "MarksmanThrown") then
        return nil
    end

    return record
end

local function steadyDrawAttackHeld()
    if input == nil or type(input.getBooleanActionValue) ~= "function" then
        return false
    end

    return input.getBooleanActionValue("Use") == true
end

local function clearSteadyDrawCharge()
    steadyDrawHoldSeconds = 0
    steadyDrawWasHoldingAttack = false
end

local function publishSteadyDrawShot(multiplier, expiresAt)
    steadyDrawShotSequence = steadyDrawShotSequence + 1
    core.sendGlobalEvent(STEADY_DRAW_STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        multiplier = multiplier,
        expiresAt = expiresAt,
        sequence = steadyDrawShotSequence,
    })
end

local function shouldFrameSteadyDraw(dt)
    if steadyDrawHoldSeconds > 0 or steadyDrawWasHoldingAttack then
        return true
    end

    steadyDrawArmedWindowRemaining = math.max(0, steadyDrawArmedWindowRemaining - (tonumber(dt) or 0))
    if steadyDrawArmedWindowRemaining <= 0 then
        return false
    end

    steadyDrawIdleFrameCheckTimer = steadyDrawIdleFrameCheckTimer + (tonumber(dt) or 0)
    if steadyDrawIdleFrameCheckTimer < STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL then
        return false
    end
    steadyDrawIdleFrameCheckTimer = 0

    return hasEnabledPerk(STEADY_DRAW_PERK_ID) and getEquippedBowOrCrossbowRecord() ~= nil
end

local function updateSteadyDraw(dt)
    if not hasEnabledPerk(STEADY_DRAW_PERK_ID) or getEquippedBowOrCrossbowRecord() == nil then
        clearSteadyDrawCharge()
        return
    end

    local holdingAttack = steadyDrawAttackHeld()
    if holdingAttack then
        steadyDrawHoldSeconds = math.min(
            steadyDrawHoldSeconds + (tonumber(dt) or 0),
            STEADY_DRAW_MAX_HOLD_SECONDS
        )
    elseif steadyDrawWasHoldingAttack and steadyDrawHoldSeconds > 0 then
        local now = core.getSimulationTime()
        local ratio = math.min(steadyDrawHoldSeconds / STEADY_DRAW_MAX_HOLD_SECONDS, 1)
        publishSteadyDrawShot(
            1 + (ratio * STEADY_DRAW_MAX_DAMAGE_BONUS),
            now + STEADY_DRAW_PENDING_SHOT_WINDOW
        )
        steadyDrawHoldSeconds = 0
    end

    steadyDrawWasHoldingAttack = holdingAttack
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(applySteadyDrawDamage)
end

local function handleMarksmanAnimation(event)
    markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    if hasEnabledPerk(STEADY_DRAW_PERK_ID) then
        steadyDrawArmedWindowRemaining = math.max(steadyDrawArmedWindowRemaining, MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    end

    if not event.isWeaponAttackWindup then
        return
    end

    if hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) and getEquippedBowRecord() ~= nil then
        multiplyAnimationSpeed(event.options, BOW_FUNDAMENTALS_DRAW_SPEED_MULTIPLIER)
    end

    if hasEnabledPerk(QUICK_CAST_PERK_ID) and getEquippedThrownMarksmanRecord() ~= nil then
        multiplyAnimationSpeed(event.options, QUICK_CAST_ATTACK_SPEED_MULTIPLIER)
    end
end
registerBasepackAnimationHandler(handleMarksmanAnimation)

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function()
            marksmanAgilityDirty = false
            bowFundamentalsRefreshTimer = 0
            refreshBowFundamentalsAgilityBonus()
        end,
        shouldUpdate = shouldUpdateBowFundamentals,
        onFrame = function(dt)
            updateSteadyDraw(dt)
        end,
        shouldFrame = shouldFrameSteadyDraw,
        onLoad = function()
            appliedBowFundamentalsAgilityBonus = 0
            bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
            steadyDrawIdleFrameCheckTimer = STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL
            marksmanAgilityDirty = true
            marksmanEquipmentScanRemaining = MARKSMAN_EQUIPMENT_SCAN_WINDOW
            steadyDrawArmedWindowRemaining = MARKSMAN_EQUIPMENT_SCAN_WINDOW
            steadyDrawHoldSeconds = 0
            steadyDrawWasHoldingAttack = false
            steadyDrawShotSequence = 0
            refreshBowFundamentalsAgilityBonus()
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_MarksmanStateDirty = function() markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW) end,
        UiModeChanged = function() markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW) end,
    },
}

end

----------------------------------------------------------------------
-- spear runtime logic
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local POINT_CONTROL_PERK_ID = "spear_point_control"
local DRIVING_STEP_PERK_ID = "spear_driving_step"
local HOOK_AND_TURN_PERK_ID = "spear_hook_and_turn"
local LINE_BREAKER_PERK_ID = "spear_line_breaker"
local MASTER_VANGUARD_PERK_ID = "spear_master_vanguard"
local POINT_CONTROL_ENDURANCE_BONUS = 5
local HOOK_AND_TURN_WINDOW = 5.0
local HOOK_AND_TURN_HEALTH_MULTIPLIER = 1.15
local HOOK_AND_TURN_FATIGUE_DAMAGE = 10
local MASTER_VANGUARD_ATTRIBUTE_BONUS = 5
local MASTER_VANGUARD_DURATION = 10.0
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_Spear"
local MASTER_VANGUARD_ENDURANCE_APPLIED_KEY = "master_vanguard.applied_endurance_bonus"
local MASTER_VANGUARD_AGILITY_APPLIED_KEY = "master_vanguard.applied_agility_bonus"
local SPEAR_STATE_EVENT = "SkillPerkSystem_SpearPointControlState"
local SPEAR_STATE_REFRESH_INTERVAL = 0.5
local SPEAR_EQUIPMENT_SCAN_WINDOW = 1.5

local storageSection = storage.playerSection(STORAGE_SECTION_ID)

local appliedPointControlEnduranceBonus = 0
local spearStateDirty = true
local spearEquipmentScanRemaining = SPEAR_EQUIPMENT_SCAN_WINDOW
local spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
local lastSpearStateKey = nil
local hookAndTurnPrimedUntil = 0
local appliedMasterVanguardEnduranceBonus = tonumber(storageSection:get(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY)) or 0
local appliedMasterVanguardAgilityBonus = tonumber(storageSection:get(MASTER_VANGUARD_AGILITY_APPLIED_KEY)) or 0
local masterVanguardRemaining = 0
local spearRuntimeTime = 0
local lastMasterVanguardTarget = nil
local lastMasterVanguardApplyTime = -1

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function isSpearRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.SpearTwoWide)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function getEquippedSpearRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isSpearRecord(record) then
        return nil
    end

    return record
end

local function isMeleeAttack(attack)
    local sourceTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_SOURCE_TYPES or nil
    local expected = sourceTypes ~= nil and tonumber(sourceTypes.Melee) or nil
    local actual = type(attack) == "table" and tonumber(attack.sourceType) or nil
    return expected == nil or actual == nil or actual == expected
end


local function resolveAttackShapeFromText(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = string.lower(value)
    if string.find(normalized, "thrust", 1, true) ~= nil then
        return "thrust"
    end
    if string.find(normalized, "slash", 1, true) ~= nil then
        return "slash"
    end
    if string.find(normalized, "chop", 1, true) ~= nil then
        return "chop"
    end

    return nil
end

local function resolveAttackShapeFromType(value)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    if attackTypes ~= nil then
        if value == attackTypes.Chop then
            return "chop"
        end
        if value == attackTypes.Slash then
            return "slash"
        end
        if value == attackTypes.Thrust then
            return "thrust"
        end
    end

    return resolveAttackShapeFromText(value)
end

local function resolveSpearAttackShape(attack)
    if type(attack) ~= "table" then
        return nil
    end

    local candidates = {
        attack.attackType,
        attack.type,
        attack.attack,
        attack.attackKind,
        attack.attackSource,
        attack.source,
        attack.animation,
        attack.animationName,
        attack.groupName,
        attack.startKey,
        attack.stopKey,
    }

    for _, candidate in ipairs(candidates) do
        local shape = resolveAttackShapeFromType(candidate)
        if shape ~= nil then
            return shape
        end
    end

    return nil
end

local function isSuccessfulPlayerSpearHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if getEquippedSpearRecord() == nil then
        return false
    end

    return type(attack.damage) == "table"
end

local function isSuccessfulPlayerSpearHitForPerk(attack, perkID)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
        return false
    end
    if not hasEnabledPerk(perkID) then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if getEquippedSpearRecord() == nil then
        return false
    end

    return type(attack.damage) == "table"
end

local function resolveMasterVanguardAttributeStat(attributeName)
    local attributes = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes
        or nil
    local accessor = nil
    if attributeName == "endurance" then
        accessor = attributes ~= nil and attributes.endurance or nil
    elseif attributeName == "agility" then
        accessor = attributes ~= nil and attributes.agility or nil
    end
    if type(accessor) ~= "function" then
        return nil
    end

    local ok, stat = pcall(accessor, pself)
    if not ok then
        return nil
    end

    return stat
end

local function applyAttributeBonus(attributeName, currentBonus, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(currentBonus) or 0))
    if desired == current then
        return current
    end

    local stat = resolveMasterVanguardAttributeStat(attributeName)
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    return desired
end

local function applyMasterVanguardBonuses(targetBonus)
    appliedMasterVanguardEnduranceBonus = applyAttributeBonus(
        "endurance",
        appliedMasterVanguardEnduranceBonus,
        targetBonus
    )
    appliedMasterVanguardAgilityBonus = applyAttributeBonus(
        "agility",
        appliedMasterVanguardAgilityBonus,
        targetBonus
    )
    storageSection:set(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY, appliedMasterVanguardEnduranceBonus)
    storageSection:set(MASTER_VANGUARD_AGILITY_APPLIED_KEY, appliedMasterVanguardAgilityBonus)
end

local function clearMasterVanguardBonuses()
    masterVanguardRemaining = 0
    applyMasterVanguardBonuses(0)
end

local function refreshMasterVanguardBonuses(dt)
    if masterVanguardRemaining > 0 then
        masterVanguardRemaining = math.max(0, masterVanguardRemaining - (tonumber(dt) or 0))
        if masterVanguardRemaining <= 0
            or not hasEnabledPerk(MASTER_VANGUARD_PERK_ID)
            or getEquippedSpearRecord() == nil then
            clearMasterVanguardBonuses()
        end
    elseif appliedMasterVanguardEnduranceBonus ~= 0 or appliedMasterVanguardAgilityBonus ~= 0 then
        clearMasterVanguardBonuses()
    end
end

local function recentlyAppliedMasterVanguard(target)
    return target ~= nil and target == lastMasterVanguardTarget and (spearRuntimeTime - lastMasterVanguardApplyTime) < 0.05
end

local function rememberMasterVanguardApplication(target)
    lastMasterVanguardTarget = target
    lastMasterVanguardApplyTime = spearRuntimeTime
end

local function tryApplyMasterVanguard(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target ~= nil and type(target.isValid) == "function" and not target:isValid() then
        return
    end
    if not hasEnabledPerk(MASTER_VANGUARD_PERK_ID) or getEquippedSpearRecord() == nil then
        return
    end
    if recentlyAppliedMasterVanguard(target) then
        return
    end

    rememberMasterVanguardApplication(target)
    masterVanguardRemaining = MASTER_VANGUARD_DURATION
    applyMasterVanguardBonuses(MASTER_VANGUARD_ATTRIBUTE_BONUS)
end

local function updateHookAndTurn(attack)
    if not isSuccessfulPlayerSpearHitForPerk(attack, HOOK_AND_TURN_PERK_ID) then
        return
    end

    local shape = resolveSpearAttackShape(attack)
    if shape == nil then
        return
    end

    local now = core.getSimulationTime()
    if shape == "chop" or shape == "slash" then
        hookAndTurnPrimedUntil = now + HOOK_AND_TURN_WINDOW
        return
    end

    if shape ~= "thrust" then
        return
    end

    if hookAndTurnPrimedUntil <= 0 or hookAndTurnPrimedUntil < now then
        hookAndTurnPrimedUntil = 0
        return
    end

    hookAndTurnPrimedUntil = 0
    attack.damage.health = (tonumber(attack.damage.health) or 0) * HOOK_AND_TURN_HEALTH_MULTIPLIER
    attack.damage.fatigue = (tonumber(attack.damage.fatigue) or 0) + HOOK_AND_TURN_FATIGUE_DAMAGE
end
local function resolveEnduranceStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.endurance
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyPointControlEnduranceBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedPointControlEnduranceBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveEnduranceStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedPointControlEnduranceBonus = desired
end

local function refreshPointControlEnduranceBonus()
    local desiredBonus = 0
    if hasEnabledPerk(POINT_CONTROL_PERK_ID) and getEquippedSpearRecord() ~= nil then
        desiredBonus = POINT_CONTROL_ENDURANCE_BONUS
    end

    applyPointControlEnduranceBonus(desiredBonus)
end

local function publishSpearPointControlState(force)
    local pointControlEnabled = hasEnabledPerk(POINT_CONTROL_PERK_ID)
    local masterVanguardEnabled = hasEnabledPerk(MASTER_VANGUARD_PERK_ID)
    local drivingStepEnabled = hasEnabledPerk(DRIVING_STEP_PERK_ID)
    local hookAndTurnEnabled = hasEnabledPerk(HOOK_AND_TURN_PERK_ID)
    local lineBreakerEnabled = hasEnabledPerk(LINE_BREAKER_PERK_ID)
    local stateKey = tostring(pointControlEnabled) .. ":" .. tostring(drivingStepEnabled) .. ":" .. tostring(hookAndTurnEnabled) .. ":" .. tostring(lineBreakerEnabled) .. ":" .. tostring(masterVanguardEnabled)
    if not force and stateKey == lastSpearStateKey then
        return
    end

    lastSpearStateKey = stateKey
    core.sendGlobalEvent(SPEAR_STATE_EVENT, {
        playerId = pself.id,
        pointControlEnabled = pointControlEnabled,
        drivingStepEnabled = drivingStepEnabled,
        hookAndTurnEnabled = hookAndTurnEnabled,
        lineBreakerEnabled = lineBreakerEnabled,
        masterVanguardEnabled = masterVanguardEnabled,
    })
end

local function markSpearStateDirty(scanWindow)
    spearStateDirty = true
    spearEquipmentScanRemaining = math.max(spearEquipmentScanRemaining, tonumber(scanWindow) or SPEAR_EQUIPMENT_SCAN_WINDOW)
    spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" then
        return
    end

    if data.perkID == POINT_CONTROL_PERK_ID or data.perkID == DRIVING_STEP_PERK_ID or data.perkID == HOOK_AND_TURN_PERK_ID or data.perkID == LINE_BREAKER_PERK_ID or data.perkID == MASTER_VANGUARD_PERK_ID then
        markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW)
    end
end

local function shouldUpdateSpear(dt)
    if spearStateDirty then
        return true
    end

    if appliedPointControlEnduranceBonus ~= 0
        and (not hasEnabledPerk(POINT_CONTROL_PERK_ID) or getEquippedSpearRecord() == nil) then
        return true
    end

    if masterVanguardRemaining > 0 or appliedMasterVanguardEnduranceBonus ~= 0 or appliedMasterVanguardAgilityBonus ~= 0 then
        return true
    end

    spearEquipmentScanRemaining = math.max(0, spearEquipmentScanRemaining - (tonumber(dt) or 0))
    if spearEquipmentScanRemaining <= 0 then
        return false
    end

    spearRefreshTimer = spearRefreshTimer + (tonumber(dt) or 0)
    return spearRefreshTimer >= SPEAR_STATE_REFRESH_INTERVAL
end

local function handleSpearAnimation()
    markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW)
end
registerBasepackAnimationHandler(handleSpearAnimation)

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(updateHookAndTurn)
    addOnHitHandler(updateMasterVanguard)
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function(dt)
            spearRuntimeTime = spearRuntimeTime + (tonumber(dt) or 0)
            refreshMasterVanguardBonuses(dt)

            spearStateDirty = false
            spearRefreshTimer = 0
            refreshPointControlEnduranceBonus()
            refreshMasterVanguardBonuses()
            publishSpearPointControlState(false)
        end,
        shouldUpdate = shouldUpdateSpear,
        onLoad = function()
            appliedPointControlEnduranceBonus = 0
            spearStateDirty = true
            spearEquipmentScanRemaining = SPEAR_EQUIPMENT_SCAN_WINDOW
            spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
            lastSpearStateKey = nil
            hookAndTurnPrimedUntil = 0
            appliedMasterVanguardEnduranceBonus = math.max(0, math.floor(tonumber(storageSection:get(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY)) or 0))
            appliedMasterVanguardAgilityBonus = math.max(0, math.floor(tonumber(storageSection:get(MASTER_VANGUARD_AGILITY_APPLIED_KEY)) or 0))
            clearMasterVanguardBonuses()
            spearRuntimeTime = 0
            lastMasterVanguardTarget = nil
            lastMasterVanguardApplyTime = -1
            refreshPointControlEnduranceBonus()
            publishSpearPointControlState(true)
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_TryMasterVanguard = tryApplyMasterVanguard,
        SkillPerkSystem_SpearStateDirty = function() markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW) end,
        UiModeChanged = function() markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW) end,
    },
}

end

----------------------------------------------------------------------
-- blunt weapon runtime logic (from bluntweapon_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local STRENGTH_IN_ARMS_PERK_ID = "bluntweapon_strength_in_arms"
local PLATEBREAKER_PERK_ID = "bluntweapon_platebreaker"
local BREATHSTEALER_PERK_ID = "bluntweapon_breathstealer"
local HEAVY_HITTER_PERK_ID = "bluntweapon_heavy_hitter"
local GUARDED_STAMINA_PERK_ID = "bluntweapon_placeholder_guarded_stance"
local STAGGERING_BLOW_PERK_ID = "bluntweapon_placeholder_staggering_blow"
local IRON_BELL_PERK_ID = "bluntweapon_iron_bell"
local STATE_EVENT = "SkillPerkSystem_BluntWeaponStrengthInArmsState"
local GUARDED_STAMINA_REFUND_MULTIPLIER = 0.25
local GUARDED_STAMINA_ATTACK_WINDOW = 5.0
local STAGGERING_BLOW_CHOP_ATTACK_SPEED_MULTIPLIER = 0.70

local bluntStateDirty = true
local lastStateKey = nil
local lastAnimationLogKey = nil
local guardedStaminaAttackState = nil

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function getStrengthDamageBonus()
    local attributes = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.attributes or nil
    local strengthAccessor = attributes ~= nil and attributes.strength or nil
    if type(strengthAccessor) ~= "function" then
        return 0
    end

    local stat = strengthAccessor(pself)
    local strength = stat ~= nil and tonumber(stat.modified) or nil
    if strength == nil then
        strength = stat ~= nil and tonumber(stat.base) or 0
    end

    return math.max(0, math.floor(strength / 10))
end

local function getEquippedItem(actor, slot)
    local Actor = types.Actor
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    local Weapon = types.Weapon
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function weaponTypeEquals(record, typeName)
    local Weapon = types.Weapon
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE[typeName])
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isBluntWeaponRecord(record)
    return weaponTypeEquals(record, "BluntOneHand")
        or weaponTypeEquals(record, "BluntTwoClose")
        or weaponTypeEquals(record, "BluntTwoWide")
end

local function getEquippedBluntWeaponRecord()
    local Actor = types.Actor
    local Weapon = types.Weapon
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isBluntWeaponRecord(record) then
        return nil
    end

    return record
end

local function getCurrentFatigue()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return nil
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return nil
    end

    return tonumber(fatigue.current), fatigue
end

local function getMaxFatigue(fatigue)
    if fatigue == nil then
        return nil
    end

    local base = tonumber(fatigue.base) or 0
    local modifier = tonumber(fatigue.modifier) or 0
    return math.max(0, base + modifier)
end

local function isAttackReleaseTextKey(key)
    if type(key) ~= "string" then
        return false
    end

    local normalized = string.lower(key)
    return normalized == "chop max attack"
        or normalized == "slash max attack"
        or normalized == "thrust max attack"
        or normalized:find(" max attack$") ~= nil
        or (normalized:find("hit$") ~= nil and normalized:find("min hit$") == nil)
end

local function armGuardedStaminaRefund(event)
    local current = getCurrentFatigue()
    if current == nil then
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState = {
        elapsed = 0,
        lastFatigue = current,
        releaseSeen = isAttackReleaseTextKey(event.stopKey),
    }
end

local function clearInvalidGuardedStaminaState(bluntWeapon)
    if guardedStaminaAttackState == nil then
        return
    end
    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or bluntWeapon == nil then
        guardedStaminaAttackState = nil
    end
end

local function handleBluntAnimation(event)
    local needsBluntWeapon = event.isBluntAttackShape or event.isChopAttackWindup
    local bluntWeapon = nil

    if guardedStaminaAttackState ~= nil or needsBluntWeapon then
        bluntWeapon = getEquippedBluntWeaponRecord()
    end

    clearInvalidGuardedStaminaState(bluntWeapon)

    if event.isBluntAttackShape and hasEnabledPerk(GUARDED_STAMINA_PERK_ID) and bluntWeapon ~= nil then
        armGuardedStaminaRefund(event)
    end

    if event.isChopAttackWindup and hasEnabledPerk(STAGGERING_BLOW_PERK_ID) and bluntWeapon ~= nil then
        multiplyAnimationSpeed(event.options, STAGGERING_BLOW_CHOP_ATTACK_SPEED_MULTIPLIER)
    end
end
registerBasepackAnimationHandler(handleBluntAnimation)

dispatchBasepackAnimationTextKey = function(_, key)
    if guardedStaminaAttackState == nil then
        return
    end
    if not isAttackReleaseTextKey(key) then
        return
    end
    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or getEquippedBluntWeaponRecord() == nil then
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState.releaseSeen = true
end

local function processGuardedStaminaRefund(dt)
    if guardedStaminaAttackState == nil then
        return
    end

    guardedStaminaAttackState.elapsed = (tonumber(guardedStaminaAttackState.elapsed) or 0) + (tonumber(dt) or 0)

    local current, fatigue = getCurrentFatigue()
    if current == nil then
        guardedStaminaAttackState = nil
        return
    end

    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or getEquippedBluntWeaponRecord() == nil then
        guardedStaminaAttackState = nil
        return
    end

    local before = tonumber(guardedStaminaAttackState.lastFatigue) or current
    local spent = before - current
    if spent > 0 then
        local refund = spent * GUARDED_STAMINA_REFUND_MULTIPLIER
        local maxFatigue = getMaxFatigue(fatigue) or before
        fatigue.current = math.min(maxFatigue, before, current + refund)
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState.lastFatigue = math.max(before, current)

    if guardedStaminaAttackState.elapsed >= GUARDED_STAMINA_ATTACK_WINDOW then
        guardedStaminaAttackState = nil
    end
end

local BLUNT_STATE_PERKS = {
    bluntweapon_strength_in_arms = true,
    bluntweapon_platebreaker = true,
    bluntweapon_breathstealer = true,
    bluntweapon_heavy_hitter = true,
    bluntweapon_placeholder_guarded_stance = true,
    bluntweapon_placeholder_staggering_blow = true,
    bluntweapon_iron_bell = true,
}

local function markBluntStateDirty()
    bluntStateDirty = true
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or BLUNT_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markBluntStateDirty()
end

local function shouldUpdateBlunt()
    return bluntStateDirty or guardedStaminaAttackState ~= nil
end

local function publishState(force)
    local strengthInArmsEnabled = hasEnabledPerk(STRENGTH_IN_ARMS_PERK_ID)
    local damageBonus = strengthInArmsEnabled and getStrengthDamageBonus() or 0
    local platebreakerEnabled = hasEnabledPerk(PLATEBREAKER_PERK_ID)
    local breathstealerEnabled = hasEnabledPerk(BREATHSTEALER_PERK_ID)
    local heavyHitterEnabled = hasEnabledPerk(HEAVY_HITTER_PERK_ID)
    local guardedStaminaEnabled = hasEnabledPerk(GUARDED_STAMINA_PERK_ID)
    local staggeringBlowEnabled = hasEnabledPerk(STAGGERING_BLOW_PERK_ID)
    local ironBellEnabled = hasEnabledPerk(IRON_BELL_PERK_ID)
    local stateKey = tostring(strengthInArmsEnabled)
        .. ":"
        .. tostring(damageBonus)
        .. ":"
        .. tostring(platebreakerEnabled)
        .. ":"
        .. tostring(breathstealerEnabled)
        .. ":"
        .. tostring(heavyHitterEnabled)
        .. ":"
        .. tostring(guardedStaminaEnabled)
        .. ":"
        .. tostring(staggeringBlowEnabled)
        .. ":"
        .. tostring(ironBellEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        playerId = pself.id,
        strengthInArmsEnabled = strengthInArmsEnabled,
        enabled = strengthInArmsEnabled,
        damageBonus = damageBonus,
        platebreakerEnabled = platebreakerEnabled,
        breathstealerEnabled = breathstealerEnabled,
        heavyHitterEnabled = heavyHitterEnabled,
        guardedStaminaEnabled = guardedStaminaEnabled,
        staggeringBlowEnabled = staggeringBlowEnabled,
        ironBellEnabled = ironBellEnabled,
    })
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = function(dt)
            if guardedStaminaAttackState ~= nil then
                processGuardedStaminaRefund(dt)
            end
            if bluntStateDirty then
                bluntStateDirty = false
                publishState(false)
            end
        end,
        shouldUpdate = shouldUpdateBlunt,
        onLoad = function()
            lastStateKey = nil
            bluntStateDirty = true
            publishState(true)
            bluntStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_BluntWeaponStateDirty = function() markBluntStateDirty() end,
        UiModeChanged = function() markBluntStateDirty() end,
    },
}

end

----------------------------------------------------------------------
-- block reactive local logic (from block_reactive_local.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon
local Lockpick = types.Lockpick
local Probe = types.Probe
local Repair = types.Repair

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local REACTIVE_ENCHANTING_PERK_ID = "block_reactive_enchanting"

local function perkEnabled(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local owned = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId) or false
    local enabled = owned
    if owned and type(playerApi.isPerkEffectEnabled) == "function" then
        enabled = playerApi.isPerkEffectEnabled(perkId)
    end

    return owned and enabled
end

local function getEquippedItem(actor, slot)
    if actor == nil or Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local ok, equipped = pcall(Actor.getEquipment, actor, slot)
    if not ok then
        return nil
    end

    return equipped
end

local function getEquippedShield(actor)
    if actor == nil or Actor == nil then
        return nil, nil
    end

    local carriedLeftSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedLeft or nil
    if carriedLeftSlot == nil then
        return nil, nil
    end

    local equipped = getEquippedItem(actor, carriedLeftSlot)
    if equipped == nil then
        return nil, nil
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return nil, nil
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, equipped)
        if okRecord then
            record = value
        end
    end

    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil, nil
    end

    return equipped, record
end

local function getEquippedRightHand(actor)
    if actor == nil or Actor == nil then
        return nil
    end

    local rightSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedRight or nil
    if rightSlot == nil then
        return nil
    end

    return getEquippedItem(actor, rightSlot)
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local ok, record = pcall(Weapon.record, item)
        if ok and record ~= nil then
            return record
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    return nil
end

local function isOneHandedWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil then
        return true
    end

    local weaponType = tonumber(record.type)
    if weaponType == nil then
        return true
    end

    if weaponType == 2 then return false end
    if weaponType == 4 then return false end
    if weaponType == 5 then return false end
    if weaponType == 6 then return false end
    if weaponType == 8 then return false end
    if weaponType == 9 then return false end
    if weaponType == 10 then return false end
    if weaponType == 11 then return false end
    if weaponType == 12 then return false end
    if weaponType == 13 then return false end

    return true
end

local function isTool(item)
    if item == nil then
        return false
    end

    if Lockpick ~= nil and type(Lockpick.objectIsInstance) == "function" and Lockpick.objectIsInstance(item) then
        return true
    end
    if Probe ~= nil and type(Probe.objectIsInstance) == "function" and Probe.objectIsInstance(item) then
        return true
    end
    if Repair ~= nil and type(Repair.objectIsInstance) == "function" and Repair.objectIsInstance(item) then
        return true
    end

    return false
end

local function hasValidReactiveShieldSetup(actor)
    local shield = getEquippedShield(actor)
    if shield == nil then
        return false
    end

    local rightHand = getEquippedRightHand(actor)
    if rightHand == nil then
        return false
    end

    return isOneHandedWeapon(rightHand) or isTool(rightHand)
end

local function wasSuccessfulShieldBlock(attack)
    if type(attack) ~= "table" then
        return false
    end

    local blockedFlag = attack.blocked == true or attack.isBlocked == true or attack.block == true
    local blockedBy = string.lower(tostring(attack.blockedBy or attack.blockType or attack.defenseType or ""))
    local isParry = attack.parried == true or attack.isParry == true or blockedBy:find("parry", 1, true) ~= nil

    if isParry then
        return false
    end
    if blockedBy:find("shield", 1, true) ~= nil then
        return true
    end
    if blockedFlag then
        return true
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local totalDamage = (tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)
    if attack.successful == true and totalDamage <= 0 then
        return true
    end

    return false
end

local function buildPayload(attack)
    local attacker = attack.attacker
    if attacker == nil then
        return nil
    end

    local shield, shieldRecord = getEquippedShield(selfObj)
    if shield == nil or shieldRecord == nil then
        return nil
    end

    local enchantmentId = shieldRecord.enchant or shieldRecord.enchantment
    if type(enchantmentId) == "table" and type(enchantmentId.id) == "string" then
        enchantmentId = enchantmentId.id
    end
    if type(enchantmentId) ~= "string" or enchantmentId == "" then
        return nil
    end

    return {
        blocker = selfObj,
        attacker = attacker,
        shield = shield,
        enchantmentId = enchantmentId,
    }
end

local function onHit(attack)
    if not perkEnabled(REACTIVE_ENCHANTING_PERK_ID) then
        return
    end
    if not wasSuccessfulShieldBlock(attack) then
        return
    end
    if not hasValidReactiveShieldSetup(selfObj) then
        return
    end

    local payload = buildPayload(attack)
    if payload == nil then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyReactiveShieldEnchant", payload)
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {},
}

end

----------------------------------------------------------------------
-- apprentice hammer runtime logic (from apprentice_hammer_runtime.lua)
----------------------------------------------------------------------
do
local async = require("openmw.async")
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")

local MENU_NAME = "SkillPerkSystem_BasePack_ApprenticeHammerMenu"
local OVERREPAIR_MENU_NAME = "SkillPerkSystem_BasePack_OverRepairMenu"
local TEMPER_MENU_NAME = "SkillPerkSystem_BasePack_WeaponTemperMenu"
local ARMOR_REFIT_MENU_NAME = "SkillPerkSystem_BasePack_ArmorRefitMenu"
local MASTERWORK_MENU_NAME = "SkillPerkSystem_BasePack_MasterworkMenu"
local OVERREPAIR_USES_COST = 5
local DEFAULT_MULTIPLIER = 1.10
local TEMPER_STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_WeaponTemper"
local TEMPERED_WEAPONS_KEY = "temperedWeapons"
local REFITTED_ARMOR_KEY = "refittedArmor"
local TEMPER_REQUEST_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Request"
local TEMPER_RESULT_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Result"
local ARMOR_REFIT_REQUEST_EVENT = "SkillPerkSystem_BasePack_ArmorRefit_Request"
local ARMOR_REFIT_RESULT_EVENT = "SkillPerkSystem_BasePack_ArmorRefit_Result"
local MASTERWORK_REQUEST_EVENT = "SkillPerkSystem_BasePack_Masterwork_Request"
local MASTERWORK_RESULT_EVENT = "SkillPerkSystem_BasePack_Masterwork_Result"
local FIELD_MENDER_PERK_ID = "armorer_field_mender"
local APPRENTICE_PERK_ID = "armorer_apprentice_hammer"
local REFORGED_PLATING_PERK_ID = "armorer_masterwork_rivets"
local MASTERWORK_PERK_ID = "armorer_masterwork"
local LOG_TAG = "[SkillPerkSystem_BasePack][ApprenticeHammer][RepairMode]"
local OVERREPAIR_REQUEST_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest"
local OVERREPAIR_RESULT_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairResult"
local CAREFUL_REPAIRS_SUPPRESS_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_SuppressRepairToolDrops"

local rootMenuElement = nil
local subMenuElement = nil
local customMenuOpen = false
local suppressNextRepairIntercept = false
local pendingUseRepairTool = nil
local pendingUseRepairFrames = 0
local lastRepairTool = nil
local lastRepairToolRecordId = nil
local lastOverrepairedTargetRecordId = nil
local lastOverrepairedTargetName = nil

local temperStorage = storage.playerSection(TEMPER_STORAGE_SECTION_ID)
local temperedWeaponCache = {}
local refittedArmorCache = {}
local masterworkedGearCache = nil

local function logDebug(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function isPerkOwnedAndEnabled(perkId)
    local playerApi = interfaces.SkillPerkSystemPlayer
    if playerApi == nil then
        logDebug("interfaces.SkillPerkSystemPlayer unavailable")
        return false
    end
    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(perkId) then
        return false
    end
    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(perkId) then
        return false
    end
    return true
end

local function apprenticeHammerEnabled()
    return isPerkOwnedAndEnabled(APPRENTICE_PERK_ID)
end

local function weaponTemperEnabled()
    return isPerkOwnedAndEnabled(FIELD_MENDER_PERK_ID)
end

local function armorRefitEnabled()
    return isPerkOwnedAndEnabled(REFORGED_PLATING_PERK_ID)
end

local function masterworkEnabled()
    return isPerkOwnedAndEnabled(MASTERWORK_PERK_ID)
end

local function anyRepairToolActionEnabled()
    return apprenticeHammerEnabled() or weaponTemperEnabled() or armorRefitEnabled() or masterworkEnabled()
end

local function showMessage(text)
    ui.showMessage(text, { showInDialogue = false })
end

local function closeRootMenu()
    if rootMenuElement ~= nil then
        rootMenuElement:destroy()
        rootMenuElement = nil
    end
end

local function closeSubMenu()
    if subMenuElement ~= nil then
        subMenuElement:destroy()
        subMenuElement = nil
    end
end

local function closeAllMenus()
    closeSubMenu()
    closeRootMenu()
    customMenuOpen = false
end

local function sequenceToArray(seq)
    if seq == nil then
        return {}
    end

    local out = {}
    local okLen, len = pcall(function()
        return #seq
    end)

    if okLen and type(len) == "number" then
        for i = 1, len do
            out[#out + 1] = seq[i]
        end
        return out
    end

    local okPairs, err = pcall(function()
        for _, item in pairs(seq) do
            out[#out + 1] = item
        end
    end)

    if not okPairs then
        logDebug("sequenceToArray failed: " .. tostring(err))
    end

    return out
end

local function getActorObject()
    return pself.object or pself
end

local function getPlayerInventory()
    local okInv, inventory = pcall(types.Actor.inventory, getActorObject())
    if not okInv or inventory == nil then
        logDebug("types.Actor.inventory failed")
        return nil
    end
    return inventory
end

local function safeGetRecordField(record, fieldName)
    if record == nil then return nil end

    local okField, value = pcall(function()
        return record[fieldName]
    end)
    if okField then
        return value
    end
    return nil
end

local function getEquipmentRecord(item)
    if item == nil then return nil end

    if types.Weapon.objectIsInstance(item) then
        local okRecord, record = pcall(types.Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Weapon.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    elseif types.Armor.objectIsInstance(item) then
        local okRecord, record = pcall(types.Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Armor.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    end

    return nil
end

local function getMaxCondition(item)
    local record = getEquipmentRecord(item)
    return tonumber(safeGetRecordField(record, "health") or safeGetRecordField(record, "maxCondition"))
end

local function getItemCondition(item)
    if item == nil then return nil end
    local itemData = types.Item.itemData(item)
    if itemData ~= nil and type(itemData.condition) == "number" then
        return itemData.condition, itemData
    end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) == "number" then
        return maxCondition, itemData
    end

    return nil, itemData
end

local function setSharedActiveRepairTool(item, source)
    if item == nil or not types.Repair.objectIsInstance(item) then
        return
    end

    local condition = getItemCondition(item)
    __basepack_repair_tool_state.item = item
    __basepack_repair_tool_state.recordId = item.recordId
    __basepack_repair_tool_state.lastCondition = condition
    __basepack_repair_tool_state.source = source
end

local function getDisplayName(item)
    if item == nil then return "Unknown Item" end

    local record = getEquipmentRecord(item)
    local recordName = safeGetRecordField(record, "name")
    if type(recordName) == "string" and recordName ~= "" then
        return recordName
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then return "Unknown Item" end
    return recordId
end

local function getAllInventoryItems()
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll()
    end)
    if not okAll or items == nil then
        logDebug("inventory:getAll() failed")
        return {}
    end
    return sequenceToArray(items)
end

local function getAllInventoryItemsOfType(typeObject)
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll(typeObject)
    end)
    if okAll and items ~= nil then
        return sequenceToArray(items)
    end

    local fallback = {}
    for _, item in ipairs(getAllInventoryItems()) do
        if item ~= nil and typeObject.objectIsInstance(item) then
            fallback[#fallback + 1] = item
        end
    end
    return fallback
end

local function isRepairableEquipmentItem(item)
    return item ~= nil and (types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item))
end

local function getItemKey(item)
    if item == nil then return nil end

    local okId, objectId = pcall(function()
        return item.id
    end)
    if okId and objectId ~= nil then
        return objectId
    end

    return item
end

local function getObjectCount(item)
    if item == nil then return 1 end

    local okCount, count = pcall(function()
        return item.count
    end)
    if okCount and type(count) == "number" and count > 0 then
        return count
    end

    return 1
end

local function addUniqueItem(out, seen, item)
    local key = getItemKey(item)
    if item == nil or key == nil or seen[key] then
        return false
    end
    seen[key] = true
    out[#out + 1] = item
    return true
end

local function getEquippedRepairableEquipmentItems(seen)
    local out = {}
    local weaponCount = 0
    local armorCount = 0

    if type(types.Actor.getEquipment) ~= "function" then
        return out, weaponCount, armorCount
    end

    for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
        local okItem, item = pcall(types.Actor.getEquipment, getActorObject(), slot)
        if okItem and item ~= nil then
            local isWeapon = types.Weapon.objectIsInstance(item)
            local isArmor = types.Armor.objectIsInstance(item)
            if isWeapon or isArmor then
                if isWeapon then weaponCount = weaponCount + 1 end
                if isArmor then armorCount = armorCount + 1 end
                addUniqueItem(out, seen, item)
            end
        end
    end

    return out, weaponCount, armorCount
end

local function getRepairableEquipmentItems()
    local out = {}
    local seen = {}
    local weaponItems = getAllInventoryItemsOfType(types.Weapon)
    local armorItems = getAllInventoryItemsOfType(types.Armor)

    logDebug("inventory typed weapons=" .. tostring(#weaponItems))
    for _, item in ipairs(weaponItems) do
        addUniqueItem(out, seen, item)
    end

    logDebug("inventory typed armor=" .. tostring(#armorItems))
    for _, item in ipairs(armorItems) do
        addUniqueItem(out, seen, item)
    end

    local equippedItems, equippedWeapons, equippedArmor = getEquippedRepairableEquipmentItems(seen)
    logDebug("equipment weapons=" .. tostring(equippedWeapons) .. " armor=" .. tostring(equippedArmor) .. " uniqueAdded=" .. tostring(#equippedItems))
    for _, item in ipairs(equippedItems) do
        out[#out + 1] = item
    end

    return out, #weaponItems, #armorItems, equippedWeapons, equippedArmor
end

local function getStoredRecords(key)
    local records = nil
    if type(temperStorage.getCopy) == "function" then
        records = temperStorage:getCopy(key)
    else
        records = temperStorage:get(key)
    end
    if type(records) ~= "table" then
        records = {}
    end
    if type(records.byGeneratedName) ~= "table" then
        records.byGeneratedName = {}
    end
    return records
end

local function getTemperedWeaponRecords()
    return getStoredRecords(TEMPERED_WEAPONS_KEY)
end

local function setTemperedWeaponRecords(records)
    temperStorage:set(TEMPERED_WEAPONS_KEY, records)
end

local function getRefittedArmorRecords()
    return getStoredRecords(REFITTED_ARMOR_KEY)
end

local function setRefittedArmorRecords(records)
    temperStorage:set(REFITTED_ARMOR_KEY, records)
end

local function getMasterworkedGearRecord()
    return masterworkedGearCache
end

local function setMasterworkedGearRecord(record)
    masterworkedGearCache = type(record) == "table" and record or nil
end

local function inferMasterworkModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Masterwork " then
        return "masterwork"
    end
    return nil
end

local function formatMasterworkMode()
    return "Masterwork"
end

local function inferArmorRefitModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Reinforced " then
        return "reinforced"
    elseif string.sub(name, 1, 8) == "Trimmed " then
        return "trimmed"
    end
    return nil
end

local function inferTemperModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 6) == "Honed " then
        return "honed"
    elseif string.sub(name, 1, 9) == "Hardened " then
        return "hardened"
    end
    return nil
end

local function getTemperedWeaponInfo(recordId, displayName)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local cached = temperedWeaponCache[recordId]
    if type(cached) == "table" then
        return cached
    end

    local records = getTemperedWeaponRecords()
    local entry = records[recordId]
    if type(entry) == "table" then
        temperedWeaponCache[recordId] = entry
        return entry
    end

    local byName = records.byGeneratedName
    if type(byName) == "table" and type(displayName) == "string" then
        entry = byName[displayName]
        if type(entry) == "table" then
            temperedWeaponCache[recordId] = entry
            return entry
        end
    end

    local inferredMode = inferTemperModeFromName(displayName)
    if inferredMode ~= nil then
        return { mode = inferredMode, inferred = true }
    end

    return nil
end

local function getRefittedArmorInfo(recordId, displayName)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local cached = refittedArmorCache[recordId]
    if type(cached) == "table" then
        return cached
    end

    local records = getRefittedArmorRecords()
    local entry = records[recordId]
    if type(entry) == "table" then
        refittedArmorCache[recordId] = entry
        return entry
    end

    local byName = records.byGeneratedName
    if type(byName) == "table" and type(displayName) == "string" then
        entry = byName[displayName]
        if type(entry) == "table" then
            refittedArmorCache[recordId] = entry
            return entry
        end
    end

    local inferredMode = inferArmorRefitModeFromName(displayName)
    if inferredMode ~= nil then
        return { mode = inferredMode, inferred = true }
    end

    return nil
end

local function formatTemperMode(mode)
    if mode == "honed" then
        return "Honed"
    elseif mode == "hardened" then
        return "Hardened"
    end
    return "Tempered"
end

local function formatArmorRefitMode(mode)
    if mode == "reinforced" then
        return "Reinforced"
    elseif mode == "trimmed" then
        return "Trimmed"
    end
    return "Refitted"
end

local function collectWeaponTemperCandidates()
    local out = {}
    local seen = {}
    for _, item in ipairs(getAllInventoryItemsOfType(types.Weapon)) do
        if item ~= nil and addUniqueItem(out, seen, item) then
            -- Added by addUniqueItem.
        end
    end

    table.sort(out, function(a, b)
        return string.lower(getDisplayName(a)) < string.lower(getDisplayName(b))
    end)
    return out
end

local function getMasterworkedGearInfo(recordId, displayName)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end
    local record = masterworkedGearCache or getMasterworkedGearRecord()
    if type(record) == "table" then
        if record.generatedRecordId == recordId or record.originalRecordId == recordId then
            return record
        end
        if type(displayName) == "string" and (record.generatedName == displayName or record.originalName == displayName) then
            return record
        end
    end
    if inferMasterworkModeFromName(displayName) ~= nil then
        return { mode = "masterwork", inferred = true, generatedRecordId = recordId, generatedName = displayName }
    end
    return nil
end

local function collectMasterworkCandidates()
    local active = getMasterworkedGearRecord()
    local out = {}
    local seen = {}
    for _, item in ipairs(getAllInventoryItemsOfType(types.Weapon)) do
        if item ~= nil and (active == nil or item.recordId == active.generatedRecordId) then
            addUniqueItem(out, seen, item)
        end
    end
    for _, item in ipairs(getAllInventoryItemsOfType(types.Armor)) do
        if item ~= nil and (active == nil or item.recordId == active.generatedRecordId) then
            addUniqueItem(out, seen, item)
        end
    end
    table.sort(out, function(a, b)
        return string.lower(getDisplayName(a)) < string.lower(getDisplayName(b))
    end)
    return out, active
end

local function collectArmorRefitCandidates()
    local out = {}
    local seen = {}
    for _, item in ipairs(getAllInventoryItemsOfType(types.Armor)) do
        if item ~= nil and addUniqueItem(out, seen, item) then
            -- Added by addUniqueItem.
        end
    end

    table.sort(out, function(a, b)
        return string.lower(getDisplayName(a)) < string.lower(getDisplayName(b))
    end)
    return out
end

local function isAtNormalMaxCondition(currentCondition, maxCondition)
    if type(currentCondition) ~= "number" or type(maxCondition) ~= "number" then
        return false
    end

    local currentRounded = math.floor(currentCondition + 0.5)
    local maxRounded = math.floor(maxCondition + 0.5)
    return currentRounded == maxRounded
end

local function getOverrepairEligibility(item)
    if not isRepairableEquipmentItem(item) then
        return false, "not_weapon_or_armor"
    end

    local currentCondition, itemData = getItemCondition(item)
    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        return false, "missing_max_condition", currentCondition, maxCondition, itemData
    end
    if type(currentCondition) ~= "number" then
        return false, "missing_current_condition", currentCondition, maxCondition, itemData
    end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then
        if currentCondition > maxCondition then
            return false, "already_overrepaired", currentCondition, maxCondition, itemData
        end
        return false, "not_at_normal_max", currentCondition, maxCondition, itemData
    end

    return true, "eligible", currentCondition, maxCondition, itemData
end

local function findRepairToolByRecordId(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local inventory = getPlayerInventory()
    if inventory ~= nil and type(inventory.find) == "function" then
        local okFind, item = pcall(function()
            return inventory:find(recordId)
        end)
        if okFind and item ~= nil then
            return item
        end
    end

    for _, item in ipairs(getAllInventoryItemsOfType(types.Repair)) do
        if item ~= nil and item.recordId == recordId then
            return item
        end
    end
    return nil
end

local function findRepairableItemByRecordId(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local inventory = getPlayerInventory()
    if inventory ~= nil and type(inventory.find) == "function" then
        local okFind, item = pcall(function()
            return inventory:find(recordId)
        end)
        if okFind and isRepairableEquipmentItem(item) then
            return item
        end
    end

    if type(types.Actor.getEquipment) == "function" then
        for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
            local okItem, item = pcall(types.Actor.getEquipment, getActorObject(), slot)
            if okItem and item ~= nil and item.recordId == recordId and isRepairableEquipmentItem(item) then
                return item
            end
        end
    end

    return nil
end

local function getCachedOverrepairedItemStatus()
    local item = findRepairableItemByRecordId(lastOverrepairedTargetRecordId)
    if item == nil then
        return false
    end

    local currentCondition = getItemCondition(item)
    local maxCondition = getMaxCondition(item)
    if type(currentCondition) == "number" and type(maxCondition) == "number" and currentCondition > maxCondition then
        return true, item, currentCondition, maxCondition
    end

    return false, item, currentCondition, maxCondition
end

local function getActiveRepairTool()
    if lastRepairTool ~= nil then
        return lastRepairTool
    end

    if lastRepairToolRecordId ~= nil then
        local cachedItem = findRepairToolByRecordId(lastRepairToolRecordId)
        if cachedItem ~= nil then
            return cachedItem
        end
    end

    local repairTools = getAllInventoryItemsOfType(types.Repair)
    if #repairTools > 0 then
        return repairTools[1]
    end

    if type(types.Actor.getEquipment) == "function" then
        for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
            local okItem, item = pcall(types.Actor.getEquipment, getActorObject(), slot)
            if okItem and item ~= nil and types.Repair.objectIsInstance(item) then
                return item
            end
        end
    end
    return nil
end

local function hasRepairToolUses(item, usesRequired)
    local currentCondition, itemData = getItemCondition(item)
    return type(currentCondition) == "number" and currentCondition >= usesRequired and itemData ~= nil
end

local function setInterfaceMode()
    local uiApi = interfaces.UI
    if uiApi == nil or type(uiApi.setMode) ~= "function" then
        logDebug("interfaces.UI.setMode unavailable for Interface")
        return
    end
    uiApi.setMode("Interface", { windows = { "Map", "Stats", "Magic", "Inventory" } })
end

local function createButton(label, onSelect, width)
    local textLayout = {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.Center,
            relativeSize = util.vector2(1, 1),
        },
    }

    local innerButton = {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxButton,
        props = { size = util.vector2(width or 560, 28) },
        content = ui.content({ textLayout }),
    }

    return {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = { autoSize = true },
        content = ui.content({ innerButton }),
        events = {
            mousePress = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    textLayout.template = interfaces.MWUI.templates.textHeader
                    if rootMenuElement ~= nil then rootMenuElement:update() end
                    if subMenuElement ~= nil then subMenuElement:update() end
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then onSelect() end
            end),
            focusGain = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textHeader
                if rootMenuElement ~= nil then rootMenuElement:update() end
                if subMenuElement ~= nil then subMenuElement:update() end
            end),
            focusLoss = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textNormal
                if rootMenuElement ~= nil then rootMenuElement:update() end
                if subMenuElement ~= nil then subMenuElement:update() end
            end),
        },
    }
end

local function requestBaseRepairUi(repairToolItem)
    repairToolItem = repairToolItem or getActiveRepairTool()
    if repairToolItem == nil then
        showMessage("No repair tool found.")
        return
    end

    lastRepairTool = repairToolItem
    lastRepairToolRecordId = repairToolItem.recordId
    setSharedActiveRepairTool(repairToolItem, "requestBaseRepairUi")
    logDebug("requestBaseRepairUi using " .. tostring(lastRepairToolRecordId))
    suppressNextRepairIntercept = true
    pendingUseRepairTool = repairToolItem
    pendingUseRepairFrames = 1
    closeAllMenus()
end

local function collectOverrepairCandidates()
    local out = {}
    local inventory = getPlayerInventory()
    if inventory ~= nil then
        local okResolved, resolved = pcall(function() return inventory:isResolved() end)
        if okResolved then
            logDebug("inventory resolved=" .. tostring(resolved))
        end
    end

    local allItems = getRepairableEquipmentItems()
    local weaponSeen = 0
    local armorSeen = 0

    for _, item in ipairs(allItems) do
        local isWeapon = item ~= nil and types.Weapon.objectIsInstance(item)
        local isArmor = item ~= nil and types.Armor.objectIsInstance(item)

        if isWeapon then weaponSeen = weaponSeen + 1 end
        if isArmor then armorSeen = armorSeen + 1 end

        local eligible, reason, currentCondition, maxCondition, itemData = getOverrepairEligibility(item)
        if eligible then
            out[#out + 1] = {
                item = item,
                recordId = item.recordId,
                name = getDisplayName(item),
                currentCondition = currentCondition,
                maxCondition = maxCondition,
                count = getObjectCount(item),
            }
        else
            logDebug(string.format(
                "overrepair reject id=%s current=%s max=%s itemData=%s reason=%s",
                tostring(item and item.recordId),
                tostring(currentCondition),
                tostring(maxCondition),
                tostring(itemData ~= nil),
                tostring(reason)
            ))
        end
    end

    table.sort(out, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
    logDebug("collectOverrepairCandidates scanned weapons=" .. tostring(weaponSeen) .. " armor=" .. tostring(armorSeen) .. " eligible=" .. tostring(#out))
    return out
end

local function computeOverrepairTargetCondition(item, multiplier)
    local currentCondition = getItemCondition(item)
    if type(currentCondition) ~= "number" then return nil end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then return nil end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then return nil end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then return nil end

    return targetCondition
end

local function findEligibleItemByRecordId(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    for _, item in ipairs(getRepairableEquipmentItems()) do
        if item ~= nil and item.recordId == recordId then
            local eligible = getOverrepairEligibility(item)
            if eligible then
                return item
            end
        end
    end

    return nil
end

local function openOverRepairMenu(repairToolItem)
    closeSubMenu()

    local alreadyOverrepaired, overrepairedItem = getCachedOverrepairedItemStatus()
    if alreadyOverrepaired then
        local name = lastOverrepairedTargetName or getDisplayName(overrepairedItem)
        logDebug("overrepair skipped full scan; cached target is already over max for " .. tostring(lastOverrepairedTargetRecordId))
        showMessage(string.format("%s is already over-repaired.", tostring(name or "That item")))
        return
    end

    local candidates = collectOverrepairCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Over Repair", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Select a fully repaired weapon or armor piece.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "No eligible items at full durability.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, entry in ipairs(candidates) do
            local countLabel = ""
            if type(entry.count) == "number" and entry.count > 1 then
                countLabel = " x" .. tostring(entry.count)
            end
            local label = string.format(
                "%s%s (%d/%d)",
                entry.name,
                countLabel,
                math.floor(entry.currentCondition + 0.5),
                math.floor(entry.maxCondition + 0.5)
            )
            table.insert(contentLayouts, createButton(label, function()
                closeAllMenus()
                local currentRepairTool = getActiveRepairTool()
                if currentRepairTool == nil then
                    logDebug("overrepair failed: no repair tool")
                    showMessage("No repair tool found.")
                    return
                end

                local targetItem = nil
                local entryItemEligible, entryItemReason = getOverrepairEligibility(entry.item)
                if entryItemEligible then
                    targetItem = entry.item
                else
                    if entryItemReason == "already_overrepaired" then
                        logDebug("overrepair failed: target already over-repaired for " .. tostring(entry.recordId))
                        showMessage(string.format("%s is already over-repaired.", tostring(entry.name or "That item")))
                        return
                    end
                    targetItem = findEligibleItemByRecordId(entry.recordId)
                end
                if targetItem == nil then
                    logDebug("overrepair failed: target item missing for " .. tostring(entry.recordId))
                    showMessage("That item is no longer eligible.")
                    return
                end

                if not hasRepairToolUses(currentRepairTool, OVERREPAIR_USES_COST) then
                    logDebug("overrepair failed: not enough tool uses")
                    showMessage("Not enough hammer uses remaining (need 5).")
                    return
                end

                local targetCondition = computeOverrepairTargetCondition(targetItem, DEFAULT_MULTIPLIER)
                if targetCondition == nil then
                    logDebug("overrepair failed: target no longer eligible for " .. tostring(entry.recordId))
                    showMessage("That item is no longer eligible.")
                    return
                end

                local playerObject = getActorObject()
                if playerObject ~= nil and type(playerObject.sendEvent) == "function" then
                    playerObject:sendEvent(CAREFUL_REPAIRS_SUPPRESS_EVENT, {
                        amount = OVERREPAIR_USES_COST,
                        source = "apprentice_hammer_overrepair",
                    })
                end
                core.sendGlobalEvent(OVERREPAIR_REQUEST_EVENT, {
                    player = playerObject,
                    repairTool = currentRepairTool,
                    targetItem = targetItem,
                    targetName = entry.name,
                    usesCost = OVERREPAIR_USES_COST,
                    multiplier = DEFAULT_MULTIPLIER,
                    expectedTargetCondition = targetCondition,
                })
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = OVERREPAIR_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function sendTemperRequest(item, mode, temperInfo)
    if item == nil or type(mode) ~= "string" then
        showMessage("That weapon is no longer eligible.")
        return
    end

    closeAllMenus()
    core.sendGlobalEvent(TEMPER_REQUEST_EVENT, {
        player = getActorObject(),
        targetItem = item,
        mode = mode,
        targetName = getDisplayName(item),
        originalRecordId = type(temperInfo) == "table" and temperInfo.originalRecordId or nil,
        originalName = type(temperInfo) == "table" and temperInfo.originalName or nil,
        generatedRecordId = type(temperInfo) == "table" and temperInfo.generatedRecordId or nil,
        generatedName = type(temperInfo) == "table" and temperInfo.generatedName or nil,
    })
end

local openTemperWeaponMenu

local function openTemperModeMenu(entry)
    closeSubMenu()

    local recordId = entry.item ~= nil and entry.item.recordId or entry.recordId
    local temperInfo = getTemperedWeaponInfo(recordId, entry.name)
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = entry.name, textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if temperInfo ~= nil then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "This weapon is " .. formatTemperMode(temperInfo.mode) .. ".", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Restore Original", function()
            sendTemperRequest(entry.item, "restore", temperInfo)
        end, 620))
    else
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose one temper. Unenchanted tempered weapons cannot be enchanted afterward.", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Hone: +damage, -weight, -durability", function()
            sendTemperRequest(entry.item, "honed")
        end, 620))
        table.insert(contentLayouts, createButton("Harden: +durability, +weight, -damage", function()
            sendTemperRequest(entry.item, "hardened")
        end, 620))
    end

    table.insert(contentLayouts, createButton("Back", function()
        openTemperWeaponMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = TEMPER_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

openTemperWeaponMenu = function()
    closeSubMenu()

    local candidates = collectWeaponTemperCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Hone or Harden", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Select a weapon to temper or restore.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "No weapons found in your inventory.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, item in ipairs(candidates) do
            local recordId = item.recordId
            local currentCondition = getItemCondition(item)
            local maxCondition = getMaxCondition(item)
            local modeLabel = ""
            local temperInfo = getTemperedWeaponInfo(recordId, getDisplayName(item))
            if temperInfo ~= nil then
                modeLabel = " [" .. formatTemperMode(temperInfo.mode) .. "]"
            end
            local conditionLabel = ""
            if type(currentCondition) == "number" and type(maxCondition) == "number" then
                conditionLabel = string.format(" (%d/%d)", math.floor(currentCondition + 0.5), math.floor(maxCondition + 0.5))
            end
            local count = getObjectCount(item)
            local countLabel = count > 1 and (" x" .. tostring(count)) or ""
            local entry = {
                item = item,
                recordId = recordId,
                name = getDisplayName(item),
            }
            table.insert(contentLayouts, createButton(entry.name .. countLabel .. modeLabel .. conditionLabel, function()
                openTemperModeMenu(entry)
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = TEMPER_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function sendMasterworkRequest(item, mode, masterworkInfo)
    if item == nil or type(mode) ~= "string" then
        showMessage("That item is no longer eligible.")
        return
    end

    local activeMasterwork = getMasterworkedGearRecord()

    closeAllMenus()
    core.sendGlobalEvent(MASTERWORK_REQUEST_EVENT, {
        player = getActorObject(),
        targetItem = item,
        mode = mode,
        targetName = getDisplayName(item),
        activeMasterwork = activeMasterwork,
        originalRecordId = type(masterworkInfo) == "table" and masterworkInfo.originalRecordId or nil,
        originalName = type(masterworkInfo) == "table" and masterworkInfo.originalName or nil,
        generatedRecordId = type(masterworkInfo) == "table" and masterworkInfo.generatedRecordId or nil,
        generatedName = type(masterworkInfo) == "table" and masterworkInfo.generatedName or nil,
        itemType = type(masterworkInfo) == "table" and masterworkInfo.itemType or nil,
    })
end

local openMasterworkMenu

local function openMasterworkModeMenu(entry)
    closeSubMenu()

    local recordId = entry.item ~= nil and entry.item.recordId or entry.recordId
    local masterworkInfo = getMasterworkedGearInfo(recordId, entry.name)
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = entry.name, textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if masterworkInfo ~= nil then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "This is your active masterwork.", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Restore Original", function()
            sendMasterworkRequest(entry.item, "restore", masterworkInfo)
        end, 620))
    else
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Masterwork this item: +15% damage or armor and +25% durability. Value and weight are unchanged.", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Masterwork", function()
            sendMasterworkRequest(entry.item, "masterwork")
        end, 620))
    end

    table.insert(contentLayouts, createButton("Back", function()
        openMasterworkMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = MASTERWORK_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

openMasterworkMenu = function()
    closeSubMenu()

    local candidates, active = collectMasterworkCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Masterwork", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = active == nil and "Select one weapon or armor piece to masterwork." or "Restore your current masterwork before choosing another item.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = active == nil and "No weapons or armor found in your inventory." or "Your masterworked item is not in your inventory.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, item in ipairs(candidates) do
            local recordId = item.recordId
            local currentCondition = getItemCondition(item)
            local maxCondition = getMaxCondition(item)
            local masterworkInfo = getMasterworkedGearInfo(recordId, getDisplayName(item))
            local modeLabel = masterworkInfo ~= nil and " [" .. formatMasterworkMode() .. "]" or ""
            local conditionLabel = ""
            if type(currentCondition) == "number" and type(maxCondition) == "number" then
                conditionLabel = string.format(" (%d/%d)", math.floor(currentCondition + 0.5), math.floor(maxCondition + 0.5))
            end
            local count = getObjectCount(item)
            local countLabel = count > 1 and (" x" .. tostring(count)) or ""
            local entry = {
                item = item,
                recordId = recordId,
                name = getDisplayName(item),
            }
            table.insert(contentLayouts, createButton(entry.name .. countLabel .. modeLabel .. conditionLabel, function()
                openMasterworkModeMenu(entry)
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = MASTERWORK_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function sendArmorRefitRequest(item, mode, refitInfo)
    if item == nil or type(mode) ~= "string" then
        showMessage("That armor is no longer eligible.")
        return
    end

    closeAllMenus()
    core.sendGlobalEvent(ARMOR_REFIT_REQUEST_EVENT, {
        player = getActorObject(),
        targetItem = item,
        mode = mode,
        targetName = getDisplayName(item),
        originalRecordId = type(refitInfo) == "table" and refitInfo.originalRecordId or nil,
        originalName = type(refitInfo) == "table" and refitInfo.originalName or nil,
        generatedRecordId = type(refitInfo) == "table" and refitInfo.generatedRecordId or nil,
        generatedName = type(refitInfo) == "table" and refitInfo.generatedName or nil,
    })
end

local openArmorRefitMenu

local function openArmorRefitModeMenu(entry)
    closeSubMenu()

    local recordId = entry.item ~= nil and entry.item.recordId or entry.recordId
    local refitInfo = getRefittedArmorInfo(recordId, entry.name)
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = entry.name, textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if refitInfo ~= nil then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "This armor is " .. formatArmorRefitMode(refitInfo.mode) .. ".", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Restore Original", function()
            sendArmorRefitRequest(entry.item, "restore", refitInfo)
        end, 620))
    else
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose one refit. Value is unchanged.", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Reinforce: +7% armor, +20% weight, +15% durability", function()
            sendArmorRefitRequest(entry.item, "reinforced")
        end, 620))
        table.insert(contentLayouts, createButton("Trim: -20% weight, -10% armor, -20% durability", function()
            sendArmorRefitRequest(entry.item, "trimmed")
        end, 620))
    end

    table.insert(contentLayouts, createButton("Back", function()
        openArmorRefitMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = ARMOR_REFIT_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

openArmorRefitMenu = function()
    closeSubMenu()

    local candidates = collectArmorRefitCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Reforged Plating", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Select armor to reinforce, trim, or restore.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "No armor found in your inventory.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, item in ipairs(candidates) do
            local recordId = item.recordId
            local currentCondition = getItemCondition(item)
            local maxCondition = getMaxCondition(item)
            local modeLabel = ""
            local refitInfo = getRefittedArmorInfo(recordId, getDisplayName(item))
            if refitInfo ~= nil then
                modeLabel = " [" .. formatArmorRefitMode(refitInfo.mode) .. "]"
            end
            local conditionLabel = ""
            if type(currentCondition) == "number" and type(maxCondition) == "number" then
                conditionLabel = string.format(" (%d/%d)", math.floor(currentCondition + 0.5), math.floor(maxCondition + 0.5))
            end
            local count = getObjectCount(item)
            local countLabel = count > 1 and (" x" .. tostring(count)) or ""
            local entry = {
                item = item,
                recordId = recordId,
                name = getDisplayName(item),
            }
            table.insert(contentLayouts, createButton(entry.name .. countLabel .. modeLabel .. conditionLabel, function()
                openArmorRefitModeMenu(entry)
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = ARMOR_REFIT_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function openRepairMenu()
    closeAllMenus()
    customMenuOpen = true

    local repairToolItem = getActiveRepairTool()
    if repairToolItem ~= nil then
        lastRepairTool = repairToolItem
        lastRepairToolRecordId = repairToolItem.recordId
        setSharedActiveRepairTool(repairToolItem, "openRepairMenu")
        logDebug("openRepairMenu captured " .. tostring(lastRepairToolRecordId))
    else
        logDebug("openRepairMenu captured nil repair tool")
    end

    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Repair Tool Action", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose how to use this repair tool.", textAlignH = ui.ALIGNMENT.Center },
        },
        createButton("Repair", function()
            requestBaseRepairUi(repairToolItem or getActiveRepairTool())
        end, 560),
    }

    if apprenticeHammerEnabled() then
        table.insert(contentLayouts, createButton("Over Repair", function()
            openOverRepairMenu(repairToolItem or getActiveRepairTool())
        end, 560))
    end

    if weaponTemperEnabled() then
        table.insert(contentLayouts, createButton("Hone / Harden", function()
            openTemperWeaponMenu()
        end, 560))
    end

    if armorRefitEnabled() then
        table.insert(contentLayouts, createButton("Reforged Plating", function()
            openArmorRefitMenu()
        end, 560))
    end

    if masterworkEnabled() then
        table.insert(contentLayouts, createButton("Masterwork", function()
            openMasterworkMenu()
        end, 560))
    end

    table.insert(contentLayouts, createButton("Close", function()
        closeAllMenus()
        setInterfaceMode()
    end, 560))

    rootMenuElement = ui.create({
        layer = "Windows",
        name = MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function onRecordRepairTool(data)
    if type(data) ~= "table" or data.item == nil then
        logDebug("SkillPerkSystem_RecordRepairTool received invalid data")
        return
    end

    lastRepairTool = data.item
    lastRepairToolRecordId = data.recordId or data.item.recordId
    setSharedActiveRepairTool(data.item, "recordRepairTool")
    logDebug("recorded repair tool " .. tostring(lastRepairToolRecordId))
end

local function onArmorRefitResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        if data.mode == "restore" and type(data.restoredRecordId) == "string" then
            local existing = refittedArmorCache[data.restoredRecordId] or getRefittedArmorInfo(data.restoredRecordId)
            local records = getRefittedArmorRecords()
            records[data.restoredRecordId] = nil
            if type(existing) == "table" and type(existing.generatedName) == "string" then
                records.byGeneratedName[existing.generatedName] = nil
            end
            refittedArmorCache[data.restoredRecordId] = nil
            setRefittedArmorRecords(records)
        elseif type(data.recordId) == "string" and data.recordId ~= "" then
            local entry = {
                originalRecordId = data.originalRecordId,
                originalName = data.originalName,
                generatedRecordId = data.recordId,
                generatedName = data.generatedName,
                mode = data.mode,
            }
            local records = getRefittedArmorRecords()
            records[data.recordId] = entry
            if type(data.generatedName) == "string" then
                records.byGeneratedName[data.generatedName] = entry
            end
            refittedArmorCache[data.recordId] = entry
            setRefittedArmorRecords(records)
        end
        showMessage(tostring(data.message or "Armor refitting complete."))
    else
        showMessage(tostring(data.message or "That armor could not be refitted."))
    end
end

local function onTemperResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        if data.mode == "restore" and type(data.restoredRecordId) == "string" then
            local existing = temperedWeaponCache[data.restoredRecordId] or getTemperedWeaponInfo(data.restoredRecordId)
            local records = getTemperedWeaponRecords()
            records[data.restoredRecordId] = nil
            if type(existing) == "table" and type(existing.generatedName) == "string" then
                records.byGeneratedName[existing.generatedName] = nil
            end
            temperedWeaponCache[data.restoredRecordId] = nil
            setTemperedWeaponRecords(records)
        elseif type(data.recordId) == "string" and data.recordId ~= "" then
            local entry = {
                originalRecordId = data.originalRecordId,
                originalName = data.originalName,
                generatedRecordId = data.recordId,
                generatedName = data.generatedName,
                mode = data.mode,
            }
            local records = getTemperedWeaponRecords()
            records[data.recordId] = entry
            if type(data.generatedName) == "string" then
                records.byGeneratedName[data.generatedName] = entry
            end
            temperedWeaponCache[data.recordId] = entry
            setTemperedWeaponRecords(records)
        end
        showMessage(tostring(data.message or "Weapon tempering complete."))
    else
        showMessage(tostring(data.message or "That weapon could not be tempered."))
    end
end

local function onMasterworkResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        if data.mode == "restore" then
            setMasterworkedGearRecord(nil)
        elseif type(data.recordId) == "string" and data.recordId ~= "" then
            setMasterworkedGearRecord({
                originalRecordId = data.originalRecordId,
                originalName = data.originalName,
                generatedRecordId = data.recordId,
                generatedName = data.generatedName,
                itemType = data.itemType,
                mode = data.mode,
            })
        end
        showMessage(tostring(data.message or "Masterwork complete."))
    else
        showMessage(tostring(data.message or "That item could not be masterworked."))
    end
end

local function onOverrepairResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        if type(data.repairToolCondition) == "number" then
            __basepack_repair_tool_state.lastCondition = data.repairToolCondition
            __basepack_repair_tool_state.source = "apprentice_hammer_overrepair_result"
        end
        logDebug("overrepair success for " .. tostring(data.recordId) .. " -> " .. tostring(data.targetCondition))
        showMessage(string.format("%s is now at %d condition.", tostring(data.name or "Item"), tonumber(data.targetCondition) or 0))
    else
        logDebug("overrepair failed in global handler reason=" .. tostring(data.reason) .. " recordId=" .. tostring(data.recordId))
        showMessage(tostring(data.message or "That item could not be over-repaired."))
    end
end

local function handleUiModeChanged(data)
    if type(data) ~= "table" then return end

    if data.newMode == "Repair" then
        if suppressNextRepairIntercept then
            suppressNextRepairIntercept = false
            return
        end

        if not anyRepairToolActionEnabled() then
            closeAllMenus()
            return
        end

        openRepairMenu()
        setInterfaceMode()
        return
    end

    if data.newMode == nil or data.newMode == "MainMenu" then
        closeAllMenus()
    end
end

local function shouldFramePendingRepairUse()
    return pendingUseRepairFrames > 0 and pendingUseRepairTool ~= nil
end

local function tryPendingRepairUse()
    if pendingUseRepairFrames <= 0 or pendingUseRepairTool == nil then return end

    pendingUseRepairFrames = pendingUseRepairFrames - 1
    if pendingUseRepairFrames > 0 then return end

    logDebug("triggering UseItem for " .. tostring(pendingUseRepairTool.recordId))
    core.sendGlobalEvent("UseItem", {
        object = pendingUseRepairTool,
        actor = pself,
    })
    pendingUseRepairTool = nil
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    eventHandlers = {
        UiModeChanged = handleUiModeChanged,
        SkillPerkSystem_RecordRepairTool = onRecordRepairTool,
        [OVERREPAIR_RESULT_EVENT] = onOverrepairResult,
        [TEMPER_RESULT_EVENT] = onTemperResult,
        [ARMOR_REFIT_RESULT_EVENT] = onArmorRefitResult,
        [MASTERWORK_RESULT_EVENT] = onMasterworkResult,
    },
    engineHandlers = {
        onLoad = function(savedData)
            if type(savedData) == "table" and type(savedData.masterworkedGear) == "table" and type(savedData.masterworkedGear.generatedRecordId) == "string" then
                masterworkedGearCache = savedData.masterworkedGear
            else
                masterworkedGearCache = nil
            end
            logDebug("onLoad")
        end,
        onSave = function()
            return {
                masterworkedGear = masterworkedGearCache,
            }
        end,
        onFrame = function()
            tryPendingRepairUse()
        end,
        shouldFrame = shouldFramePendingRepairUse,
    },
}

end

----------------------------------------------------------------------
-- careful repairs runtime logic (from careful_repairs_runtime.lua)
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")

local NO_CONSUME_CHANCE = 0.15
local SUPPRESS_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_SuppressRepairToolDrops"
local MODIFY_REPAIR_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_ModifyRepairToolCondition"
local REFUND_RESULT_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_RefundResult"
local REPAIR_TOOL_USE_EVENT = "SkillPerkSystem_RecordRepairTool"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local CAREFUL_REPAIRS_PERK_ID = "armorer_careful_repairs"
local MAX_CONDITION_ROLLS_PER_UPDATE = 8
local LOG_TAG = "[SkillPerkSystem_BasePack][CarefulRepairs]"

local trackedToolsByKey = {}
local suppressDropsRemaining = 0
local repairToolScanRemaining = 0
local repairToolScanTimer = 0
local repairToolsDirty = false
local repairMenuActive = false
local REPAIR_TOOL_SCAN_WINDOW = 2.0
local REPAIR_TOOL_SCAN_INTERVAL = 0.25

local function log(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function carefulRepairsEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(CAREFUL_REPAIRS_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(CAREFUL_REPAIRS_PERK_ID) then
        return false
    end

    return true
end

local function getActorObject()
    return pself.object or pself
end

local function getPlayerInventory()
    local okInv, inventory = pcall(types.Actor.inventory, getActorObject())
    if not okInv or inventory == nil then
        return nil
    end
    return inventory
end

local function sequenceToArray(seq)
    if seq == nil then
        return {}
    end

    local out = {}
    local okLen, len = pcall(function()
        return #seq
    end)
    if okLen and type(len) == "number" then
        for i = 1, len do
            out[#out + 1] = seq[i]
        end
        return out
    end

    local okPairs = pcall(function()
        for _, item in pairs(seq) do
            out[#out + 1] = item
        end
    end)
    if not okPairs then
        return {}
    end

    return out
end

local function getRepairTools()
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll(types.Repair)
    end)
    if okAll and items ~= nil then
        return sequenceToArray(items)
    end

    return {}
end

local function repairToolCondition(item)
    if item == nil or not types.Repair.objectIsInstance(item) then
        return nil
    end

    local okData, data = pcall(types.Item.itemData, item)
    if not okData or data == nil then
        return nil
    end

    local okCondition, condition = pcall(function()
        return data.condition
    end)
    if okCondition and type(condition) == "number" then
        return condition, data
    end

    return nil, data
end

local function repairToolMaxCondition(item)
    if item == nil then
        return nil
    end

    local okRecord, record = pcall(types.Repair.record, item)
    if okRecord and record ~= nil then
        local okMax, maxCondition = pcall(function()
            return record.maxCondition
        end)
        if okMax and type(maxCondition) == "number" then
            return maxCondition
        end
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        local okById, recordById = pcall(function()
            return types.Repair.records[recordId]
        end)
        if okById and recordById ~= nil then
            local okMax, maxCondition = pcall(function()
                return recordById.maxCondition
            end)
            if okMax and type(maxCondition) == "number" then
                return maxCondition
            end
        end
    end

    return nil
end

local function objectKey(item)
    if item == nil then
        return nil
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        return "record:" .. recordId
    end

    local okId, id = pcall(function()
        return item.id
    end)
    if okId and id ~= nil then
        return "id:" .. tostring(id)
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        return "record:" .. recordId .. ":" .. tostring(item)
    end

    return tostring(item)
end

local function snapshotRepairTools()
    local out = {}
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and types.Repair.objectIsInstance(item) then
            local key = objectKey(item)
            local condition = repairToolCondition(item)
            if key ~= nil then
                out[key] = {
                    item = item,
                    recordId = item.recordId,
                    condition = condition,
                }
            end
        end
    end
    return out
end

local function findRepairToolByRecordId(recordId, excludeItem)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local fallback = nil
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and item ~= excludeItem and item.recordId == recordId and types.Repair.objectIsInstance(item) then
            local condition = repairToolCondition(item)
            if type(condition) == "number" and condition > 0 then
                return item
            end
            fallback = fallback or item
        end
    end

    return fallback
end

local function findAnyUsableRepairTool(excludeItem)
    local fallback = nil
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and item ~= excludeItem and types.Repair.objectIsInstance(item) then
            local condition = repairToolCondition(item)
            if type(condition) == "number" and condition > 0 then
                return item
            end
            fallback = fallback or item
        end
    end
    return fallback
end

local function switchSharedActiveRepairTool(item, source, resetCondition)
    if item == nil or not types.Repair.objectIsInstance(item) then
        return nil
    end

    __basepack_repair_tool_state.item = item
    __basepack_repair_tool_state.recordId = item.recordId
    if resetCondition ~= false then
        __basepack_repair_tool_state.lastCondition = repairToolCondition(item)
    end
    __basepack_repair_tool_state.source = source
    return item
end

local function resolveSharedActiveRepairTool()
    local item = __basepack_repair_tool_state.item
    if item ~= nil and types.Repair.objectIsInstance(item) then
        local condition = repairToolCondition(item)
        if type(condition) == "number" then
            if condition > 0 or __basepack_repair_tool_state.lastCondition ~= condition then
                return item
            end

            if not repairMenuActive then
                return item
            end
        end

        if repairMenuActive then
            local replacement = findRepairToolByRecordId(__basepack_repair_tool_state.recordId, item)
                or findAnyUsableRepairTool(item)
            if replacement ~= nil then
                return switchSharedActiveRepairTool(replacement, "repairMenuRollover")
            end
        end
    end

    item = findRepairToolByRecordId(__basepack_repair_tool_state.recordId)
    if item == nil and repairMenuActive then
        item = findAnyUsableRepairTool(nil)
    end

    return switchSharedActiveRepairTool(item, "repairToolResolve")
end

local function requestRefund(toolState, amount)
    if toolState == nil or toolState.item == nil then
        return false
    end

    if type(amount) ~= "number" or amount <= 0 then
        return false
    end

    core.sendGlobalEvent(MODIFY_REPAIR_TOOL_CONDITION_EVENT, {
        player = getActorObject(),
        tool = toolState.item,
        recordId = toolState.recordId,
        amount = amount,
    })
    return true
end

local function rollAndRefund(toolState, attempts)
    if not carefulRepairsEnabled() then
        return
    end

    local chance = NO_CONSUME_CHANCE

    local refunds = 0
    for _ = 1, attempts do
        if math.random() < chance then
            refunds = refunds + 1
        end
    end

    if refunds <= 0 then
        return
    end

    if requestRefund(toolState, refunds) then
        log(string.format("refund requested uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
    else
        log(string.format("refund request failed uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
    end
end

local function maybeRefundCondition(previousState, currentState)
    if previousState == nil or currentState == nil then
        return
    end

    local oldCondition = previousState.condition
    local newCondition = currentState.condition
    if type(oldCondition) ~= "number" or type(newCondition) ~= "number" then
        return
    end
    if newCondition >= oldCondition then
        return
    end

    local delta = math.floor(oldCondition - newCondition)
    if delta < 1 then
        delta = 1
    end

    if suppressDropsRemaining > 0 then
        suppressDropsRemaining = math.max(0, suppressDropsRemaining - delta)
        log(string.format("suppressed repair tool drop delta=%d remaining=%d recordId=%s", delta, suppressDropsRemaining, tostring(currentState.recordId)))
        return
    end

    local rollAttempts = math.min(delta, MAX_CONDITION_ROLLS_PER_UPDATE)
    if delta > rollAttempts then
        log(string.format("multi-use repair tool drop capped delta=%d cap=%d recordId=%s", delta, MAX_CONDITION_ROLLS_PER_UPDATE, tostring(currentState.recordId)))
    end

    rollAndRefund(currentState, rollAttempts)
end

local function hasTrackedRepairTools()
    return next(trackedToolsByKey) ~= nil
end

local function openRepairToolScanWindow(scanWindow)
    repairToolsDirty = true
    repairToolScanRemaining = math.max(repairToolScanRemaining, tonumber(scanWindow) or REPAIR_TOOL_SCAN_WINDOW)
    repairToolScanTimer = REPAIR_TOOL_SCAN_INTERVAL
end

local function shouldUpdateCarefulRepairs(dt)
    if suppressDropsRemaining > 0 or repairToolsDirty then
        return true
    end

    if repairMenuActive then
        repairToolScanRemaining = math.max(repairToolScanRemaining, REPAIR_TOOL_SCAN_WINDOW)
        repairToolScanTimer = 0
        return true
    end

    if hasTrackedRepairTools() and repairToolScanRemaining > 0 then
        local deltaTime = tonumber(dt) or 0
        repairToolScanRemaining = math.max(0, repairToolScanRemaining - deltaTime)
        if repairToolScanRemaining <= 0 then
            trackedToolsByKey = {}
            return false
        end

        repairToolScanTimer = repairToolScanTimer + deltaTime
        if repairToolScanTimer < REPAIR_TOOL_SCAN_INTERVAL then
            return false
        end

        repairToolScanTimer = 0
        return true
    end

    return false
end

local function maybeRefundMissingTools(previousToolsByKey, currentToolsByKey)
    for key, previousState in pairs(previousToolsByKey) do
        if currentToolsByKey[key] == nil and type(previousState.condition) == "number" and previousState.condition <= 1 then
            if suppressDropsRemaining > 0 then
                suppressDropsRemaining = math.max(0, suppressDropsRemaining - 1)
                log(string.format("suppressed disappeared repair tool drop remaining=%d recordId=%s", suppressDropsRemaining, tostring(previousState.recordId)))
            else
                rollAndRefund(previousState, 1)
            end
        end
    end
end

local function compareSharedActiveRepairTool()
    local item = resolveSharedActiveRepairTool()
    if item == nil then
        __basepack_repair_tool_state.lastCondition = nil
        return nil, nil
    end

    local condition = repairToolCondition(item)
    local key = objectKey(item)
    local currentState = {
        item = item,
        recordId = item.recordId,
        condition = condition,
    }

    local previousCondition = __basepack_repair_tool_state.lastCondition
    if type(condition) ~= "number" then
        return key, currentState
    end

    if type(previousCondition) == "number" and condition < previousCondition then
        local delta = math.floor(previousCondition - condition)
        if delta < 1 then
            delta = 1
        end
        local rollAttempts = math.min(delta, MAX_CONDITION_ROLLS_PER_UPDATE)
        rollAndRefund(currentState, rollAttempts)

        if condition <= 0 and repairMenuActive then
            local replacement = findRepairToolByRecordId(item.recordId, item) or findAnyUsableRepairTool(item)
            if replacement ~= nil then
                local replacementCondition = repairToolCondition(replacement)
                switchSharedActiveRepairTool(replacement, "repairToolConsumed")
                return objectKey(replacement), {
                    item = replacement,
                    recordId = replacement.recordId,
                    condition = replacementCondition,
                }
            end
        end
    end

    __basepack_repair_tool_state.item = item
    __basepack_repair_tool_state.recordId = item.recordId
    __basepack_repair_tool_state.lastCondition = condition
    return key, currentState
end

local function shouldFrameCarefulRepairs()
    return repairMenuActive or repairToolsDirty
end

local function onUpdate()
    if not carefulRepairsEnabled() then
        trackedToolsByKey = {}
        suppressDropsRemaining = 0
        return
    end

    repairToolsDirty = false
    local activeKey, activeState = compareSharedActiveRepairTool()
    local currentToolsByKey = snapshotRepairTools()
    if activeKey ~= nil and activeState ~= nil then
        currentToolsByKey[activeKey] = activeState
    end

    for key, currentState in pairs(currentToolsByKey) do
        if key ~= activeKey then
            maybeRefundCondition(trackedToolsByKey[key], currentState)
        end
    end
    maybeRefundMissingTools(trackedToolsByKey, currentToolsByKey)

    trackedToolsByKey = currentToolsByKey
end

local function handleSuppressRepairToolDrops(data)
    if type(data) ~= "table" then
        return
    end

    local amount = math.floor(tonumber(data.amount) or 0)
    if amount <= 0 then
        return
    end

    if data.source == "apprentice_hammer_overrepair" then
        trackedToolsByKey = {}
        repairToolsDirty = false
        repairToolScanRemaining = 0
        repairToolScanTimer = 0
        log(string.format("skipping overrepair tool-drop scan amount=%d", amount))
        return
    end

    suppressDropsRemaining = suppressDropsRemaining + amount
    trackedToolsByKey = snapshotRepairTools()
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("suppressing next repair tool drops amount=%d total=%d", amount, suppressDropsRemaining))
end

local function handleRepairToolUse(data)
    if type(data) ~= "table" or data.item == nil then
        return
    end

    if not carefulRepairsEnabled() then
        return
    end

    __basepack_repair_tool_state.item = data.item
    __basepack_repair_tool_state.recordId = data.recordId or data.item.recordId
    __basepack_repair_tool_state.lastCondition = repairToolCondition(data.item)
    __basepack_repair_tool_state.source = "recordRepairTool"
    trackedToolsByKey = snapshotRepairTools()
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("repair tool use captured recordId=%s", tostring(data.recordId or data.item.recordId)))
end

local function handleUiModeChanged(data)
    if type(data) ~= "table" then
        return
    end

    repairMenuActive = data.newMode == "Repair"
    if repairMenuActive then
        openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    elseif data.newMode == nil or data.newMode == "MainMenu" then
        repairToolScanRemaining = math.min(repairToolScanRemaining, REPAIR_TOOL_SCAN_WINDOW)
    end
end

local function handleRefundResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success ~= true then
        log(string.format(
            "refund failed uses=%s recordId=%s reason=%s",
            tostring(data.amount),
            tostring(data.recordId),
            tostring(data.reason)
        ))
        return
    end

    local amount = math.floor(tonumber(data.amount) or 0)
    if amount <= 0 then
        return
    end

    local useLabel = amount == 1 and "use" or "uses"
    ui.showMessage(string.format("Careful Repairs preserved %d repair tool %s.", amount, useLabel), { showInDialogue = false })
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("refunded uses=%d recordId=%s", amount, tostring(data.recordId)))
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    engineHandlers = {
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdateCarefulRepairs,
        onFrame = onUpdate,
        shouldFrame = shouldFrameCarefulRepairs,
        onLoad = function(data)
            suppressDropsRemaining = math.max(0, math.floor(tonumber(type(data) == "table" and data.suppressDropsRemaining) or 0))
            trackedToolsByKey = {}
            if suppressDropsRemaining > 0 then
                openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
            end
        end,
        onSave = function()
            return {
                suppressDropsRemaining = suppressDropsRemaining,
            }
        end,
    },
    eventHandlers = {
        UiModeChanged = handleUiModeChanged,
        [REPAIR_TOOL_USE_EVENT] = handleRepairToolUse,
        [SUPPRESS_EVENT] = handleSuppressRepairToolDrops,
        [REFUND_RESULT_EVENT] = handleRefundResult,
    },
}

end


----------------------------------------------------------------------
-- hand-to-hand runtime logic
----------------------------------------------------------------------
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Clothing = types.Clothing
local NPC = types.NPC
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local CENTERED_STANCE_PERK_ID = "handtohand_centered_stance"
local OPEN_PALM_PERK_ID = "handtohand_open_palm"
local IRON_KNUCKLES_PERK_ID = "handtohand_iron_knuckles"
local FLOWING_COUNTER_PERK_ID = "handtohand_flowing_counter"
local EMPTY_BODY_MASTERY_PERK_ID = "handtohand_empty_body_mastery"
local BREAKING_FIST_PERK_ID = "handtohand_breaking_fist"
local CENTERED_STANCE_BONUS = 3
local FLOWING_COUNTER_ABILITY_ID = "sps_DeflectingPalm"
local FLOWING_COUNTER_HEAVY_AGILITY_PENALTY = 10
local FLOWING_COUNTER_HEAVY_ATTACK_SPEED_MULTIPLIER = 0.80
local OPEN_PALM_BONUS_PER_STACK = 3
local OPEN_PALM_MAX_STACKS = 5
local OPEN_PALM_DURATION = 6.0
local HAND_TO_HAND_STATE_EVENT = "SkillPerkSystem_HandToHandState"
local HAND_TO_HAND_IDLE_REFRESH_INTERVAL = 0.5

local appliedBonuses = {}
local flowingCounterAppliedAgilityPenalty = 0
local flowingCounterAbilityApplied = false
local resolveAttributeStat
local openPalmStacks = 0
local openPalmRemaining = 0
local appliedOpenPalmBonus = 0
local handToHandStateDirty = true
local handToHandIdleRefreshTimer = HAND_TO_HAND_IDLE_REFRESH_INTERVAL
local handToHandDirty = true
local handToHandScanRemaining = 0
local handToHandScanTimer = 0
local HAND_TO_HAND_SCAN_WINDOW = 1.5
local HAND_TO_HAND_SCAN_INTERVAL = 0.25
local DEFAULT_HAND_TO_HAND_STATE_KEY = "false:false:none"
local lastHandToHandStateKey = nil
local handToHandEquipmentCache = {
    key = nil,
    hasWeaponOrShield = true,
    flowingCounterMode = "none",
}
local lastEmptyBodyAttackShape = nil
local EMPTY_BODY_DEBUG = true

local function logEmptyBodyDebug(message)
    if EMPTY_BODY_DEBUG then
        print("[SkillPerkSystem_BasePack][EmptyBody][Player][debug] " .. tostring(message))
    end
end

local ATTRIBUTES = {
    "agility",
    "endurance",
    "willpower",
}

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function getEquippedItem(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getArmorRecord(item)
    if item == nil or Armor == nil then
        return nil
    end

    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Armor.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Armor.records) == "table" then
        return Armor.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function getClothingRecord(item)
    if item == nil or Clothing == nil then
        return nil
    end

    if type(Clothing.record) == "function" then
        local okRecord, record = pcall(Clothing.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Clothing.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Clothing.records) == "table" then
        return Clothing.records[item.recordId]
    end

    return nil
end

local function itemIsWeapon(item)
    return item ~= nil and Weapon ~= nil and type(Weapon.objectIsInstance) == "function" and Weapon.objectIsInstance(item)
end

local function itemIsShield(item)
    if item == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return false
    end

    local record = getArmorRecord(item)
    return record ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE.Shield
end

local function armorTypeEquals(record, typeName)
    return record ~= nil and Armor ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE[typeName]
end

local function clothingTypeEquals(record, typeName)
    return record ~= nil and Clothing ~= nil and Clothing.TYPE ~= nil and record.type == Clothing.TYPE[typeName]
end

local function getGloveRecordFromItem(item)
    if item == nil then
        return nil
    end
    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return nil
    end

    return getArmorRecord(item)
end

local function getEmptyBodyHandRecord(item, hand)
    if item == nil then
        return nil, nil
    end

    if Armor ~= nil and type(Armor.objectIsInstance) == "function" and Armor.objectIsInstance(item) then
        local record = getArmorRecord(item)
        local expectedGauntletType = hand == "right" and "RGauntlet" or "LGauntlet"
        local expectedBracerType = hand == "right" and "RBracer" or "LBracer"

        if armorTypeEquals(record, expectedGauntletType) or armorTypeEquals(record, expectedBracerType) then
            return record, "armor"
        end
    end

    if Clothing ~= nil and type(Clothing.objectIsInstance) == "function" and Clothing.objectIsInstance(item) then
        local record = getClothingRecord(item)
        local expectedGloveType = hand == "right" and "RGlove" or "LGlove"

        if clothingTypeEquals(record, expectedGloveType) then
            return record, "clothing"
        end
    end

    return nil, nil
end

local function normalizedRecordText(record)
    local parts = {}
    if type(record.id) == "string" then
        parts[#parts + 1] = record.id
    end
    if type(record.name) == "string" then
        parts[#parts + 1] = record.name
    end
    if type(record.icon) == "string" then
        parts[#parts + 1] = record.icon
    end
    if type(record.model) == "string" then
        parts[#parts + 1] = record.model
    end

    return string.lower(table.concat(parts, " "))
end

local function gloveArmorClass(record)
    if record == nil then
        return "none"
    end

    local recordText = normalizedRecordText(record)
    local lightArmorHints = {
        "chitin",
        "dreugh",
        "glass",
        "leather",
        "netch",
        "nordic fur",
        "wolv",
    }
    for _, hint in ipairs(lightArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return "light"
        end
    end

    local mediumArmorHints = {
        "adamantium",
        "bonemold",
        "chain",
        "ice armor",
        "imperial chain",
        "orcish",
        "royal guard",
        "scale",
        "snow bear",
        "snow wolf",
    }
    for _, hint in ipairs(mediumArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return "medium"
        end
    end

    local heavyArmorHints = {
        "daedric",
        "dwemer",
        "ebony",
        "her hand",
        "imperial steel",
        "iron",
        "nordic mail",
        "steel",
    }
    for _, hint in ipairs(heavyArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return "heavy"
        end
    end

    -- OpenMW exposes the armor body-part type but not the TES3 armor skill
    -- class through ArmorRecord, so use the record's weight as a final
    -- fallback for modded gloves that do not include vanilla material names.
    local weight = tonumber(record.weight) or 0
    if weight <= 2 then
        return "light"
    elseif weight <= 6 then
        return "medium"
    end

    return "heavy"
end

local function itemCacheKey(item)
    if item == nil then
        return ""
    end

    return tostring(item.recordId or item.id or "")
end

local function readHandToHandEquipmentSnapshot()
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil then
        return {
            key = "equipment-slots-unavailable",
            carriedRight = nil,
            carriedLeft = nil,
            leftGlove = nil,
            rightGlove = nil,
        }
    end

    local carriedRight = getEquippedItem(slots.CarriedRight)
    local carriedLeft = getEquippedItem(slots.CarriedLeft)
    local leftGlove = getEquippedItem(slots.LeftGauntlet)
    local rightGlove = getEquippedItem(slots.RightGauntlet)

    return {
        key = table.concat({
            itemCacheKey(carriedRight),
            itemCacheKey(carriedLeft),
            itemCacheKey(leftGlove),
            itemCacheKey(rightGlove),
            tostring(hasEnabledPerk(FLOWING_COUNTER_PERK_ID)),
        }, "|"),
        carriedRight = carriedRight,
        carriedLeft = carriedLeft,
        leftGlove = leftGlove,
        rightGlove = rightGlove,
    }
end

local function computeHasEquippedWeaponOrShield(snapshot)
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return true
    end

    return itemIsWeapon(snapshot.carriedRight)
        or itemIsShield(snapshot.carriedRight)
        or itemIsWeapon(snapshot.carriedLeft)
        or itemIsShield(snapshot.carriedLeft)
end

local function computeFlowingCounterMode(snapshot)
    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) or Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return "none"
    end

    local leftRecord = getGloveRecordFromItem(snapshot.leftGlove)
    local rightRecord = getGloveRecordFromItem(snapshot.rightGlove)
    local leftHasGlove = leftRecord ~= nil and (armorTypeEquals(leftRecord, "LGauntlet") or armorTypeEquals(leftRecord, "LBracer"))
    local rightHasGlove = rightRecord ~= nil and (armorTypeEquals(rightRecord, "RGauntlet") or armorTypeEquals(rightRecord, "RBracer"))

    if not leftHasGlove and not rightHasGlove then
        return "bare"
    end
    if not leftHasGlove or not rightHasGlove then
        return "none"
    end

    local leftClass = gloveArmorClass(leftRecord)
    local rightClass = gloveArmorClass(rightRecord)
    if leftClass == rightClass then
        return leftClass
    end

    return "none"
end

local function refreshHandToHandEquipmentCache(force)
    local snapshot = readHandToHandEquipmentSnapshot()
    if not force and handToHandEquipmentCache.key == snapshot.key then
        return
    end

    handToHandEquipmentCache = {
        key = snapshot.key,
        hasWeaponOrShield = computeHasEquippedWeaponOrShield(snapshot),
        flowingCounterMode = computeFlowingCounterMode(snapshot),
    }
end

local function cachedHasEquippedWeaponOrShield()
    return handToHandEquipmentCache.hasWeaponOrShield == true
end

local function cachedFlowingCounterMode()
    return type(handToHandEquipmentCache.flowingCounterMode) == "string" and handToHandEquipmentCache.flowingCounterMode or "none"
end

local function resolveAbilityRecord(abilityId)
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if okRecords and type(records) == "table" then
        return records[abilityId]
    end
    return nil
end

local function playerHasAbility(spells, abilityId)
    if spells == nil then
        return false
    end
    if type(spells.has) == "function" then
        local okHasById, hasById = pcall(function()
            return spells:has(abilityId)
        end)
        if okHasById and hasById == true then
            return true
        end

        local record = resolveAbilityRecord(abilityId)
        if record ~= nil then
            local okHasByRecord, hasByRecord = pcall(function()
                return spells:has(record)
            end)
            if okHasByRecord and hasByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == abilityId then
            return true
        end
    end

    return false
end

local function setPlayerAbility(abilityId, shouldHave)
    if Actor == nil or type(Actor.spells) ~= "function" then
        return shouldHave and flowingCounterAbilityApplied or false
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells or spells == nil then
        return shouldHave and flowingCounterAbilityApplied or false
    end

    local hasAbility = playerHasAbility(spells, abilityId)
    if shouldHave and not hasAbility and type(spells.add) == "function" then
        local ok = pcall(function()
            spells:add(abilityId)
        end)
        if not ok then
            local record = resolveAbilityRecord(abilityId)
            if record ~= nil then
                ok = pcall(function()
                    spells:add(record)
                end)
            end
        end
        return ok or flowingCounterAbilityApplied
    elseif not shouldHave and type(spells.remove) == "function" then
        local ok = pcall(function()
            spells:remove(abilityId)
        end)
        if not ok then
            local record = resolveAbilityRecord(abilityId)
            if record ~= nil then
                ok = pcall(function()
                    spells:remove(record)
                end)
            end
        end
        return not ok and flowingCounterAbilityApplied or false
    end

    return shouldHave and hasAbility
end

local function applyFlowingCounterAgilityPenalty(targetPenalty)
    local desired = math.max(0, math.floor(tonumber(targetPenalty) or 0))
    local current = math.max(0, math.floor(tonumber(flowingCounterAppliedAgilityPenalty) or 0))
    if desired == current then
        return
    end

    local stat = resolveAttributeStat("agility")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier + current - desired
    flowingCounterAppliedAgilityPenalty = desired
end

function resolveAttributeStat(attributeID)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes[attributeID]
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyAttributeBonus(attributeID, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBonuses[attributeID]) or 0))
    if desired == current then
        return
    end

    local stat = resolveAttributeStat(attributeID)
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedBonuses[attributeID] = desired
end


local function resolveHandToHandStat()
    local accessor = NPC ~= nil
        and NPC.stats ~= nil
        and NPC.stats.skills ~= nil
        and NPC.stats.skills.handtohand
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyOpenPalmBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedOpenPalmBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveHandToHandStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedOpenPalmBonus = desired
end

local function clearOpenPalmStacks()
    openPalmStacks = 0
    openPalmRemaining = 0
    applyOpenPalmBonus(0)
end

local function tryApplyOpenPalm(data)
    if type(data) ~= "table" or data.target == nil then
        return
    end
    refreshHandToHandEquipmentCache(true)
    if not hasEnabledPerk(OPEN_PALM_PERK_ID) or cachedHasEquippedWeaponOrShield() then
        clearOpenPalmStacks()
        return
    end

    openPalmStacks = math.min(OPEN_PALM_MAX_STACKS, math.max(0, math.floor(tonumber(openPalmStacks) or 0)) + 1)
    openPalmRemaining = OPEN_PALM_DURATION
    applyOpenPalmBonus(openPalmStacks * OPEN_PALM_BONUS_PER_STACK)
end

local function updateOpenPalm(dt)
    if openPalmStacks <= 0 then
        if appliedOpenPalmBonus ~= 0 then
            applyOpenPalmBonus(0)
        end
        return
    end

    if not hasEnabledPerk(OPEN_PALM_PERK_ID) or cachedHasEquippedWeaponOrShield() then
        clearOpenPalmStacks()
        return
    end

    openPalmRemaining = math.max(0, (tonumber(openPalmRemaining) or 0) - (tonumber(dt) or 0))
    if openPalmRemaining <= 0 then
        clearOpenPalmStacks()
    else
        applyOpenPalmBonus(openPalmStacks * OPEN_PALM_BONUS_PER_STACK)
    end
end

local function refreshHandToHandState(force)
    local ironKnucklesEnabled = hasEnabledPerk(IRON_KNUCKLES_PERK_ID)
    local breakingFistEnabled = hasEnabledPerk(BREAKING_FIST_PERK_ID)
    local emptyBodyMasteryEnabled = hasEnabledPerk(EMPTY_BODY_MASTERY_PERK_ID)
    local flowingCounterMode = hasEnabledPerk(FLOWING_COUNTER_PERK_ID) and cachedFlowingCounterMode() or "none"
    local stateKey = tostring(ironKnucklesEnabled) .. ":"
        .. tostring(breakingFistEnabled) .. ":"
        .. tostring(emptyBodyMasteryEnabled) .. ":"
        .. tostring(flowingCounterMode)
    if not force and stateKey == lastHandToHandStateKey then
        return
    end

    lastHandToHandStateKey = stateKey
    core.sendGlobalEvent(HAND_TO_HAND_STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        ironKnucklesEnabled = ironKnucklesEnabled,
        breakingFistEnabled = breakingFistEnabled,
        emptyBodyMasteryEnabled = emptyBodyMasteryEnabled,
        flowingCounterMode = flowingCounterMode,
    })
end

local function refreshFlowingCounter()
    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) then
        if flowingCounterAbilityApplied then
            flowingCounterAbilityApplied = setPlayerAbility(FLOWING_COUNTER_ABILITY_ID, false)
        end
        if flowingCounterAppliedAgilityPenalty ~= 0 then
            applyFlowingCounterAgilityPenalty(0)
        end
        return
    end

    local mode = cachedFlowingCounterMode()
    flowingCounterAbilityApplied = setPlayerAbility(FLOWING_COUNTER_ABILITY_ID, mode == "bare")
    applyFlowingCounterAgilityPenalty(mode == "heavy" and FLOWING_COUNTER_HEAVY_AGILITY_PENALTY or 0)
end

local function hasAppliedCenteredStanceBonus()
    for _, attributeID in ipairs(ATTRIBUTES) do
        if math.max(0, math.floor(tonumber(appliedBonuses[attributeID]) or 0)) ~= 0 then
            return true
        end
    end
    return false
end

local function refreshCenteredStance()
    local centeredStanceEnabled = hasEnabledPerk(CENTERED_STANCE_PERK_ID)
    if not centeredStanceEnabled and not hasAppliedCenteredStanceBonus() then
        return
    end

    local desiredBonus = 0
    if centeredStanceEnabled and not cachedHasEquippedWeaponOrShield() then
        desiredBonus = CENTERED_STANCE_BONUS
    end

    for _, attributeID in ipairs(ATTRIBUTES) do
        applyAttributeBonus(attributeID, desiredBonus)
    end
end

local HAND_TO_HAND_STATE_PERKS = {
    handtohand_centered_stance = true,
    handtohand_open_palm = true,
    handtohand_iron_knuckles = true,
    handtohand_flowing_counter = true,
    handtohand_empty_body_mastery = true,
    handtohand_breaking_fist = true,
}

local function markHandToHandDirty(scanWindow)
    handToHandDirty = true
    handToHandStateDirty = true
    handToHandScanRemaining = math.max(handToHandScanRemaining, tonumber(scanWindow) or HAND_TO_HAND_SCAN_WINDOW)
    handToHandScanTimer = HAND_TO_HAND_SCAN_INTERVAL
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or HAND_TO_HAND_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
end

local function shouldRunHandToHandUpdate(dt)
    if handToHandDirty
        or handToHandStateDirty
        or openPalmStacks > 0
        or appliedOpenPalmBonus ~= 0
        or (hasAppliedCenteredStanceBonus() and not hasEnabledPerk(CENTERED_STANCE_PERK_ID))
        or ((flowingCounterAbilityApplied or flowingCounterAppliedAgilityPenalty ~= 0) and not hasEnabledPerk(FLOWING_COUNTER_PERK_ID)) then
        return true
    end

    handToHandScanRemaining = math.max(0, handToHandScanRemaining - (tonumber(dt) or 0))
    if handToHandScanRemaining <= 0 then
        return false
    end

    handToHandScanTimer = handToHandScanTimer + (tonumber(dt) or 0)
    if handToHandScanTimer < HAND_TO_HAND_SCAN_INTERVAL then
        return false
    end

    handToHandScanTimer = 0
    return true
end

local function resolveAttackShapeFromText(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = string.lower(value)
    if string.find(normalized, "thrust", 1, true) ~= nil then
        return "thrust"
    end
    if string.find(normalized, "slash", 1, true) ~= nil then
        return "slash"
    end
    if string.find(normalized, "chop", 1, true) ~= nil then
        return "chop"
    end

    return nil
end

local function resolveAttackShapeFromType(value)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    if attackTypes ~= nil then
        if value == attackTypes.Chop then
            return "chop"
        end
        if value == attackTypes.Slash then
            return "slash"
        end
        if value == attackTypes.Thrust then
            return "thrust"
        end
    end

    return resolveAttackShapeFromText(value)
end

local function resolveHandToHandAttackShape(attack)
    if type(attack) ~= "table" then
        return lastEmptyBodyAttackShape
    end

    local candidates = {
        attack.attackType,
        attack.type,
        attack.attack,
        attack.attackKind,
        attack.attackSource,
        attack.source,
        attack.animation,
        attack.animationName,
        attack.groupName,
        attack.startKey,
        attack.stopKey,
    }

    for _, candidate in ipairs(candidates) do
        local shape = resolveAttackShapeFromType(candidate)
        if shape ~= nil then
            return shape
        end
    end

    return lastEmptyBodyAttackShape
end

local function getEnchantedGloveForAttackShape(shape)
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil, nil, nil
    end

    local slot = nil
    local hand = nil
    if shape == "chop" or shape == "slash" then
        slot = Actor.EQUIPMENT_SLOT.RightGauntlet
        hand = "right"
    elseif shape == "thrust" then
        slot = Actor.EQUIPMENT_SLOT.LeftGauntlet
        hand = "left"
    end

    if slot == nil then
        logEmptyBodyDebug("no glove slot for shape=" .. tostring(shape))
        return nil, nil, nil
    end

    local glove = getEquippedItem(slot)
    local record, recordKind = getEmptyBodyHandRecord(glove, hand)
    if record == nil then
        logEmptyBodyDebug("no matching hand item equipped for hand=" .. tostring(hand))
        return nil, nil, nil
    end

    local enchantmentId = record.enchant or record.enchantment
    if type(enchantmentId) == "table" and type(enchantmentId.id) == "string" then
        enchantmentId = enchantmentId.id
    end
    if type(enchantmentId) ~= "string" or enchantmentId == "" then
        logEmptyBodyDebug("matching glove/bracer has no enchantment for hand=" .. tostring(hand))
        return nil, nil, nil
    end

    logEmptyBodyDebug("resolved hand=" .. tostring(hand) .. " kind=" .. tostring(recordKind) .. " enchantmentId=" .. tostring(enchantmentId))
    return glove, enchantmentId, hand
end

local function tryApplyEmptyBodyMastery(attack, target)
    if target == nil or not hasEnabledPerk(EMPTY_BODY_MASTERY_PERK_ID) then
        logEmptyBodyDebug("skipped missing target or disabled perk")
        return false
    end

    local shape = resolveHandToHandAttackShape(attack)
    if shape == nil then
        logEmptyBodyDebug("skipped unresolved attack shape")
        return false
    end
    logEmptyBodyDebug("resolved attackShape=" .. tostring(shape))

    local glove, enchantmentId, hand = getEnchantedGloveForAttackShape(shape)
    if glove == nil then
        return false
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyEmptyBodyGloveEnchant", {
        attacker = pself,
        target = target,
        glove = glove,
        enchantmentId = enchantmentId,
        hand = hand,
        attackShape = shape,
    })

    logEmptyBodyDebug("sent global enchant event hand=" .. tostring(hand))
    return true
end

local function handleTryEmptyBodyMastery(data)
    if type(data) ~= "table" then
        return
    end
    if data.target == nil then
        logEmptyBodyDebug("target-side request missing target")
        lastEmptyBodyAttackShape = nil
        return
    end

    tryApplyEmptyBodyMastery({
        type = data.attackType or data.type,
        attackType = data.attackType or data.type,
        attack = data.attack,
        attackKind = data.attackKind,
        attackSource = data.attackSource,
        source = data.source,
        animation = data.animation,
        animationName = data.animationName,
        groupName = data.groupName,
        startKey = data.startKey,
        stopKey = data.stopKey,
    }, data.target)
    lastEmptyBodyAttackShape = nil
end

local function handleHandToHandAnimation(event)
    markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
    if not event.isHandToHandAttackShape then
        return
    end

    local emptyBodyAttackShape = resolveAttackShapeFromText(event.startKeyLower)
        or resolveAttackShapeFromText(event.stopKeyLower)
        or resolveAttackShapeFromText(event.groupLower)
    if emptyBodyAttackShape ~= nil then
        lastEmptyBodyAttackShape = emptyBodyAttackShape
    end

    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) then
        return
    end

    refreshHandToHandEquipmentCache(false)
    if cachedFlowingCounterMode() ~= "heavy" then
        return
    end
    if cachedHasEquippedWeaponOrShield() then
        return
    end

    multiplyAnimationSpeed(event.options, FLOWING_COUNTER_HEAVY_ATTACK_SPEED_MULTIPLIER)
end
registerBasepackAnimationHandler(handleHandToHandAnimation)

local function dispatchBasepackBlendedAnimation(groupName, options)
    local event = classifyBlendedAnimationEvent(groupName, options)

    for _, handler in ipairs(__basepack_animation_handlers) do
        handler(event)
    end
end

if interfaces.AnimationController ~= nil and type(interfaces.AnimationController.addPlayBlendedAnimationHandler) == "function" then
    interfaces.AnimationController.addPlayBlendedAnimationHandler(dispatchBasepackBlendedAnimation)
end

if interfaces.AnimationController ~= nil and type(interfaces.AnimationController.addTextKeyHandler) == "function" then
    interfaces.AnimationController.addTextKeyHandler("", dispatchBasepackAnimationTextKey)
end

__basepack_subsystems[#__basepack_subsystems + 1] = {
    eventHandlers = {
        SkillPerkSystem_TryOpenPalm = tryApplyOpenPalm,
        SkillPerkSystem_TryEmptyBodyMastery = handleTryEmptyBodyMastery,
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_HandToHandStateDirty = function() markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW) end,
        UiModeChanged = function()
            markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            handToHandDirty = false
            refreshHandToHandEquipmentCache(false)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(dt)
            if handToHandStateDirty then
                handToHandStateDirty = false
                refreshHandToHandState(false)
            end
        end,
        shouldUpdate = shouldRunHandToHandUpdate,
        onSave = function()
            refreshHandToHandEquipmentCache(true)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(0)
            refreshHandToHandState(true)
            return {
                centeredStanceAppliedBonuses = appliedBonuses,
                flowingCounterAppliedAgilityPenalty = flowingCounterAppliedAgilityPenalty,
                flowingCounterAbilityApplied = flowingCounterAbilityApplied,
                openPalmStacks = openPalmStacks,
                openPalmRemaining = openPalmRemaining,
                openPalmAppliedBonus = appliedOpenPalmBonus,
                handToHandEquipmentCache = {
                    key = handToHandEquipmentCache.key,
                    hasWeaponOrShield = handToHandEquipmentCache.hasWeaponOrShield == true,
                    flowingCounterMode = cachedFlowingCounterMode(),
                },
            }
        end,
        onLoad = function(data)
            if type(data) == "table" and type(data.centeredStanceAppliedBonuses) == "table" then
                appliedBonuses = data.centeredStanceAppliedBonuses
            else
                appliedBonuses = {}
            end
            flowingCounterAppliedAgilityPenalty = math.max(0, math.floor(tonumber(type(data) == "table" and data.flowingCounterAppliedAgilityPenalty) or 0))
            flowingCounterAbilityApplied = type(data) == "table" and data.flowingCounterAbilityApplied == true
            openPalmStacks = math.max(0, math.floor(tonumber(type(data) == "table" and data.openPalmStacks) or 0))
            openPalmRemaining = math.max(0, tonumber(type(data) == "table" and data.openPalmRemaining) or 0)
            appliedOpenPalmBonus = math.max(0, math.floor(tonumber(type(data) == "table" and data.openPalmAppliedBonus) or 0))
            handToHandIdleRefreshTimer = HAND_TO_HAND_IDLE_REFRESH_INTERVAL
            handToHandStateDirty = true
            markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
            local savedEquipmentCache = type(data) == "table"
                and type(data.handToHandEquipmentCache) == "table"
                and data.handToHandEquipmentCache
                or nil
            local savedFlowingCounterMode = type(savedEquipmentCache) == "table"
                and type(savedEquipmentCache.flowingCounterMode) == "string"
                and savedEquipmentCache.flowingCounterMode
                or "none"
            handToHandEquipmentCache = {
                key = type(savedEquipmentCache) == "table" and savedEquipmentCache.key or nil,
                hasWeaponOrShield = type(savedEquipmentCache) == "table" and savedEquipmentCache.hasWeaponOrShield == true,
                flowingCounterMode = savedFlowingCounterMode,
            }
            refreshHandToHandEquipmentCache(true)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(0)
            refreshHandToHandState(true)
        end,
    },
}

end

----------------------------------------------------------------------
-- combined eventHandlers
----------------------------------------------------------------------
local __combinedEventHandlers = {}
for _, subsystem in ipairs(__basepack_subsystems) do
    local handlers = subsystem.eventHandlers
    if type(handlers) == "table" then
        for eventName, handler in pairs(handlers) do
            if type(handler) == "function" then
                local previous = __combinedEventHandlers[eventName]
                if previous == nil then
                    __combinedEventHandlers[eventName] = handler
                else
                    __combinedEventHandlers[eventName] = function(data)
                        previous(data)
                        handler(data)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- combined engineHandlers
----------------------------------------------------------------------
local __combinedEngineHandlers = {}
local __engineHandlerChains = {}

local function predicateNameForHandler(handlerName)
    if handlerName == "onUpdate" then
        return "shouldUpdate"
    elseif handlerName == "onFrame" then
        return "shouldFrame"
    end
    return nil
end

for _, subsystem in ipairs(__basepack_subsystems) do
    local handlers = subsystem.engineHandlers
    if type(handlers) == "table" then
        for handlerName, handler in pairs(handlers) do
            if handlerName ~= "shouldUpdate" and handlerName ~= "shouldFrame" and type(handler) == "function" then
                local chain = __engineHandlerChains[handlerName]
                if chain == nil then
                    chain = {}
                    __engineHandlerChains[handlerName] = chain
                end
                local predicateName = predicateNameForHandler(handlerName)
                chain[#chain + 1] = {
                    handler = handler,
                    shouldRun = predicateName ~= nil and handlers[predicateName] or nil,
                }
            end
        end
    end
end

local INACTIVE_UPDATE_PREDICATE_INTERVAL = 0.10
local INACTIVE_FRAME_PREDICATE_INTERVAL = 0.10

local function makeCombinedOnUpdate(chain)
    local inactivePredicateTimer = INACTIVE_UPDATE_PREDICATE_INTERVAL

    return function(dt)
        local deltaTime = tonumber(dt) or 0
        inactivePredicateTimer = inactivePredicateTimer + deltaTime

        local scanInactivePredicates = inactivePredicateTimer >= INACTIVE_UPDATE_PREDICATE_INTERVAL
        if scanInactivePredicates then
            inactivePredicateTimer = 0
        end

        for index = 1, #chain do
            local entry = chain[index]
            local shouldRun = entry.shouldRun
            if type(shouldRun) ~= "function" then
                entry.handler(dt)
            elseif entry.updateActive then
                if shouldRun(dt) then
                    entry.handler(dt)
                else
                    entry.updateActive = false
                end
            elseif scanInactivePredicates and shouldRun(dt) then
                entry.updateActive = true
                entry.handler(dt)
            end
        end
    end
end

local function makeCombinedOnFrame(chain)
    local inactivePredicateTimer = INACTIVE_FRAME_PREDICATE_INTERVAL

    return function(dt)
        local deltaTime = tonumber(dt) or 0
        local pausedFrame = deltaTime <= 0
        inactivePredicateTimer = inactivePredicateTimer + deltaTime
        local scanInactivePredicates = pausedFrame or inactivePredicateTimer >= INACTIVE_FRAME_PREDICATE_INTERVAL
        if scanInactivePredicates and not pausedFrame then
            inactivePredicateTimer = 0
        end

        for index = 1, #chain do
            local entry = chain[index]
            local shouldRun = entry.shouldRun
            if type(shouldRun) ~= "function" then
                entry.handler(dt)
            elseif entry.frameActive then
                if shouldRun(dt) then
                    entry.handler(dt)
                else
                    entry.frameActive = false
                end
            elseif scanInactivePredicates and shouldRun(dt) then
                entry.frameActive = true
                entry.handler(dt)
            end
        end
    end
end

for handlerName, chain in pairs(__engineHandlerChains) do
    if #chain == 1 and chain[1].shouldRun == nil then
        __combinedEngineHandlers[handlerName] = chain[1].handler
    elseif handlerName == "onUpdate" and #chain > 0 then
        -- OpenMW can call PLAYER onUpdate frequently. Most basepack update
        -- predicates are dormant in normal play, so dormant predicates are
        -- polled at a short interval; once active, they are checked and
        -- dispatched every update until they report idle again.
        __combinedEngineHandlers[handlerName] = makeCombinedOnUpdate(chain)
    elseif handlerName == "onFrame" and #chain > 0 then
        -- OpenMW calls PLAYER onFrame every rendered frame. Most basepack frame
        -- handlers are dormant fallback windows, so avoid re-running every idle
        -- predicate every frame; once a predicate becomes active it is checked and
        -- dispatched every frame until it reports idle again.
        __combinedEngineHandlers[handlerName] = makeCombinedOnFrame(chain)
    elseif #chain > 0 then
        __combinedEngineHandlers[handlerName] = function(...)
            local saveData = nil
            for index = 1, #chain do
                local entry = chain[index]
                if type(entry.shouldRun) ~= "function" or entry.shouldRun(...) then
                    local result = entry.handler(...)
                    if handlerName == "onSave" and result ~= nil then
                        if saveData == nil then saveData = {} end
                        if type(result) == "table" then
                            for key, value in pairs(result) do
                                saveData[key] = value
                            end
                        end
                    end
                end
            end
            if handlerName == "onSave" then
                return saveData
            end
        end
    end
end

local __combinedInterfaceName = nil
local __combinedInterface = nil
for _, subsystem in ipairs(__basepack_subsystems) do
    -- Preserve the PLAYER-side Combat interface override from the former block runtime.
    -- Other former PLAYER runtime interfaces in this base pack are not referenced by
    -- the repository and cannot be exported simultaneously by one OpenMW script.
    if subsystem.interfaceName == "Combat" and type(subsystem.interface) == "table" then
        __combinedInterfaceName = subsystem.interfaceName
        __combinedInterface = subsystem.interface
        break
    end
end

local __result = {
    eventHandlers = __combinedEventHandlers,
    engineHandlers = __combinedEngineHandlers,
}
if __combinedInterfaceName ~= nil then
    __result.interfaceName = __combinedInterfaceName
    __result.interface = __combinedInterface
end

return __result
