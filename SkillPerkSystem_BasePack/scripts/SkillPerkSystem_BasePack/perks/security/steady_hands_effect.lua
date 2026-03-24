local core = require("openmw.core")

local CONDITION_REFUND_CHANCE = 0.15
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_SteadyHands_Toggle"

local function setSteadyHandsEnabled(enable, chance)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
        chance = chance,
    })
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "While enabled, lockpick and probe uses have a 15% chance to not be consumed.",
    onAcquire = function(_context)
        setSteadyHandsEnabled(true, CONDITION_REFUND_CHANCE)
    end,
    onRemove = function(_context)
        setSteadyHandsEnabled(false, 0.0)
    end,
}
