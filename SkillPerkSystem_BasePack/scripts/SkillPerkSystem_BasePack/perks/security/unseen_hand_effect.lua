local core = require("openmw.core")

local PLAYER_TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle"

local function setEnabled(enable)
    core.sendGlobalEvent(PLAYER_TOGGLE_EVENT, {
        enable = enable == true,
    })
end

return {
    id = "security_unseen_hand_effect",
    name = "Burglar's Instinct",
    description = "While a lockpick or probe is equipped, gain Chameleon 15% and Sanctuary 15 pts.",
    onAcquire = function(_context)
        setEnabled(true)
    end,
    onRemove = function(_context)
        setEnabled(false)
    end,
}
