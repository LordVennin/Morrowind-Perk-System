local core = require("openmw.core")
local config = require("scripts.SkillPerkSystem_BasePack.perks.security.tumbler_sense_config")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local function syncTumblerSense(context)
    local payload = config.buildPayload()

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
        syncTumblerSense(context)
    end,
    onRemove = function(context)
        syncTumblerSense(context)
    end,
}
