local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/bluntweapon_target.lua"
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local strengthInArmsState = {
    enabled = false,
    damageBonus = 0,
    playerId = nil,
}

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(TARGET_SCRIPT)
end

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_BluntWeaponStrengthInArmsRefresh", strengthInArmsState)
    end
end

local function refreshWatchers()
    for _, actor in ipairs(world.activeActors) do
        if shouldAttachWatcher(actor) then
            actor:addScript(TARGET_SCRIPT, strengthInArmsState)
        elseif actor ~= nil and type(actor.hasScript) == "function" and actor:hasScript(TARGET_SCRIPT) then
            sendState(actor)
        end
    end
end

local function onStrengthInArmsState(data)
    if type(data) ~= "table" then
        return
    end

    strengthInArmsState = {
        enabled = data.enabled == true,
        damageBonus = math.max(0, math.floor(tonumber(data.damageBonus) or 0)),
        playerId = type(data.playerId) == "string" and data.playerId or nil,
    }
    refreshWatchers()
end

return {
    eventHandlers = {
        SkillPerkSystem_BluntWeaponStrengthInArmsState = onStrengthInArmsState,
    },
    engineHandlers = {
        onUpdate = function(dt)
            refreshTimer = refreshTimer + (tonumber(dt) or 0)
            if refreshTimer >= WATCHER_REFRESH_INTERVAL then
                refreshTimer = 0
                refreshWatchers()
            end
        end,
        onLoad = function()
            refreshTimer = WATCHER_REFRESH_INTERVAL
            refreshWatchers()
        end,
    },
}
