local core = require("openmw.core")
local types = require("openmw.types")

local DRAIN_LOCKPICK_EVENT = "DrainLockpick"
local FORWARD_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local BRIDGE_INTERFACE_NAME = "SkillPerkSystem_BasePack_SecurityFailureBridge"
local DEFAULT_SOURCE = "drain_lockpick_event"

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

return {
    interfaceName = BRIDGE_INTERFACE_NAME,
    interface = {
        emitFailure = emitFailure,
    },
    eventHandlers = {
        [DRAIN_LOCKPICK_EVENT] = onDrainLockpick,
    },
}
