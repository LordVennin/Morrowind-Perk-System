local core = require("openmw.core")

local BONUS_PER_FAILED_ATTEMPT = 0.01
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
    description = "Starts at 1 stack (+1% lockpick chance). Failed lockpick attempts grant +1% lockpick chance per stack (max 5) with a shared 10s decay timer.",
    onAcquire = function(_context)
        setTumblerSenseEnabled(true)
    end,
    onRemove = function(_context)
        setTumblerSenseEnabled(false)
    end,
}
