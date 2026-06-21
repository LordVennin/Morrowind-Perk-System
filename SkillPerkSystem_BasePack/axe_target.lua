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
local DRAGGING_WOUND_DURATION = 10.0
local DRAGGING_WOUND_DAMAGE_PER_TICK = BLOODLETTER_DAMAGE_PER_TICK * BLOODLETTER_DURATION / DRAGGING_WOUND_DURATION
local DRAGGING_WOUND_SPEED_PENALTY = 20
local BLOODLETTER_BLOOD_INTERVAL = 2.0
local IRON_CANOPY_MAGICKA_DAMAGE_MIN = 5
local IRON_CANOPY_MAGICKA_DAMAGE_MAX = 20
local IRON_CANOPY_EMPTY_MAGICKA_DAMAGE_BONUS = 0.20

local kindlingGripEnabled = false
local kindlingGripPlayerId = nil
local kindlingGripDamageBonusCount = 0
local bloodletterEnabled = false
local draggingWoundEnabled = false
local hewerHeartEnabled = false
local crimsonCleaveEnabled = false
local ironCanopyEnabled = false

local bloodletterRemainingTime = 0
local bloodletterDamageTimer = 0
local bloodletterBloodTimer = 0
local bloodletterDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK
local bloodletterSpeedPenaltyApplied = 0
local hewerHeartRemainingTime = 0
local hewerHeartDamageTimer = 0
local hewerHeartBloodTimer = 0
local hewerHeartDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK

local updateBleedSpeedPenalty

local function setKindlingGripState(data)
    if type(data) ~= "table" then
        return
    end

    kindlingGripDamageBonusCount = math.max(0, math.floor(tonumber(data.damageBonusCount) or 0))
    kindlingGripEnabled = data.enabled == true and kindlingGripDamageBonusCount > 0
    kindlingGripPlayerId = type(data.playerId) == "string" and data.playerId or nil
    bloodletterEnabled = data.bloodletterEnabled == true
    draggingWoundEnabled = data.draggingWoundEnabled == true
    hewerHeartEnabled = data.hewerHeartEnabled == true
    crimsonCleaveEnabled = data.crimsonCleaveEnabled == true
    ironCanopyEnabled = data.ironCanopyEnabled == true
    updateBleedSpeedPenalty()
end

local function resolveSpeedStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.speed
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(selfObj)
end

local function applyBloodletterSpeedPenalty(targetPenalty)
    local desired = math.max(0, math.floor(tonumber(targetPenalty) or 0))
    local current = math.max(0, math.floor(tonumber(bloodletterSpeedPenaltyApplied) or 0))
    if desired == current then
        return
    end

    local stat = resolveSpeedStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier + current - desired
    bloodletterSpeedPenaltyApplied = desired
end

updateBleedSpeedPenalty = function()
    if draggingWoundEnabled and (bloodletterRemainingTime > 0 or hewerHeartRemainingTime > 0) then
        applyBloodletterSpeedPenalty(DRAGGING_WOUND_SPEED_PENALTY)
    else
        applyBloodletterSpeedPenalty(0)
    end
end

local function clearBloodletterBleed()
    bloodletterRemainingTime = 0
    bloodletterDamageTimer = 0
    bloodletterBloodTimer = 0
    bloodletterDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK
    updateBleedSpeedPenalty()
end

local function clearHewerHeartBleed()
    hewerHeartRemainingTime = 0
    hewerHeartDamageTimer = 0
    hewerHeartBloodTimer = 0
    hewerHeartDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK
    updateBleedSpeedPenalty()
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

local function isSuccessfulAxeHit(attack, perkEnabled)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not perkEnabled or type(kindlingGripPlayerId) ~= "string" or kindlingGripPlayerId == "" then
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

local function getMagicka()
    local magickaAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.magicka
    if type(magickaAccessor) ~= "function" then
        return nil
    end

    return magickaAccessor(selfObj)
end

local function getCurrentMagicka()
    local magicka = getMagicka()
    if magicka == nil then
        return 0
    end

    return math.max(0, tonumber(magicka.current) or 0)
end

local function applyMagickaDamage(amount)
    local magicka = getMagicka()
    if magicka == nil or type(magicka.current) ~= "number" then
        return false
    end

    magicka.current = math.max(0, magicka.current - math.max(0, tonumber(amount) or 0))
    return true
end

local function applyIronCanopyHit(attack)
    if not isSuccessfulAxeHit(attack, ironCanopyEnabled) then
        return
    end

    applyMagickaDamage(math.random(IRON_CANOPY_MAGICKA_DAMAGE_MIN, IRON_CANOPY_MAGICKA_DAMAGE_MAX))

    if getCurrentMagicka() <= 0 then
        attack.damage.health = attack.damage.health * (1 + IRON_CANOPY_EMPTY_MAGICKA_DAMAGE_BONUS)
    end
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

local function isSlashAttack(attack)
    local slashType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_TYPES ~= nil
        and interfaces.Combat.ATTACK_TYPES.Slash
    return slashType ~= nil and type(attack) == "table" and attack.type == slashType
end

local function getBleedDamageMultiplier(attack)
    if crimsonCleaveEnabled and isSlashAttack(attack) then
        return 2
    end

    return 1
end

local function refreshBloodletterBleed(attack)
    local damageMultiplier = getBleedDamageMultiplier(attack)
    if draggingWoundEnabled then
        bloodletterRemainingTime = DRAGGING_WOUND_DURATION
        bloodletterDamagePerTick = DRAGGING_WOUND_DAMAGE_PER_TICK * damageMultiplier
    else
        bloodletterRemainingTime = BLOODLETTER_DURATION
        bloodletterDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK * damageMultiplier
    end
    bloodletterDamageTimer = 0
    bloodletterBloodTimer = 0
    updateBleedSpeedPenalty()
    spawnBloodSpray(attack.hitPos or selfObj.position)
