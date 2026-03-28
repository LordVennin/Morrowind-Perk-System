local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"

local function setLuckyFindEnabled(enable)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
    })
end

return {
    id = "security_lucky_find_effect",
    name = "Lucky Find",
    description = "First checks on containers have a small chance to hide a Lucky Coin. Each Lucky Coin carried grants +1 Luck.",
    onAcquire = function(_context)
        setLuckyFindEnabled(true)
    end,
    onRemove = function(_context)
        setLuckyFindEnabled(false)
    end,
}
