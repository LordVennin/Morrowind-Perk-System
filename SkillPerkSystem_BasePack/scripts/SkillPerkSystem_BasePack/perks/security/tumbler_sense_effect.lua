local core = require("openmw.core")

local BONUS_PER_FAILED_ATTEMPT = 0.01
local MAX_STACKS = 5
local SHARED_DECAY_SECONDS = 10
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local function setTumblerSenseEnabled(enable, context)
    local payload = {
        enable = enable == true,
        bonusPerFailedAttempt = BONUS_PER_FAILED_ATTEMPT,
        maxStacks = MAX_STACKS,
        sharedDecaySeconds = SHARED_DECAY_SECONDS,
    }

    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        print(string.format(
            "[SkillPerkSystem_BasePack][TumblerSense] sending player toggle event enabled=%s bonusPerFailedAttempt=%.2f maxStacks=%d decaySeconds=%d",
            tostring(enable == true),
            BONUS_PER_FAILED_ATTEMPT,
            MAX_STACKS,
            SHARED_DECAY_SECONDS
        ))
        player:sendEvent(TOGGLE_EVENT, payload)
        return
    end

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSense] sending global toggle event enabled=%s bonusPerFailedAttempt=%.2f maxStacks=%d decaySeconds=%d reason=no-player-context",
        tostring(enable == true),
        BONUS_PER_FAILED_ATTEMPT,
        MAX_STACKS,
        SHARED_DECAY_SECONDS
    ))
    core.sendGlobalEvent(TOGGLE_EVENT, payload)
end

return {
    id = "security_tumbler_sense_effect",
    name = "Tumbler Sense",
    description = "Starts at 1 stack (+1 Security). Failed lockpick attempts grant +1 Security per stack (max 5) with a shared 10s decay timer.",
    onAcquire = function(context)
        print("[SkillPerkSystem_BasePack][TumblerSense] onAcquire called")
        setTumblerSenseEnabled(true, context)
    end,
    onRemove = function(context)
        print("[SkillPerkSystem_BasePack][TumblerSense] onRemove called")
        setTumblerSenseEnabled(false, context)
    end,
}
