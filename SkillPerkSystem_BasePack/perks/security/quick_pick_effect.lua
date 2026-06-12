local core = require("openmw.core")

local TOOL_SPEED_MULTIPLIER = 1.75
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_QuickPick_Toggle"

local function setQuickPickEnabled(enable, context)
    local payload = {
        enable = enable == true,
        toolSpeedMultiplier = TOOL_SPEED_MULTIPLIER,
    }

    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(TOGGLE_EVENT, payload)
        return
    end

    core.sendGlobalEvent(TOGGLE_EVENT, payload)
end

return {
    id = "security_quick_pick_effect",
    name = "Quick Pick",
    description = "Increases lockpick and probe animation speed by 75% while a security tool is equipped.",
    onAcquire = function(context)
        setQuickPickEnabled(true, context)
    end,
    onRemove = function(context)
        setQuickPickEnabled(false, context)
    end,
}
