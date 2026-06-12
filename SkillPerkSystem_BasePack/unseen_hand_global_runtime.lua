local world = require("openmw.world")

local PLAYER_TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle"

local function forwardToPlayer(data)
    local player = world.players[1]
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    player:sendEvent(PLAYER_TOGGLE_EVENT, data)
end

return {
    eventHandlers = {
        [PLAYER_TOGGLE_EVENT] = function(data)
            if type(data) ~= "table" then
                return
            end

            forwardToPlayer({
                enable = data.enable == true,
            })
        end,
    },
}
