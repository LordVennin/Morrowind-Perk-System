local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_Toggle"
local SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"

local function setUnseenHandEnabled(enable)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
        spellRecordId = SPELL_RECORD_ID,
    })
end

return {
    id = "security_unseen_hand_effect",
    name = "Burglar's Instinct",
    description = "While a lockpick or probe is equipped, gain Chameleon 15% and Sanctuary 15 pts.",
    onAcquire = function(_context)
        setUnseenHandEnabled(true)
    end,
    onRemove = function(_context)
        setUnseenHandEnabled(false)
    end,
}
