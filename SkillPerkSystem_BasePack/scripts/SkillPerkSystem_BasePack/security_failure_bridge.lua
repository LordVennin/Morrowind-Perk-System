local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")

local FORWARD_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local BRIDGE_INTERFACE_NAME = "SkillPerkSystem_BasePack_SecurityFailureBridge"
local SOURCE = "drain_lockpick_event"

local EQUIPMENT_SLOT = types.Actor.EQUIPMENT_SLOT or {}

local tracked = {
    item = nil,
    slot = nil,
    condition = nil,
    probe = false,
}

local function getCondition(item)
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

    return nil
end

local function getEquippedSecurityTool()
    local right = types.Actor.getEquipment(pself, EQUIPMENT_SLOT.CarriedRight)
    if right ~= nil then
        if types.Lockpick.objectIsInstance(right) then
            return right, EQUIPMENT_SLOT.CarriedRight, false
        end
        if types.Probe.objectIsInstance(right) then
            return right, EQUIPMENT_SLOT.CarriedRight, true
        end
    end

    local left = types.Actor.getEquipment(pself, EQUIPMENT_SLOT.CarriedLeft)
    if left ~= nil then
        if types.Lockpick.objectIsInstance(left) then
            return left, EQUIPMENT_SLOT.CarriedLeft, false
        end
        if types.Probe.objectIsInstance(left) then
            return left, EQUIPMENT_SLOT.CarriedLeft, true
        end
    end

    return nil, nil, false
end

local function emitFailure(isProbe)
    core.sendGlobalEvent(FORWARD_FAILURE_EVENT, {
        source = SOURCE,
        probe = isProbe == true,
    })
end

local function onUpdate()
    local item, slot, isProbe = getEquippedSecurityTool()
    local condition = getCondition(item)

    local sameTool = tracked.item ~= nil and tracked.item == item and tracked.slot == slot
    if sameTool and type(tracked.condition) == "number" and type(condition) == "number" and condition < tracked.condition then
        local pointsLost = math.floor(tracked.condition - condition)
        if pointsLost < 1 then
            pointsLost = 1
        end

        for _ = 1, pointsLost do
            emitFailure(isProbe)
        end

        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSenseBridge] durability drop detected before=%d after=%d emitted=%d",
            tracked.condition,
            condition,
            pointsLost
        ))
    end

    tracked.item = item
    tracked.slot = slot
    tracked.condition = condition
    tracked.probe = isProbe
end

local function findTrackedSecurityTool()
    for _, slotInfo in ipairs(TRACKED_SLOTS) do
        if slotInfo.slot ~= nil then
            local item = types.Actor.getEquipment(pself, slotInfo.slot)
            local toolType = classifySecurityTool(item)
            if toolType ~= nil then
                return {
                    item = item,
                    slot = slotInfo.slot,
                    slotName = slotInfo.label,
                    toolType = toolType,
                    condition = itemCondition(item),
                }
            end
        end
    end

    return nil
end

local function sameTool(previousState, currentState)
    if previousState == nil or currentState == nil then
        return false
    end

    return previousState.item == currentState.item and previousState.slot == currentState.slot
end

local function onUpdate()
    local currentState = findTrackedSecurityTool()
    local previousState = trackedToolState

    if previousState ~= nil and currentState ~= nil and sameTool(previousState, currentState) then
        local oldCondition = previousState.condition
        local newCondition = currentState.condition

        if type(oldCondition) == "number" and type(newCondition) == "number" and newCondition < oldCondition then
            local loss = math.floor(oldCondition - newCondition)
            if loss < 1 then
                loss = 1
            end

            for _ = 1, loss do
                emitFailure({
                    source = DEFAULT_SOURCE,
                    probe = currentState.toolType == "probe",
                })
            end

            print(string.format(
                "[SkillPerkSystem_BasePack][TumblerSenseBridge] fallback condition drain detected slot=%s type=%s before=%d after=%d emitted=%d",
                tostring(currentState.slotName),
                tostring(currentState.toolType),
                oldCondition,
                newCondition,
                loss
            ))
        end
    end

    trackedToolState = currentState
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
