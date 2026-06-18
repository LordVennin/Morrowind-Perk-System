local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local KINDLING_GRIP_HEALTH_THRESHOLD = 0.5

local function getHealth()
    local healthAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.health
    if type(healthAccessor) ~= "function" then
        return nil
    end

    return healthAccessor(selfObj)
end

local function getHealthPercent()
    local health = getHealth()
    if health == nil then
        return 1
    end

    local current = tonumber(health.current) or 0
    local base = tonumber(health.base) or current
    local modifier = tonumber(health.modifier) or 0
    local maxHealth = math.max(0, base + modifier)
    if maxHealth <= 0 then
        return 0
    end

    return current / maxHealth
end

local function isBelowKindlingGripThreshold()
    return getHealthPercent() < KINDLING_GRIP_HEALTH_THRESHOLD
end

local function applyHealthDamage(amount)
    local health = getHealth()
    if health == nil or type(health.current) ~= "number" then
        return false
    end

    health.current = math.max(0, health.current - math.max(0, tonumber(amount) or 0))
    return true
end

local function onApplyKindlingGripDamage(data)
    if type(data) ~= "table" then
        return
    end

    local damage = math.max(0, tonumber(data.damage) or 0)
    if damage <= 0 then
        return
    end
    if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
        return
    end
    if not isBelowKindlingGripThreshold() then
        return
    end

    applyHealthDamage(damage)
end

local function isSuccessfulPlayerMeleeHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker == nil or type(attack.attacker.isValid) ~= "function" or not attack.attacker:isValid() then
        return false
    end

    local meleeType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Melee
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return true
end

local function onHit(attack)
    if not isSuccessfulPlayerMeleeHit(attack) then
        return
    end

    attack.attacker:sendEvent("SkillPerkSystem_TryAxeKindlingGrip", {
        target = selfObj,
        damage = attack.damage,
    })
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    eventHandlers = {
        SkillPerkSystem_ApplyAxeKindlingGripDamage = onApplyKindlingGripDamage,
    },
}
