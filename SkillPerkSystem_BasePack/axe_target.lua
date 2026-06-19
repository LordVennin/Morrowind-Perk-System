local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local KINDLING_GRIP_HEALTH_THRESHOLD = 0.5
local KINDLING_GRIP_DAMAGE_BONUS = 0.10
local BLOODLETTER_DURATION = 5.0
local BLOODLETTER_DAMAGE_INTERVAL = 1.0
local BLOODLETTER_DAMAGE_PER_TICK = 1
local BLOODLETTER_BLOOD_INTERVAL = 2.0

local kindlingGripEnabled = false
local kindlingGripPlayerId = nil
local kindlingGripDamageBonusCount = 0
local bloodletterEnabled = false

local bloodletterRemainingTime = 0
local bloodletterDamageTimer = 0
local bloodletterBloodTimer = 0
local bloodletterBloodPosition = nil

local function setKindlingGripState(data)
    if type(data) ~= "table" then
        return
    end

    kindlingGripDamageBonusCount = math.max(0, math.floor(tonumber(data.damageBonusCount) or 0))
    kindlingGripEnabled = data.enabled == true and kindlingGripDamageBonusCount > 0
    kindlingGripPlayerId = type(data.playerId) == "string" and data.playerId or nil
    bloodletterEnabled = data.bloodletterEnabled == true
end

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

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function weaponTypeEquals(record, typeName)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE[typeName])
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isAxeRecord(record)
    return weaponTypeEquals(record, "AxeOneHand") or weaponTypeEquals(record, "AxeTwoHand")
end

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function actorHasEquippedAxe(actor)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(actor, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return false
    end

    return isAxeRecord(getWeaponRecord(weapon))
end

local function isSuccessfulKindlingGripHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not kindlingGripEnabled or type(kindlingGripPlayerId) ~= "string" or kindlingGripPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= kindlingGripPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not actorHasEquippedAxe(attack.attacker) then
        return false
    end
    if not isBelowKindlingGripThreshold() then
        return false
    end

    local meleeType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Melee
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return type(attack.damage) == "table" and (tonumber(attack.damage.health) or 0) > 0
end

local function isSuccessfulBloodletterHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not bloodletterEnabled or type(kindlingGripPlayerId) ~= "string" or kindlingGripPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= kindlingGripPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not actorHasEquippedAxe(attack.attacker) then
        return false
    end

    local meleeType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Melee
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return type(attack.damage) == "table" and (tonumber(attack.damage.health) or 0) > 0
end

local function applyHealthDamage(amount)
    local health = getHealth()
    if health == nil or type(health.current) ~= "number" then
        return false
    end

    health.current = math.max(0, health.current - math.max(0, tonumber(amount) or 0))
    return true
end

local function spawnBloodSpray(position)
    local spawnBloodEffect = interfaces.Combat ~= nil and interfaces.Combat.spawnBloodEffect
    if type(spawnBloodEffect) ~= "function" then
        return
    end

    spawnBloodEffect(position or selfObj.position)
end

local function refreshBloodletterBleed(attack)
    bloodletterRemainingTime = BLOODLETTER_DURATION
    bloodletterDamageTimer = 0
    bloodletterBloodTimer = 0
    bloodletterBloodPosition = attack.hitPos or selfObj.position
    spawnBloodSpray(bloodletterBloodPosition)
end

local function onHit(attack)
    if isSuccessfulKindlingGripHit(attack) then
        attack.damage.health = attack.damage.health * (1 + (KINDLING_GRIP_DAMAGE_BONUS * kindlingGripDamageBonusCount))
    end

    if isSuccessfulBloodletterHit(attack) then
        refreshBloodletterBleed(attack)
    end
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    eventHandlers = {
        SkillPerkSystem_AxeKindlingGripRefresh = setKindlingGripState,
    },
    engineHandlers = {
        onInit = function(initData)
            setKindlingGripState(initData)
        end,
        onLoad = function(savedData, initData)
            if type(savedData) == "table" then
                setKindlingGripState(savedData)
                bloodletterRemainingTime = math.max(0, tonumber(savedData.bloodletterRemainingTime) or 0)
                bloodletterDamageTimer = math.max(0, tonumber(savedData.bloodletterDamageTimer) or 0)
                bloodletterBloodTimer = math.max(0, tonumber(savedData.bloodletterBloodTimer) or 0)
                bloodletterBloodPosition = nil
            else
                setKindlingGripState(initData)
            end
        end,
        onSave = function()
            return {
                enabled = kindlingGripEnabled,
                damageBonusCount = kindlingGripDamageBonusCount,
                playerId = kindlingGripPlayerId,
                bloodletterEnabled = bloodletterEnabled,
                bloodletterRemainingTime = bloodletterRemainingTime,
                bloodletterDamageTimer = bloodletterDamageTimer,
                bloodletterBloodTimer = bloodletterBloodTimer,
            }
        end,
        onUpdate = function(dt)
            if bloodletterRemainingTime <= 0 then
                return
            end
            if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                bloodletterRemainingTime = 0
                return
            end

            local elapsed = math.max(0, tonumber(dt) or 0)
            bloodletterRemainingTime = math.max(0, bloodletterRemainingTime - elapsed)
            bloodletterDamageTimer = bloodletterDamageTimer + elapsed
            bloodletterBloodTimer = bloodletterBloodTimer + elapsed

            while bloodletterRemainingTime > 0 and bloodletterDamageTimer >= BLOODLETTER_DAMAGE_INTERVAL do
                bloodletterDamageTimer = bloodletterDamageTimer - BLOODLETTER_DAMAGE_INTERVAL
                applyHealthDamage(BLOODLETTER_DAMAGE_PER_TICK)
                if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                    bloodletterRemainingTime = 0
                    return
                end
            end

            if bloodletterRemainingTime > 0 and bloodletterBloodTimer >= BLOODLETTER_BLOOD_INTERVAL then
                bloodletterBloodTimer = 0
                spawnBloodSpray(bloodletterBloodPosition or selfObj.position)
            end
        end,
    },
}
