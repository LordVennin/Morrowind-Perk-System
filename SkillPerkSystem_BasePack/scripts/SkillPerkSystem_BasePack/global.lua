local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local types = require("openmw.types")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"
local DRAIN_LOCKPICK_EVENT = "DrainLockpick"
local TUMBLER_SENSE_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local TUMBLER_SENSE_FAILURE_SOURCE = "drain_lockpick_event"

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

local function writeToolCondition(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil then
        return
    end
    local slot = data.slot
    if slot == nil then
        slot = types.Actor.EQUIPMENT_SLOT.CarriedRight
    end

    local tool = types.Actor.getEquipment(player, slot)
    local toolType = classifySecurityTool(tool)
    if toolType == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no security tool resolved) slot=%s player=%s amount=%s",
            tostring(slot),
            tostring(player),
            tostring(data.amount)
        ))
        return
    end

    local amount = tonumber(data.amount) or 0
    if amount == 0 then
        return
    end

    local itemData = types.Item.itemData(tool)
    if itemData == nil or type(itemData.condition) ~= "number" then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no numeric itemData.condition) slot=%s type=%s amount=%s",
            tostring(slot),
            tostring(toolType),
            tostring(amount)
        ))
        return
    end

    local currentCondition = itemData.condition
    local newCondition = currentCondition + amount

    if newCondition <= 0 then
        tool:remove()
        return
    end

    types.Item.itemData(tool).condition = newCondition
end

local function inferProbeFromItem(item)
    if item == nil then
        return nil
    end

    if types.Probe.objectIsInstance(item) then
        return true
    end

    if types.Lockpick.objectIsInstance(item) then
        return false
    end

    return nil
end

local function inferProbeFromEquipment(player)
    if player == nil or types.Actor == nil or type(types.Actor.getEquipment) ~= "function" then
        return false
    end

    local slots = types.Actor.EQUIPMENT_SLOT or {}
    local rightSlot = slots.CarriedRight
    if rightSlot ~= nil then
        local rightItem = types.Actor.getEquipment(player, rightSlot)
        local probe = inferProbeFromItem(rightItem)
        if probe ~= nil then
            return probe
        end
    end

    local leftSlot = slots.CarriedLeft
    if leftSlot ~= nil then
        local leftItem = types.Actor.getEquipment(player, leftSlot)
        local probe = inferProbeFromItem(leftItem)
        if probe ~= nil then
            return probe
        end
    end

    return false
end

local function normalizeFailureProbe(data)
    if type(data) == "table" and type(data.probe) == "boolean" then
        return data.probe
    end

    if type(data) == "table" then
        local probeFromItem = inferProbeFromItem(data.item)
        if probeFromItem ~= nil then
            return probeFromItem
        end

        return inferProbeFromEquipment(data.player)
    end

    return false
end

local function forwardTumblerSenseFailure(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    local probe = normalizeFailureProbe(data)
    player:sendEvent(TUMBLER_SENSE_FAILURE_EVENT, {
        source = TUMBLER_SENSE_FAILURE_SOURCE,
        probe = probe,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSenseBridge] forwarded failure source=%s mode=%s",
        TUMBLER_SENSE_FAILURE_SOURCE,
        probe and "probe" or "lockpick"
    ))
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
        [DRAIN_LOCKPICK_EVENT] = forwardTumblerSenseFailure,
    },
}
