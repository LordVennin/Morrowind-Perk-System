local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")

local DRAIN_LOCKPICK_EVENT = "DrainLockpick"
local FORWARD_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local BRIDGE_INTERFACE_NAME = "SkillPerkSystem_BasePack_SecurityFailureBridge"
local DEFAULT_SOURCE = "drain_lockpick_event"

local EQUIPMENT_SLOT = types.Actor.EQUIPMENT_SLOT or {}
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

local function classifySecurityTool(item)
    if item == nil then
        return nil
    end

    if types.Lockpick.objectIsInstance(item) then
        return "lockpick"
    end

    if types.Probe.objectIsInstance(item) then
        return "probe"
    end

    return nil
end

local function itemCondition(item)
    if item == nil then
        return nil
    end

    local itemData = types.Item.itemData(item)
    if itemData ~= nil and type(itemData.condition) == "number" then
        return itemData.condition
    end

    return nil
end

local function inferProbeFromEquipment(player)
    if player == nil then
        return false
    end

    local equipped = types.Actor.getEquipment(player, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if equipped == nil then
        return false
    end

    return types.Probe.objectIsInstance(equipped) == true
end

local function normalizeSource(data)
    if type(data) == "table" and type(data.source) == "string" and data.source ~= "" then
        return data.source
    end
    return DEFAULT_SOURCE
end

local function normalizeProbe(data)
    if type(data) == "table" and type(data.probe) == "boolean" then
        return data.probe
    end

    if type(data) == "table" then
        return inferProbeFromEquipment(data.player)
    end

    return false
end

local function emitFailure(data)
    local source = normalizeSource(data)
    local probe = normalizeProbe(data)

    core.sendGlobalEvent(FORWARD_FAILURE_EVENT, {
        source = source,
        probe = probe,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSenseBridge] forwarded failure source=%s mode=%s",
        tostring(source),
        probe and "probe" or "lockpick"
    ))
end

local function onDrainLockpick(data)
    emitFailure(data)
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
    eventHandlers = {
        [DRAIN_LOCKPICK_EVENT] = onDrainLockpick,
    },
}
