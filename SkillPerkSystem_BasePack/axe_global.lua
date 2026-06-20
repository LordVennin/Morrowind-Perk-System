local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local AXE_TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/axe_target.lua"
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local kindlingGripState = {
    enabled = false,
    damageBonusCount = 0,
    bloodletterEnabled = false,
    draggingWoundEnabled = false,
    hewerHeartEnabled = false,
    crimsonCleaveEnabled = false,
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

    return not actor:hasScript(AXE_TARGET_SCRIPT)
end

local function sendState(actor)
    if actor == nil or type(actor.sendEvent) ~= "function" then
        return
    end

    actor:sendEvent("SkillPerkSystem_AxeKindlingGripRefresh", kindlingGripState)
end

local function refreshWatchers()
    for _, actor in ipairs(world.activeActors) do
        if shouldAttachWatcher(actor) then
            actor:addScript(AXE_TARGET_SCRIPT, kindlingGripState)
        elseif actor ~= nil and type(actor.hasScript) == "function" and actor:hasScript(AXE_TARGET_SCRIPT) then
            sendState(actor)
        end
    end
end

local function onKindlingGripState(data)
    if type(data) ~= "table" then
        return
    end

    kindlingGripState = {
        enabled = data.enabled == true,
        damageBonusCount = math.max(0, math.floor(tonumber(data.damageBonusCount) or 0)),
        bloodletterEnabled = data.bloodletterEnabled == true,
        draggingWoundEnabled = data.draggingWoundEnabled == true,
        hewerHeartEnabled = data.hewerHeartEnabled == true,
        crimsonCleaveEnabled = data.crimsonCleaveEnabled == true,
        playerId = type(data.playerId) == "string" and data.playerId or nil,
    }
    refreshWatchers()
end

return {
    eventHandlers = {
        SkillPerkSystem_AxeKindlingGripState = onKindlingGripState,
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
