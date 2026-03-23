local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local DEFAULT_NO_CONSUME_CHANCE = 0.15
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_SteadyHands_Toggle"

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

local function clampChance(value)
    if type(value) ~= "number" then
        return DEFAULT_NO_CONSUME_CHANCE
    end
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function steadyHandsEnabled()
    return effectsSection:get(ENABLED_KEY) == true
end

local function steadyHandsNoConsumeChance()
    return clampChance(effectsSection:get(NO_CONSUME_CHANCE_KEY))
end

local function maybePreventConsumption(_item, actor, options)
    if not types.Player.objectIsInstance(actor) then
        return
    end
    if not steadyHandsEnabled() then
        return
    end
    if math.random() >= steadyHandsNoConsumeChance() then
        return
    end
    if type(options) == "table" then
        options.consume = false
    end
end

local function handleSteadyHandsToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)
    if enabled then
        effectsSection:set(NO_CONSUME_CHANCE_KEY, clampChance(data.chance))
    else
        effectsSection:set(NO_CONSUME_CHANCE_KEY, 0.0)
    end

    print(string.format("[SkillPerkSystem_BasePack] Steady Hands %s (chance=%.2f)", enabled and "enabled" or "disabled", effectsSection:get(NO_CONSUME_CHANCE_KEY) or 0.0))
end

local function registerHandlers()
    local itemUsage = interfaces.ItemUsage
    if type(itemUsage) ~= "table" or type(itemUsage.addHandlerForType) ~= "function" then
        print("[SkillPerkSystem_BasePack] ItemUsage interface unavailable; Steady Hands consume prevention disabled")
        return
    end

    itemUsage.addHandlerForType(types.Lockpick, maybePreventConsumption)
    itemUsage.addHandlerForType(types.Probe, maybePreventConsumption)
end

return {
    engineHandlers = {
        onInit = registerHandlers,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleSteadyHandsToggle,
    },
}
