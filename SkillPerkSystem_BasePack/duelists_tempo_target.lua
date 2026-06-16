local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor

local stacks = 0
local remainingTime = 0
local agilityPerStack = 3
local appliedPenalty = 0

local function resolveAgilityStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(selfObj)
end

local function applyPenalty(targetPenalty)
    local desired = math.max(0, math.floor(tonumber(targetPenalty) or 0))
    local current = math.max(0, math.floor(tonumber(appliedPenalty) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier + current - desired
    appliedPenalty = desired
end

local function clearPenalty()
    applyPenalty(0)
    remainingTime = 0
    stacks = 0
end

local function setState(data)
    if type(data) ~= "table" then
        return
    end

    stacks = math.max(0, math.floor(tonumber(data.stacks) or stacks or 0))
    remainingTime = math.max(0, tonumber(data.duration) or remainingTime or 0)
    agilityPerStack = math.max(0, math.floor(tonumber(data.agilityPerStack) or agilityPerStack or 3))
    applyPenalty(stacks * agilityPerStack)
end


local function applyHealthDamage(amount)
    local healthAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.health
    if type(healthAccessor) ~= "function" then
        return false
    end

    local health = healthAccessor(selfObj)
    if health == nil or type(health.current) ~= "number" then
        return false
    end

    health.current = math.max(0, health.current - math.max(0, tonumber(amount) or 0))
    return true
end

local function onApplyLongBladeCriticalDamage(data)
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

    attack.attacker:sendEvent("SkillPerkSystem_TryDuelistsTempo", {
        target = selfObj,
    })
    attack.attacker:sendEvent("SkillPerkSystem_TryKeenEdgeCritical", {
        target = selfObj,
    })
    attack.attacker:sendEvent("SkillPerkSystem_TryGreatbladeCritical", {
        target = selfObj,
    })
    attack.attacker:sendEvent("SkillPerkSystem_TryGrandmasterHeavyCritical", {
        target = selfObj,
    })
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    eventHandlers = {
        SkillPerkSystem_DuelistsTempoRefresh = setState,
        SkillPerkSystem_ApplyLongBladeCriticalDamage = onApplyLongBladeCriticalDamage,
    },
    engineHandlers = {
        onInit = function(initData)
            setState(initData)
        end,
        onLoad = function(savedData, initData)
            if type(savedData) == "table" then
                stacks = math.max(0, math.floor(tonumber(savedData.stacks) or 0))
                remainingTime = math.max(0, tonumber(savedData.remainingTime) or 0)
                agilityPerStack = math.max(0, math.floor(tonumber(savedData.agilityPerStack) or 3))
                appliedPenalty = math.max(0, math.floor(tonumber(savedData.appliedPenalty) or 0))
                applyPenalty(stacks * agilityPerStack)
            else
                setState(initData)
            end
        end,
        onSave = function()
            return {
                stacks = stacks,
                remainingTime = remainingTime,
                agilityPerStack = agilityPerStack,
                appliedPenalty = appliedPenalty,
            }
        end,
        onUpdate = function(dt)
            if remainingTime <= 0 then
                if appliedPenalty ~= 0 then
                    clearPenalty()
                end
                return
            end

            remainingTime = math.max(0, remainingTime - (tonumber(dt) or 0))
            if remainingTime <= 0 then
                clearPenalty()
            end
        end,
    },
}
