local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"

local function setTreasureSenseEnabled(enable)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
    })
end

return {
    id = "security_treasure_sense_effect",
    name = "Treasure Sense",
    description = "First checks on chest-like containers can reveal extra hidden gold based on Luck.",
    onAcquire = function(_context)
        setTreasureSenseEnabled(true)
    end,
    onRemove = function(_context)
        setTreasureSenseEnabled(false)
    end,
}
