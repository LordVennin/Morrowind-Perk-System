local storage = require("openmw.storage")

local EFFECTS_SECTION = storage.playerSection("SkillPerkSystem_BasePack_Effects")
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local NO_CONSUME_CHANCE = 0.15

local function applySteadyHandsState()
    EFFECTS_SECTION:set(ENABLED_KEY, true)
    EFFECTS_SECTION:set(NO_CONSUME_CHANCE_KEY, NO_CONSUME_CHANCE)
end

local function clearSteadyHandsState()
    EFFECTS_SECTION:set(ENABLED_KEY, false)
    EFFECTS_SECTION:set(NO_CONSUME_CHANCE_KEY, 0.0)
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "Adds a 15% chance for lockpick/probe uses to not be consumed while enabled.",
    onAcquire = function(_context)
        applySteadyHandsState()
    end,
    onRemove = function(_context)
        clearSteadyHandsState()
    end,
}
