local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION = storage.playerSection("SkillPerkSystem_BasePack_Effects")
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local NO_CONSUME_CHANCE = 0.15
local handlersRegistered = false

local function isPlayerActor(actor)
    return actor ~= nil and actor == pself
end

local function steadyHandsEnabled()
    return EFFECTS_SECTION:get(ENABLED_KEY) == true
end

local function steadyHandsNoConsumeChance()
    local chance = EFFECTS_SECTION:get(NO_CONSUME_CHANCE_KEY)
    if type(chance) ~= "number" then
        chance = NO_CONSUME_CHANCE
    end

    if chance < 0 then
        return 0
    end
    if chance > 1 then
        return 1
    end
    return chance
end

local function maybePreventConsumption(_item, actor, options)
    if not isPlayerActor(actor) then
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

local function ensureHandlersRegistered()
    if handlersRegistered then
        return
    end

    local itemUsage = interfaces.ItemUsage
    if type(itemUsage) ~= "table" or type(itemUsage.addHandlerForType) ~= "function" then
        print("[SkillPerkSystem_BasePack] ItemUsage interface unavailable; Steady Hands consume prevention disabled")
        return
    end

    itemUsage.addHandlerForType(types.Lockpick, maybePreventConsumption)
    itemUsage.addHandlerForType(types.Probe, maybePreventConsumption)
    handlersRegistered = true
end

local function applySteadyHandsState()
    ensureHandlersRegistered()
    EFFECTS_SECTION:set(ENABLED_KEY, true)
    EFFECTS_SECTION:set(NO_CONSUME_CHANCE_KEY, NO_CONSUME_CHANCE)
end

local function clearSteadyHandsState()
    EFFECTS_SECTION:set(ENABLED_KEY, false)
    EFFECTS_SECTION:set(NO_CONSUME_CHANCE_KEY, 0.0)
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "Adds a 15% chance for lockpick/probe uses to not be consumed while enabled.",
    onAcquire = function(_context)
        applySteadyHandsState()
    end,
    onRemove = function(_context)
        clearSteadyHandsState()
    end,
}
