-- Quick Pick player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
local multiplyAnimationSpeed = __basepack_animation.multiplyAnimationSpeed
local registerBasepackAnimationHandler = __basepack_animation.registerHandler
local __basepack_subsystem_result = nil

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

local function handleSecurityToolAnimation(event)
    if not event.isToolUseShape then
        return
    end
    if not quickPickEnabled() then
        return
    end
    if getEquippedSecurityTool() == nil then
        return
    end

    multiplyAnimationSpeed(event.options, toolSpeedMultiplier())
end
registerBasepackAnimationHandler(handleSecurityToolAnimation)

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

__basepack_subsystem_result = {
    eventHandlers = {
        [TOGGLE_EVENT] = handleQuickPickToggle,
    },
}


return __basepack_subsystem_result
