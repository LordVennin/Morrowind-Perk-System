local core = require("openmw.core")

-- TEMP TEST TUNING:
-- Raised from 0.02 (2%) to 0.20 (20%) per stack so in-game verification is obvious.
local BONUS_PER_FAILED_ATTEMPT = 0.20
local MAX_STACKS = 5
local SHARED_DECAY_SECONDS = 10
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local function setTumblerSenseEnabled(enable)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
        bonusPerFailedAttempt = BONUS_PER_FAILED_ATTEMPT,
        maxStacks = MAX_STACKS,
        sharedDecaySeconds = SHARED_DECAY_SECONDS,
    })
end

return {
    id = "security_tumbler_sense_effect",
    name = "Tumbler Sense",
    description = "TEMP TEST: Failed lockpick attempts grant +20% lockpick chance per stack (max 5) with a shared 10s decay timer.",
    onAcquire = function(_context)
        setTumblerSenseEnabled(true)
    end,
    onRemove = function(_context)
        setTumblerSenseEnabled(false)
    end,
}
