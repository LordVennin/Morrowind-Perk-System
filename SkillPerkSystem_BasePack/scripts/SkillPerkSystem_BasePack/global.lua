local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local core = require("openmw.core")
local storage = require("openmw.storage")
local types = require("openmw.types")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"
local TUMBLER_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local TUMBLER_REFRESH_CHANCE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_RefreshChance"

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local TUMBLER_ENABLED_KEY = "security.tumbler_sense.enabled"
local TUMBLER_ACTIVE_BONUS_KEY = "security.tumbler_sense.active_bonus"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)

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
            "[SkillPerkSystem_BasePack][SteadyHands] refund skipped (no security tool resolved) slot=%s player=%s amount=%s",
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
            "[SkillPerkSystem_BasePack][SteadyHands] refund skipped (no numeric itemData.condition) slot=%s type=%s amount=%s",
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

local function resolveLockpick(actor)
    if actor == nil then
        return nil
    end

    local slot = types.Actor.EQUIPMENT_SLOT.CarriedRight
    local equipped = types.Actor.getEquipment(actor, slot)
    if equipped ~= nil and types.Lockpick.objectIsInstance(equipped) then
        return equipped
    end
    return nil
end

local function maybeApplyTumblerSenseBonus(target, actor)
    if target == nil or actor == nil then
        return
    end
    if not types.Player.objectIsInstance(actor) then
        return
    end
    if not types.Lockable.objectIsInstance(target) then
        return
    end
    if not types.Lockable.isLocked(target) then
        return
    end

    local lockpick = resolveLockpick(actor)
    if lockpick == nil then
        return
    end

    local enabled = effectsSection:get(TUMBLER_ENABLED_KEY) == true
    local bonus = tonumber(effectsSection:get(TUMBLER_ACTIVE_BONUS_KEY)) or 0.0
    if not enabled or bonus <= 0 then
        return
    end

    core.sendGlobalEvent(TUMBLER_FAILURE_EVENT, {
        source = "onActivate-lockpick-failed",
        probe = false,
    })
    core.sendGlobalEvent(TUMBLER_REFRESH_CHANCE_EVENT, {
        source = "onActivate-lockpick-failed",
        probe = false,
    })

    local finalBonus = tonumber(effectsSection:get(TUMBLER_ACTIVE_BONUS_KEY)) or bonus
    if math.random() < finalBonus then
        types.Lockable.unlock(target)
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] lockpick rescue success source=onActivate-roll bonus=%.2f",
            finalBonus
        ))
        return
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] lockpick rescue miss source=onActivate-roll bonus=%.2f",
        finalBonus
    ))
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    engineHandlers = {
        onActivate = maybeApplyTumblerSenseBonus,
    },
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
    },
}
