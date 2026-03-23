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

    if type(item.type) == "table" and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and type(data) == "table" then
            return data
        end
    end

    if types.Item ~= nil and type(types.Item.itemData) == "function" then
        local ok, data = pcall(types.Item.itemData, item)
        if ok and type(data) == "table" then
            return data
        end
    end

    if item.type ~= nil and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and type(data) == "table" then
            return data
        end
    end

    if type(item.itemData) == "table" then
        return item.itemData
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

    local record = nil
    if types.Lockpick.objectIsInstance(item) then
        local records = types.Lockpick.records
        if type(records) == "table" then
            record = records[recordId]
        end
    elseif types.Probe.objectIsInstance(item) then
        local records = types.Probe.records
        if type(records) == "table" then
            record = records[recordId]
        end
    end

    if type(record) == "table" and type(record.maxCondition) == "number" then
        return record.maxCondition
    end

    return nil
end

local function itemCondition(item)
    local data = itemData(item)
    if type(data) == "table" then
        local condition = data.condition
        if type(condition) == "number" then
            return condition
        end
    end

    return toolMaxCondition(item)
end

local function findEquippedSecurityTool()
    local equipment = types.Actor.getEquipment(pself)
    for slot, item in pairs(equipment) do
        local toolType = classifyTool(item)
        if toolType ~= nil then
            return {
                slot = slot,
                item = item,
                toolType = toolType,
                condition = itemCondition(item),
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

local function slotLabel(slot)
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
        slotLabel(state.slot),
        tostring(state.toolType),
        tostring(state.condition)
    ))
end

local function rollAndRefund(toolState, contextLabel)
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

    local chance = steadyHandsNoConsumeChance()
    local proc = math.random() < chance

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] refund roll source=%s slot=%s type=%s chance=%.2f result=%s",
        tostring(contextLabel),
        slotLabel(toolState.slot),
        tostring(toolType),
        chance,
        proc and "PROC" or "NO_PROC"
    ))

    if not proc then
        return
    end

    core.sendGlobalEvent("ModifyItemCondition", {
        actor = pself,
        item = toolState.item,
        amount = 1,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] refund fired source=%s slot=%s type=%s amount=1",
        tostring(contextLabel),
        slotLabel(toolState.slot),
        tostring(toolType)
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
        item = item,
        toolType = toolType,
        condition = itemCondition(item),
    }

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] tool drain event received slot=%s type=%s condition=%s",
        slotLabel(toolState.slot),
        tostring(toolType),
        tostring(toolState.condition)
    ))

    rollAndRefund(toolState, "event")
end

local function maybeRefundCondition(previousState, currentState)
    if previousState == nil or currentState == nil then
        return
    end
    if not sameItem(previousState, currentState) then
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

    print(string.format(
        "[SkillPerkSystem_BasePack][SteadyHands] tool use detected slot=%s type=%s conditionBefore=%d conditionAfter=%d",
        slotLabel(currentState.slot),
        tostring(currentState.toolType),
        oldCondition,
        newCondition
    ))

    rollAndRefund(currentState, "onUpdate-fallback")
end

local function onUpdate()
    local currentState = findEquippedSecurityTool()

    if trackedToolState == nil and currentState ~= nil then
        logToolState("tracking started", currentState)
    elseif trackedToolState ~= nil and currentState == nil then
        logToolState("tracking stopped", nil)
    elseif trackedToolState ~= nil and currentState ~= nil and not sameItem(trackedToolState, currentState) then
        logToolState("tracking switched", currentState)
    end

    maybeRefundCondition(trackedToolState, currentState)
    trackedToolState = currentState
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
