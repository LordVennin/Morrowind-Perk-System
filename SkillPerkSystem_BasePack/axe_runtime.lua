local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BLOODLETTER_PERK_ID = "axe_bloodletter"
local DRAGGING_WOUND_PERK_ID = "axe_dragging_wound"
local HEWER_HEART_PERK_ID = "axe_hewer_heart"
local CRIMSON_CLEAVE_PERK_ID = "axe_crimson_cleave"
local IRON_CANOPY_PERK_ID = "axe_iron_canopy"
local EXECUTION_DAMAGE_PERK_IDS = {
    "axe_kindling_grip",
    "axe_crescent_hook",
}
local STATE_EVENT = "SkillPerkSystem_AxeKindlingGripState"
local STATE_REFRESH_INTERVAL = 1.0

local refreshTimer = STATE_REFRESH_INTERVAL
local lastStateKey = nil

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
    local bloodletterEnabled = hasEnabledPerk(BLOODLETTER_PERK_ID)
    local draggingWoundEnabled = hasEnabledPerk(DRAGGING_WOUND_PERK_ID)
    local hewerHeartEnabled = hasEnabledPerk(HEWER_HEART_PERK_ID)
    local crimsonCleaveEnabled = hasEnabledPerk(CRIMSON_CLEAVE_PERK_ID)
    local ironCanopyEnabled = hasEnabledPerk(IRON_CANOPY_PERK_ID)
    local stateKey = tostring(enabledCount) .. ":" .. tostring(bloodletterEnabled) .. ":" .. tostring(draggingWoundEnabled) .. ":" .. tostring(hewerHeartEnabled) .. ":" .. tostring(crimsonCleaveEnabled) .. ":" .. tostring(ironCanopyEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        enabled = enabledCount > 0,
        damageBonusCount = enabledCount,
        bloodletterEnabled = bloodletterEnabled,
        draggingWoundEnabled = draggingWoundEnabled,
        hewerHeartEnabled = hewerHeartEnabled,
        crimsonCleaveEnabled = crimsonCleaveEnabled,
        ironCanopyEnabled = ironCanopyEnabled,
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
            lastStateKey = nil
            publishState(true)
        end,
    },
}
