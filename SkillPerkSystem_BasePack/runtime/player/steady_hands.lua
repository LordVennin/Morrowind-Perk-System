-- Steady Hands player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_subsystem_result = nil

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

__basepack_subsystem_result = {
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


return __basepack_subsystem_result
