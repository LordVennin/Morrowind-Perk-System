local storage = require("openmw.storage")

local EFFECTS_SECTION = storage.playerSection("SkillPerkSystem_BasePack_Effects")
local ENABLED_KEY = "security.steady_hands.enabled"
local DURABILITY_MULTIPLIER_KEY = "security.steady_hands.durability_multiplier"
local DURABILITY_MULTIPLIER = 0.75

local function applySteadyHandsState()
    EFFECTS_SECTION:set(ENABLED_KEY, true)
    EFFECTS_SECTION:set(DURABILITY_MULTIPLIER_KEY, DURABILITY_MULTIPLIER)
end

local function clearSteadyHandsState()
    EFFECTS_SECTION:set(ENABLED_KEY, false)
    EFFECTS_SECTION:set(DURABILITY_MULTIPLIER_KEY, 1.0)
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "Reduces lockpick/probe durability loss while the perk effect is enabled.",
    onAcquire = function(_context)
        applySteadyHandsState()
    end,
    onRemove = function(_context)
        clearSteadyHandsState()
    end,
}
