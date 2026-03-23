local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.steady_hands.enabled"
local NO_CONSUME_CHANCE_KEY = "security.steady_hands.no_consume_chance"
local NO_CONSUME_CHANCE = 0.15
local handlersRegistered = false

local function getPlayerApis()
    local okSelf, pselfModule = pcall(require, "openmw.self")
    local okStorage, storageModule = pcall(require, "openmw.storage")
    if not okSelf or not okStorage then
        return nil
    end

    local playerSection = storageModule.playerSection(EFFECTS_SECTION_ID)
    if playerSection == nil then
        return nil
    end

    return {
        self = pselfModule,
        section = playerSection,
    }
end

local function isPlayerActor(actor, pselfModule)
    return actor ~= nil and actor == pselfModule
end

local function steadyHandsEnabled(section)
    return section:get(ENABLED_KEY) == true
end

local function steadyHandsNoConsumeChance(section)
    local chance = section:get(NO_CONSUME_CHANCE_KEY)
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
    local playerApis = getPlayerApis()
    if playerApis == nil then
        return
    end

    if not isPlayerActor(actor, playerApis.self) then
        return
    end
    if not steadyHandsEnabled(playerApis.section) then
        return
    end
    if math.random() >= steadyHandsNoConsumeChance(playerApis.section) then
        return
    end
    if type(options) == "table" then
        options.consume = false
    end
end

local function registerRuntimeHooks()
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
    local playerApis = getPlayerApis()
    if playerApis == nil then
        return
    end

    playerApis.section:set(ENABLED_KEY, true)
    playerApis.section:set(NO_CONSUME_CHANCE_KEY, NO_CONSUME_CHANCE)
end

local function clearSteadyHandsState()
    local playerApis = getPlayerApis()
    if playerApis == nil then
        return
    end

    playerApis.section:set(ENABLED_KEY, false)
    playerApis.section:set(NO_CONSUME_CHANCE_KEY, 0.0)
end

return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "Adds a 15% chance for lockpick/probe uses to not be consumed while enabled.",
    registerRuntimeHooks = registerRuntimeHooks,
    onAcquire = function(_context)
        applySteadyHandsState()
    end,
    onRemove = function(_context)
        clearSteadyHandsState()
    end,
}
