local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")

local FORWARD_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local BRIDGE_INTERFACE_NAME = "SkillPerkSystem_BasePack_SecurityFailureBridge"
local SOURCE = "drain_lockpick_event"

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

local trackedToolState = nil

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

local function toolMaxCondition(item)
    if item == nil then
        return nil
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local recordTable = nil
    if types.Lockpick.objectIsInstance(item) and type(types.Lockpick.records) == "table" then
        recordTable = types.Lockpick.records
    elseif types.Probe.objectIsInstance(item) and type(types.Probe.records) == "table" then
        recordTable = types.Probe.records
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
    if types.Actor == nil or type(types.Actor.getEquipment) ~= "function" then
        return nil
    end

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
        local item = getEquippedItem(slotInfo.slot)
        local toolType = classifyTool(item)
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

local function emitFailure(isProbe)
    core.sendGlobalEvent(FORWARD_FAILURE_EVENT, {
        source = SOURCE,
        probe = isProbe == true,
    })
end

local function emitFailuresForToolUse(previousState, currentState)
    if previousState == nil or currentState == nil then
        return
    end

    if not sameItem(previousState, currentState) then
        return
    end

    local oldCondition = previousState.lastComparableCondition
    local newCondition = currentState.condition
    if type(oldCondition) ~= "number" or type(newCondition) ~= "number" then
        return
    end

    if newCondition >= oldCondition then
        return
    end

    local spentPoints = math.floor(oldCondition - newCondition)
    if spentPoints < 1 then
        spentPoints = 1
    end

    for _ = 1, spentPoints do
        emitFailure(currentState.toolType == "Probe")
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSenseBridge] tool use detected slot=%s type=%s conditionBefore=%d conditionAfter=%d emitted=%d",
        tostring(currentState.slotName),
        tostring(currentState.toolType),
        oldCondition,
        newCondition,
        spentPoints
    ))
end

local function onUpdate()
    local currentState = findEquippedSecurityTool()
    local previousState = trackedToolState
    local normalizedCurrentState = withLastComparableCondition(previousState, currentState)

    emitFailuresForToolUse(previousState, normalizedCurrentState)
    trackedToolState = normalizedCurrentState
end

return {
    interfaceName = BRIDGE_INTERFACE_NAME,
    interface = {
        emitFailure = emitFailure,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
