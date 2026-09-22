-- Retinue follower script for SkillPerkSystem_BasePack.
--
-- Attached by the global script to the one NPC the player has recruited
-- through the Retinue perk. All it does is hold a Follow package on the
-- player and take it off again when dismissed. AI packages can only be
-- driven from a local script, which is why this exists at all.
--
-- The global side pushes the player object right after attaching, but the
-- script does not exist yet when that push is sent, so the object is asked
-- for from onInit/onLoad instead. interfaces.AI is not resolved during
-- onInit either; the Follow event arrives later, when it is.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")

local LOG_TAG = "[SkillPerkSystem_BasePack][Retinue][Follower]"

local playerId = nil
local following = false

local function requestPlayer()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Follower_Request", { target = selfObj })
end

local function alreadyFollowing(player)
    local AI = interfaces.AI
    if AI == nil or type(AI.getActivePackage) ~= "function" then
        return false
    end
    local ok, package = pcall(AI.getActivePackage)
    if not ok or package == nil then
        return false
    end
    local target = package.target
    return package.type == "Follow" and target ~= nil and player ~= nil and target.id == player.id
end

local function onFollow(data)
    local player = type(data) == "table" and data.player or nil
    if player == nil then
        return
    end
    local AI = interfaces.AI
    if AI == nil or type(AI.startPackage) ~= "function" then
        -- Not resolved yet; the global side re-sends on its next status
        -- request, and the package survives a save in any case.
        return
    end
    playerId = player.id
    if alreadyFollowing(player) then
        following = true
        return
    end
    local ok, err = pcall(AI.startPackage, { type = "Follow", target = player })
    if ok then
        following = true
        print(LOG_TAG .. " " .. tostring(selfObj.recordId) .. " now follows the player")
    else
        print(LOG_TAG .. " could not start following: " .. tostring(err))
    end
end

local function onDismiss()
    local AI = interfaces.AI
    if AI ~= nil and type(AI.removePackages) == "function" then
        pcall(AI.removePackages, "Follow")
    end
    following = false
    print(LOG_TAG .. " " .. tostring(selfObj.recordId) .. " dismissed")
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Follower_Detach", { target = selfObj })
end

return {
    eventHandlers = {
        SkillPerkSystem_BasePack_Follower_Follow = onFollow,
        SkillPerkSystem_BasePack_Follower_Dismiss = onDismiss,
    },
    engineHandlers = {
        onInit = function()
            requestPlayer()
        end,
        onLoad = function(data)
            playerId = type(data) == "table" and data.playerId or nil
            following = type(data) == "table" and data.following == true
            requestPlayer()
        end,
        onSave = function()
            return { playerId = playerId, following = following }
        end,
    },
}
