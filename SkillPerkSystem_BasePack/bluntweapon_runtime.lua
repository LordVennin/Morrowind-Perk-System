-- Superseded by scripts/SkillPerkSystem_BasePack/basepack_player.lua; kept temporarily for save/development compatibility.
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local STRENGTH_IN_ARMS_PERK_ID = "bluntweapon_strength_in_arms"
local PLATEBREAKER_PERK_ID = "bluntweapon_platebreaker"
local BREATHSTEALER_PERK_ID = "bluntweapon_breathstealer"
local STATE_EVENT = "SkillPerkSystem_BluntWeaponStrengthInArmsState"
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

local function getStrengthDamageBonus()
    local attributes = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.attributes or nil
    local strengthAccessor = attributes ~= nil and attributes.strength or nil
    if type(strengthAccessor) ~= "function" then
        return 0
    end

    local stat = strengthAccessor(pself)
    local strength = stat ~= nil and tonumber(stat.modified) or nil
    if strength == nil then
        strength = stat ~= nil and tonumber(stat.base) or 0
    end

    return math.max(0, math.floor(strength / 10))
end

local function publishState(force)
    local strengthInArmsEnabled = hasEnabledPerk(STRENGTH_IN_ARMS_PERK_ID)
    local damageBonus = strengthInArmsEnabled and getStrengthDamageBonus() or 0
    local platebreakerEnabled = hasEnabledPerk(PLATEBREAKER_PERK_ID)
    local breathstealerEnabled = hasEnabledPerk(BREATHSTEALER_PERK_ID)
    local stateKey = tostring(strengthInArmsEnabled)
        .. ":"
        .. tostring(damageBonus)
        .. ":"
        .. tostring(platebreakerEnabled)
        .. ":"
        .. tostring(breathstealerEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        playerId = pself.id,
        strengthInArmsEnabled = strengthInArmsEnabled,
        enabled = strengthInArmsEnabled,
        damageBonus = damageBonus,
        platebreakerEnabled = platebreakerEnabled,
        breathstealerEnabled = breathstealerEnabled,
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
