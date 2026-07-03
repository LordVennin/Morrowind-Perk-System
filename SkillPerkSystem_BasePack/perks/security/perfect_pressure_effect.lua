local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local BASE_BONUS_PER_FAILED_ATTEMPT = 1
local BASE_MAX_STACKS = 5
local BOOSTED_BONUS_PER_FAILED_ATTEMPT = 2
local BOOSTED_MAX_STACKS = 10
local INITIAL_STACKS = 0
local SHARED_DECAY_SECONDS = 10

local function sendTumblerSenseConfig(context, boosted)
    local payload = {
        enable = true,
        bonusPerFailedAttempt = boosted and BOOSTED_BONUS_PER_FAILED_ATTEMPT or BASE_BONUS_PER_FAILED_ATTEMPT,
        maxStacks = boosted and BOOSTED_MAX_STACKS or BASE_MAX_STACKS,
        initialStacks = INITIAL_STACKS,
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
    id = "security_perfect_pressure_effect",
    name = "Perfect Pressure",
    description = "Tumbler Sense now grants +2 Security per failed attempt and can stack up to +10 Security.",
    onAcquire = function(context)
        sendTumblerSenseConfig(context, true)
    end,
    onRemove = function(context)
        sendTumblerSenseConfig(context, false)
    end,
}
