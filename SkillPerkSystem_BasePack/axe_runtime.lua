local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local EXECUTION_DAMAGE_PERK_IDS = {
    "axe_kindling_grip",
    "axe_crescent_hook",
}
local STATE_EVENT = "SkillPerkSystem_AxeKindlingGripState"
local STATE_REFRESH_INTERVAL = 1.0

local refreshTimer = STATE_REFRESH_INTERVAL
local lastEnabledCount = nil

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

local function executionDamagePerkCount()
    local count = 0
    for _, perkID in ipairs(EXECUTION_DAMAGE_PERK_IDS) do
        if hasEnabledPerk(perkID) then
            count = count + 1
        end
    end
    return count
end

local function publishState(force)
    local enabledCount = executionDamagePerkCount()
    if not force and enabledCount == lastEnabledCount then
        return
    end

    lastEnabledCount = enabledCount
    core.sendGlobalEvent(STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        enabled = enabledCount > 0,
        damageBonusCount = enabledCount,
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
            lastEnabledCount = nil
            publishState(true)
        end,
    },
}
