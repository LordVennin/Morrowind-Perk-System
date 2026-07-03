local core = require("openmw.core")
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local BASE_BONUS_PER_FAILED_ATTEMPT = 1
local BASE_MAX_STACKS = 5
local BASE_INITIAL_STACKS = 0
local SHARED_DECAY_SECONDS = 10

local function syncTumblerSense(context, enable)
    local payload = {
        enable = enable == true,
        bonusPerFailedAttempt = BASE_BONUS_PER_FAILED_ATTEMPT,
        maxStacks = BASE_MAX_STACKS,
        initialStacks = BASE_INITIAL_STACKS,
        sharedDecaySeconds = SHARED_DECAY_SECONDS,
    }

    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(TOGGLE_EVENT, payload)
        return
    end

    core.sendGlobalEvent(TOGGLE_EVENT, payload)
end

return {
    id = "security_tumbler_sense_effect",
    name = "Tumbler Sense",
    description = "Starts at 0 stacks. Failed lockpick attempts grant +1 Security per stack (max 5) with a shared 10s decay timer.",
    onAcquire = function(context)
        syncTumblerSense(context, true)
    end,
    onRemove = function(context)
        syncTumblerSense(context, false)
    end,
}
