local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local KINDLING_GRIP_PERK_ID = "axe_kindling_grip"
local STATE_EVENT = "SkillPerkSystem_AxeKindlingGripState"
local STATE_REFRESH_INTERVAL = 1.0

local refreshTimer = STATE_REFRESH_INTERVAL
local lastEnabled = nil

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function kindlingGripEnabled()
    return hasEnabledPerk(KINDLING_GRIP_PERK_ID)
end

local function publishState(force)
    local enabled = kindlingGripEnabled()
    if not force and enabled == lastEnabled then
        return
    end

    lastEnabled = enabled
    core.sendGlobalEvent(STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        enabled = enabled,
    })
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            refreshTimer = refreshTimer + (tonumber(dt) or 0)
            if refreshTimer >= STATE_REFRESH_INTERVAL then
                refreshTimer = 0
                publishState(false)
            end
        end,
        onLoad = function()
            refreshTimer = STATE_REFRESH_INTERVAL
            lastEnabled = nil
            publishState(true)
        end,
    },
}
