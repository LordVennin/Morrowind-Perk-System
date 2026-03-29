local core = require("openmw.core")
local config = require("scripts.SkillPerkSystem_BasePack.perks.security.tumbler_sense_config")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local function syncPerfectPressure(context)
    local payload = config.buildPayload()

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
        syncPerfectPressure(context)
    end,
    onRemove = function(context)
        syncPerfectPressure(context)
    end,
}
