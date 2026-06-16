local types = require("openmw.types")

local Actor = types.Actor
local CRITICAL_DAMAGE_FALLBACK = 20

local function isValidActor(actor)
    return actor ~= nil
        and type(actor.isValid) == "function"
        and actor:isValid()
        and Actor ~= nil
        and type(Actor.objectIsInstance) == "function"
        and Actor.objectIsInstance(actor)
end

local function applyHealthDamage(target, amount)
    local healthAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.health
    if type(healthAccessor) ~= "function" then
        return false
    end

    local health = healthAccessor(target)
    if health == nil or type(health.current) ~= "number" then
        return false
    end

    health.current = math.max(0, health.current - amount)
    return true
end

local function onApplyGreatbladeCritical(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidActor(target) then
        return
    end
    if type(Actor.isDead) == "function" and Actor.isDead(target) then
        return
    end

    local damage = math.max(0, tonumber(data.damage) or CRITICAL_DAMAGE_FALLBACK)
    if damage <= 0 then
        return
    end

    applyHealthDamage(target, damage)
end

return {
    eventHandlers = {
        SkillPerkSystem_ApplyGreatbladeCritical = onApplyGreatbladeCritical,
    },
}
