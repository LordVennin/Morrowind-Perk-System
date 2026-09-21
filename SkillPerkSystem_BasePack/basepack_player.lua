-- Consolidated PLAYER runtime loader for SkillPerkSystem_BasePack.
--
-- Each perk tree lives in its own module under runtime/player/ and returns a
-- subsystem table of eventHandlers/engineHandlers. Keeping one chunk per tree
-- gives each an independent 200-local budget (Lua's per-function limit), which
-- a single consolidated file was close to exhausting. Cross-subsystem state
-- lives in runtime/shared.lua; animation plumbing lives in runtime/animation.lua.
--
-- List order defines engine-handler chain order, so preserve it when adding trees.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")

local __basepack_subsystems = {
    require("scripts.SkillPerkSystem_BasePack.runtime.player.steady_hands"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.tumbler_sense"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.quick_pick"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.lucky_find"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.unseen_hand"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.medium_armor"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.heavy_armor"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.block"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.longblade"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.shortblade"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.axe"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.marksman"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.spear"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.blunt_weapon"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.block_reactive"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.apprentice_hammer"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.careful_repairs"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.hand_to_hand"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.alchemy"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.athletics"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.acrobatics"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.sneak"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.conjuration"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.destruction"),
    require("scripts.SkillPerkSystem_BasePack.runtime.player.mysticism"),
}

-- Install the shared animation dispatchers only after every runtime module has
-- registered its handlers.
__basepack_animation.install()


----------------------------------------------------------------------
-- combined eventHandlers
----------------------------------------------------------------------
local __combinedEventHandlers = {}
for _, subsystem in ipairs(__basepack_subsystems) do
    local handlers = subsystem.eventHandlers
    if type(handlers) == "table" then
        for eventName, handler in pairs(handlers) do
            if type(handler) == "function" then
                local previous = __combinedEventHandlers[eventName]
                if previous == nil then
                    __combinedEventHandlers[eventName] = handler
                else
                    __combinedEventHandlers[eventName] = function(data)
                        previous(data)
                        handler(data)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- combined engineHandlers
----------------------------------------------------------------------
local __combinedEngineHandlers = {}
local __engineHandlerChains = {}

local function predicateNameForHandler(handlerName)
    if handlerName == "onUpdate" then
        return "shouldUpdate"
    elseif handlerName == "onFrame" then
        return "shouldFrame"
    end
    return nil
end

for _, subsystem in ipairs(__basepack_subsystems) do
    local handlers = subsystem.engineHandlers
    if type(handlers) == "table" then
        for handlerName, handler in pairs(handlers) do
            if handlerName ~= "shouldUpdate" and handlerName ~= "shouldFrame" and type(handler) == "function" then
                local chain = __engineHandlerChains[handlerName]
                if chain == nil then
                    chain = {}
                    __engineHandlerChains[handlerName] = chain
                end
                local predicateName = predicateNameForHandler(handlerName)
                chain[#chain + 1] = {
                    handler = handler,
                    shouldRun = predicateName ~= nil and handlers[predicateName] or nil,
                }
            end
        end
    end
end

local INACTIVE_UPDATE_PREDICATE_INTERVAL = 0.10
local INACTIVE_FRAME_PREDICATE_INTERVAL = 0.10

local function makeCombinedOnUpdate(chain)
    local inactivePredicateTimer = INACTIVE_UPDATE_PREDICATE_INTERVAL

    return function(dt)
        local deltaTime = tonumber(dt) or 0
        inactivePredicateTimer = inactivePredicateTimer + deltaTime

        local scanInactivePredicates = inactivePredicateTimer >= INACTIVE_UPDATE_PREDICATE_INTERVAL
        if scanInactivePredicates then
            inactivePredicateTimer = 0
        end

        for index = 1, #chain do
            local entry = chain[index]
            local shouldRun = entry.shouldRun
            if type(shouldRun) ~= "function" then
                entry.handler(dt)
            elseif entry.updateActive then
                if shouldRun(dt) then
                    entry.handler(dt)
                else
                    entry.updateActive = false
                end
            elseif scanInactivePredicates and shouldRun(dt) then
                entry.updateActive = true
                entry.handler(dt)
            end
        end
    end
end

local function makeCombinedOnFrame(chain)
    local inactivePredicateTimer = INACTIVE_FRAME_PREDICATE_INTERVAL

    return function(dt)
        local deltaTime = tonumber(dt) or 0
        local pausedFrame = deltaTime <= 0
        inactivePredicateTimer = inactivePredicateTimer + deltaTime
        local scanInactivePredicates = pausedFrame or inactivePredicateTimer >= INACTIVE_FRAME_PREDICATE_INTERVAL
        if scanInactivePredicates and not pausedFrame then
            inactivePredicateTimer = 0
        end

        for index = 1, #chain do
            local entry = chain[index]
            local shouldRun = entry.shouldRun
            if type(shouldRun) ~= "function" then
                entry.handler(dt)
            elseif entry.frameActive then
                if shouldRun(dt) then
                    entry.handler(dt)
                else
                    entry.frameActive = false
                end
            elseif scanInactivePredicates and shouldRun(dt) then
                entry.frameActive = true
                entry.handler(dt)
            end
        end
    end
end

for handlerName, chain in pairs(__engineHandlerChains) do
    if #chain == 1 and chain[1].shouldRun == nil then
        __combinedEngineHandlers[handlerName] = chain[1].handler
    elseif handlerName == "onUpdate" and #chain > 0 then
        -- OpenMW can call PLAYER onUpdate frequently. Most basepack update
        -- predicates are dormant in normal play, so dormant predicates are
        -- polled at a short interval; once active, they are checked and
        -- dispatched every update until they report idle again.
        __combinedEngineHandlers[handlerName] = makeCombinedOnUpdate(chain)
    elseif handlerName == "onFrame" and #chain > 0 then
        -- OpenMW calls PLAYER onFrame every rendered frame. Most basepack frame
        -- handlers are dormant fallback windows, so avoid re-running every idle
        -- predicate every frame; once a predicate becomes active it is checked and
        -- dispatched every frame until it reports idle again.
        __combinedEngineHandlers[handlerName] = makeCombinedOnFrame(chain)
    elseif #chain > 0 then
        __combinedEngineHandlers[handlerName] = function(...)
            local saveData = nil
            for index = 1, #chain do
                local entry = chain[index]
                if type(entry.shouldRun) ~= "function" or entry.shouldRun(...) then
                    local result = entry.handler(...)
                    if handlerName == "onSave" and result ~= nil then
                        if saveData == nil then saveData = {} end
                        if type(result) == "table" then
                            for key, value in pairs(result) do
                                saveData[key] = value
                            end
                        end
                    end
                end
            end
            if handlerName == "onSave" then
                return saveData
            end
        end
    end
end

local __combinedInterfaceName = nil
local __combinedInterface = nil
for _, subsystem in ipairs(__basepack_subsystems) do
    -- Preserve the PLAYER-side Combat interface override from the former block runtime.
    -- Other former PLAYER runtime interfaces in this base pack are not referenced by
    -- the repository and cannot be exported simultaneously by one OpenMW script.
    if subsystem.interfaceName == "Combat" and type(subsystem.interface) == "table" then
        __combinedInterfaceName = subsystem.interfaceName
        __combinedInterface = subsystem.interface
        break
    end
end

local __result = {
    eventHandlers = __combinedEventHandlers,
    engineHandlers = __combinedEngineHandlers,
}
if __combinedInterfaceName ~= nil then
    __result.interfaceName = __combinedInterfaceName
    __result.interface = __combinedInterface
end

return __result
