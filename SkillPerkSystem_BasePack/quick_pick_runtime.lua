-- Superseded by scripts/SkillPerkSystem_BasePack/basepack_player.lua; kept temporarily for save/development compatibility.
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local I = interfaces
local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.quick_pick.enabled"
local TOOL_SPEED_MULTIPLIER_KEY = "security.quick_pick.tool_speed_multiplier"
local DEFAULT_TOOL_SPEED_MULTIPLIER = 1.75
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_QuickPick_Toggle"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local QUICK_PICK_PERK_ID = "security_quick_pick"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local function quickPickEnabled()
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(QUICK_PICK_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(QUICK_PICK_PERK_ID) then
        return false
    end

    return true
end

local function toolSpeedMultiplier()
    local value = tonumber(effectsSection:get(TOOL_SPEED_MULTIPLIER_KEY))
    if type(value) ~= "number" or value < 1 then
        return DEFAULT_TOOL_SPEED_MULTIPLIER
    end
    return value
end

local function getEquippedSecurityTool()
    local right = nil
    local left = nil

    local okRight, rightItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if okRight then
        right = rightItem
    end

    local okLeft, leftItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedLeft)
    if okLeft then
        left = leftItem
    end

    if right and (Lockpick.objectIsInstance(right) or Probe.objectIsInstance(right)) then
        return right
    end

    if left and (Lockpick.objectIsInstance(left) or Probe.objectIsInstance(left)) then
        return left
    end

    return nil
end

local function isLikelyToolUseAnimation(groupName, options)
    if type(groupName) ~= "string" then
        return false
    end

    local g = string.lower(groupName)
    local startKeyRaw = type(options) == "table" and (options.startkey or options.startKey) or nil
    local stopKeyRaw = type(options) == "table" and (options.stopkey or options.stopKey) or nil
    local startKey = type(startKeyRaw) == "string" and string.lower(startKeyRaw) or ""
    local stopKey = type(stopKeyRaw) == "string" and string.lower(stopKeyRaw) or ""

    if string.find(g, "pick", 1, true) then return true end
    if string.find(g, "probe", 1, true) then return true end
    if string.find(g, "lock", 1, true) then return true end
    if string.find(g, "security", 1, true) then return true end
    if string.find(startKey, "pick", 1, true) then return true end
    if string.find(startKey, "probe", 1, true) then return true end
    if string.find(stopKey, "pick", 1, true) then return true end
    if string.find(stopKey, "probe", 1, true) then return true end

    return false
end

I.AnimationController.addPlayBlendedAnimationHandler(function(groupName, options)
    if not quickPickEnabled() then
        return
    end

    if getEquippedSecurityTool() == nil then
        return
    end

    if not isLikelyToolUseAnimation(groupName, options) then
        return
    end

    if type(options) ~= "table" then
        return
    end

    local currentSpeed = type(options.speed) == "number" and options.speed or 1.0
    options.speed = currentSpeed * toolSpeedMultiplier()
end)

local function handleQuickPickToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)

    if enabled then
        local value = tonumber(data.toolSpeedMultiplier)
        if type(value) ~= "number" or value < 1 then
            value = DEFAULT_TOOL_SPEED_MULTIPLIER
        end
        effectsSection:set(TOOL_SPEED_MULTIPLIER_KEY, value)
    else
        effectsSection:set(TOOL_SPEED_MULTIPLIER_KEY, 1.0)
    end
end

return {
    eventHandlers = {
        [TOGGLE_EVENT] = handleQuickPickToggle,
    },
}