end

local function refreshHewerHeartBleed(attack)
    local damageMultiplier = getBleedDamageMultiplier(attack)
    if draggingWoundEnabled then
        hewerHeartRemainingTime = DRAGGING_WOUND_DURATION
        hewerHeartDamagePerTick = DRAGGING_WOUND_DAMAGE_PER_TICK * damageMultiplier
    else
        hewerHeartRemainingTime = BLOODLETTER_DURATION
        hewerHeartDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK * damageMultiplier
    end
    hewerHeartDamageTimer = 0
    hewerHeartBloodTimer = 0
    updateBleedSpeedPenalty()
    spawnBloodSpray(attack.hitPos or selfObj.position)
end

local function onHit(attack)
    if isSuccessfulKindlingGripHit(attack) then
        attack.damage.health = attack.damage.health * (1 + (KINDLING_GRIP_DAMAGE_BONUS * kindlingGripDamageBonusCount))
    end

    applyIronCanopyHit(attack)

    if isSuccessfulAxeHit(attack, bloodletterEnabled) then
        refreshBloodletterBleed(attack)
    end

    if isSuccessfulAxeHit(attack, hewerHeartEnabled) and isBelowKindlingGripThreshold() then
        refreshHewerHeartBleed(attack)
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
                bloodletterDamagePerTick = math.max(0, tonumber(savedData.bloodletterDamagePerTick) or BLOODLETTER_DAMAGE_PER_TICK)
                bloodletterSpeedPenaltyApplied = math.max(0, math.floor(tonumber(savedData.bloodletterSpeedPenaltyApplied) or 0))
                hewerHeartRemainingTime = math.max(0, tonumber(savedData.hewerHeartRemainingTime) or 0)
                hewerHeartDamageTimer = math.max(0, tonumber(savedData.hewerHeartDamageTimer) or 0)
                hewerHeartBloodTimer = math.max(0, tonumber(savedData.hewerHeartBloodTimer) or 0)
                hewerHeartDamagePerTick = math.max(0, tonumber(savedData.hewerHeartDamagePerTick) or BLOODLETTER_DAMAGE_PER_TICK)
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
                draggingWoundEnabled = draggingWoundEnabled,
                hewerHeartEnabled = hewerHeartEnabled,
                crimsonCleaveEnabled = crimsonCleaveEnabled,
                ironCanopyEnabled = ironCanopyEnabled,
                bloodletterRemainingTime = bloodletterRemainingTime,
                bloodletterDamageTimer = bloodletterDamageTimer,
                bloodletterBloodTimer = bloodletterBloodTimer,
                bloodletterDamagePerTick = bloodletterDamagePerTick,
                bloodletterSpeedPenaltyApplied = bloodletterSpeedPenaltyApplied,
                hewerHeartRemainingTime = hewerHeartRemainingTime,
                hewerHeartDamageTimer = hewerHeartDamageTimer,
                hewerHeartBloodTimer = hewerHeartBloodTimer,
                hewerHeartDamagePerTick = hewerHeartDamagePerTick,
            }
        end,
        onUpdate = function(dt)
            if bloodletterRemainingTime <= 0 and hewerHeartRemainingTime <= 0 then
                updateBleedSpeedPenalty()
                return
            end
            if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                clearBloodletterBleed()
                clearHewerHeartBleed()
                return
            end

            local elapsed = math.max(0, tonumber(dt) or 0)

            if bloodletterRemainingTime > 0 then
                bloodletterRemainingTime = math.max(0, bloodletterRemainingTime - elapsed)
                bloodletterDamageTimer = bloodletterDamageTimer + elapsed
                bloodletterBloodTimer = bloodletterBloodTimer + elapsed

                while bloodletterRemainingTime > 0 and bloodletterDamageTimer >= BLOODLETTER_DAMAGE_INTERVAL do
                    bloodletterDamageTimer = bloodletterDamageTimer - BLOODLETTER_DAMAGE_INTERVAL
                    applyHealthDamage(bloodletterDamagePerTick)
                    if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                        clearBloodletterBleed()
                        clearHewerHeartBleed()
                        return
                    end
                end

                if bloodletterRemainingTime <= 0 then
                    clearBloodletterBleed()
                elseif bloodletterBloodTimer >= BLOODLETTER_BLOOD_INTERVAL then
                    bloodletterBloodTimer = 0
                    spawnBloodSpray(selfObj.position)
                end
            end

            if hewerHeartRemainingTime > 0 then
                hewerHeartRemainingTime = math.max(0, hewerHeartRemainingTime - elapsed)
                hewerHeartDamageTimer = hewerHeartDamageTimer + elapsed
                hewerHeartBloodTimer = hewerHeartBloodTimer + elapsed

                while hewerHeartRemainingTime > 0 and hewerHeartDamageTimer >= BLOODLETTER_DAMAGE_INTERVAL do
                    hewerHeartDamageTimer = hewerHeartDamageTimer - BLOODLETTER_DAMAGE_INTERVAL
                    applyHealthDamage(hewerHeartDamagePerTick)
                    if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                        clearBloodletterBleed()
                        clearHewerHeartBleed()
                        return
                    end
                end

                if hewerHeartRemainingTime <= 0 then
                    clearHewerHeartBleed()
                elseif hewerHeartBloodTimer >= BLOODLETTER_BLOOD_INTERVAL then
                    hewerHeartBloodTimer = 0
                    spawnBloodSpray(selfObj.position)
                end
            end

            updateBleedSpeedPenalty()
        end,
    },
}
