local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"

local function setTreasureSenseEnabled(enable, context)
    local payload = {
        enable = enable == true,
    }

    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(TOGGLE_EVENT, payload)
        return
    end

    core.sendGlobalEvent(TOGGLE_EVENT, payload)
end

return {
    id = "security_treasure_sense_effect",
    name = "Treasure Sense",
    description = "First checks on chest-like containers can reveal extra hidden gold based on Luck.",
    onAcquire = function(context)
        setTreasureSenseEnabled(true, context)
    end,
    onRemove = function(context)
        setTreasureSenseEnabled(false, context)
    end,
}
