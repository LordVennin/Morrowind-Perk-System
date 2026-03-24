local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local types = require("openmw.types")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"

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

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
    },
}
