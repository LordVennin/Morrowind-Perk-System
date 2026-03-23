local core = require("openmw.core")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local DEFAULT_NO_CONSUME_CHANCE = 0.15
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_SteadyHands_Toggle"
local TOOL_DRAIN_EVENT = "SkillPerkSystem_BasePack_SteadyHands_ToolDrain"

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

local trackedToolState = nil
local conditionDebugFramesRemaining = 1
local conditionSourceDebugFramesRemaining = 60
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
    return effectsSection:get(ENABLED_KEY) == true
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

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands][debug] frame compare iteratedCondition=%s iteratedSlot=%s explicitCarriedRightCondition=%s",
        tostring(iteratedState ~= nil and iteratedState.condition or nil),
        tostring(iteratedState ~= nil and slotLabel(iteratedState.slot, iteratedState.slotName) or nil),
        tostring(itemCondition(carriedRight))
    ))

    conditionDebugFramesRemaining = conditionDebugFramesRemaining - 1
    if conditionDebugFramesRemaining == 0 then
        print("[SkillPerkSystem_BasePack][SteadyHands][debug] condition comparison diagnostics complete; disabling debug output")
    end
end

local function logConditionSourceDebugForFrame(iteratedState)
    if conditionSourceDebugFramesRemaining <= 0 then
        return
    end

    local debugInfo = iteratedState ~= nil and iteratedState.conditionDebug or nil
    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands][debug] condition source rawCondition=%s maxConditionFallback=%s effectiveCondition=%s recordId=%s toolType=%s",
        tostring(debugInfo ~= nil and debugInfo.rawCondition or nil),
        tostring(debugInfo ~= nil and debugInfo.maxConditionFallback or nil),
        tostring(debugInfo ~= nil and debugInfo.effectiveCondition or nil),
        tostring(debugInfo ~= nil and debugInfo.recordId or nil),
        tostring(debugInfo ~= nil and debugInfo.toolType or nil)
    ))

    conditionSourceDebugFramesRemaining = conditionSourceDebugFramesRemaining - 1
    if conditionSourceDebugFramesRemaining == 0 then
        print("[SkillPerkSystem_BasePack][SteadyHands][debug] condition source diagnostics complete; disabling debug output")
    end
end

local function sameItem(a, b)
    if a == nil or b == nil then
        return false
    end
    return a.item == b.item and a.slot == b.slot
end

local function slotLabel(slot, slotName)
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
        print("[SkillPerkSystem_BasePack][SteadyHands] " .. prefix .. " no equipped lockpick/probe detected")
        return
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] %s slot=%s type=%s condition=%s",
        prefix,
        slotLabel(state.slot, state.slotName),
        tostring(state.toolType),
        tostring(state.condition)
    ))
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
        print(string.format("[SkillPerkSystem_BasePack][SteadyHands] perk disabled; skipping refund roll (%s)", tostring(contextLabel)))
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

    print(string.format(
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

    core.sendGlobalEvent("ModifyItemCondition", {
        actor = pself,
        item = toolState.item,
        amount = refundCount,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] refund fired source=%s slot=%s type=%s amount=%d",
        tostring(contextLabel),
        slotLabel(toolState.slot, toolState.slotName),
        tostring(toolType),
        refundCount
    ))
end

local function handleToolDrainEvent(data)
    if type(data) ~= "table" then
        return
    end

    local item = data.item
    local toolType = classifyTool(item)
    if toolType == nil then
        return
    end

    local toolState = {
        slot = data.slot,
        slotName = data.slotName,
        item = item,
        toolType = toolType,
        condition = itemCondition(item),
    }

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] tool drain event received slot=%s type=%s condition=%s",
        slotLabel(toolState.slot, toolState.slotName),
        tostring(toolType),
        tostring(toolState.condition)
    ))

    rollAndRefund(toolState, "event")
end

local function withLastComparableCondition(previousState, currentState)
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
        print(string.format(
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
    if previousState == nil or currentState == nil then
        return
    end
    if not sameItem(previousState, currentState) then
        return
    end

    local oldCondition = previousState.lastComparableCondition
    local newCondition = currentState.condition

    if type(oldCondition) == "number" and type(newCondition) ~= "number" then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] condition transitioned number->nil slot=%s type=%s previousCondition=%s",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            tostring(oldCondition)
        ))
        return
    end

    if type(oldCondition) ~= "number" and type(newCondition) == "number" then
        print(string.format(
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

    print(string.format(
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
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] multi-point drop detected source=onUpdate-fallback slot=%s type=%s delta=%d policy=per-point-with-cap cap=%d",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            spentPoints,
            MAX_CONDITION_ROLLS_PER_UPDATE
        ))
    elseif spentPoints > 1 then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands] multi-point drop detected source=onUpdate-fallback slot=%s type=%s delta=%d policy=per-point",
            slotLabel(currentState.slot, currentState.slotName),
            tostring(currentState.toolType),
            spentPoints
        ))
    end

    rollAndRefund(currentState, "onUpdate-fallback", rollAttempts)
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
    else
        effectsSection:set(NO_CONSUME_CHANCE_KEY, 0.0)
    end

    print(string.format("[SkillPerkSystem_BasePack] Steady Hands %s (chance=%.2f)", enabled and "enabled" or "disabled", effectsSection:get(NO_CONSUME_CHANCE_KEY) or 0.0))
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleSteadyHandsToggle,
        [TOOL_DRAIN_EVENT] = handleToolDrainEvent,
    },
}
