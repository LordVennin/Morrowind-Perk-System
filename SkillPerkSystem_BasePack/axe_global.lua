local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local AXE_TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/axe_target.lua"
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0

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

local function refreshWatchers()
    for _, actor in ipairs(world.activeActors) do
        if shouldAttachWatcher(actor) then
            actor:addScript(AXE_TARGET_SCRIPT, {})
        end
    end
end

return {
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
