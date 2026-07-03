local core = require("openmw.core")

local CONDITION_REFUND_CHANCE = 0.15
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_SteadyHands_Toggle"

local function setSteadyHandsEnabled(context, enable, chance)
    local payload = {
        enable = enable == true,
        chance = chance,
    }

    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(TOGGLE_EVENT, payload)
        return
    end

    core.sendGlobalEvent(TOGGLE_EVENT, payload)
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "While enabled, lockpick and probe uses have a 15% chance to not be consumed.",
    onAcquire = function(context)
        setSteadyHandsEnabled(context, true, CONDITION_REFUND_CHANCE)
    end,
    onRemove = function(context)
        setSteadyHandsEnabled(context, false, 0.0)
    end,
}
