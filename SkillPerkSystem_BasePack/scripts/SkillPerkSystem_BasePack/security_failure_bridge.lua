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

return {
    interfaceName = BRIDGE_INTERFACE_NAME,
    interface = {
        emitFailure = emitFailure,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
