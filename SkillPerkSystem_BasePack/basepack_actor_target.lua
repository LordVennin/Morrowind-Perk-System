-- Consolidated CUSTOM actor-side target runtime for SkillPerkSystem_BasePack.
-- Supersedes axe_target.lua, bluntweapon_target.lua, duelists_tempo_target.lua, and aegis_rite_target.lua.

-- 1. shared requires/constants/helpers
local interfaces = require("openmw.interfaces")

local axe = {}
local blunt = {}
local duelistTempo = {}
local aegisRite = {}

-- 2. shared actor/stat/weapon/combat helpers
-- Subsystem-specific copies remain local below to preserve existing behavior and API fallbacks.

-- 3. axe target state/effects
do
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

local script = {
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

    axe.eventHandlers = script.eventHandlers or {}
    axe.engineHandlers = script.engineHandlers or {}
    axe.onHit = onHit
end

-- 4. blunt weapon target state/effects
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local strengthInArmsEnabled = false
local strengthInArmsDamageBonus = 0
local strengthInArmsPlayerId = nil
local platebreakerEnabled = false
local breathstealerEnabled = false
local heavyHitterEnabled = false
local staggeringBlowEnabled = false
local ironBellEnabled = false

local BREATHSTEALER_FATIGUE_DAMAGE = 20
local HEAVY_HITTER_SHIELD_CONDITION_DAMAGE = 300
local IRON_BELL_CONDITION_DAMAGE = 200
local STAGGERING_BLOW_CHOP_DAMAGE_MULTIPLIER = 1.5

local function setStrengthInArmsState(data)
    if type(data) ~= "table" then
        return
    end

    strengthInArmsEnabled = (data.strengthInArmsEnabled == true or data.enabled == true) and (tonumber(data.damageBonus) or 0) > 0
    strengthInArmsDamageBonus = math.max(0, math.floor(tonumber(data.damageBonus) or 0))
    strengthInArmsPlayerId = type(data.playerId) == "string" and data.playerId or nil
    platebreakerEnabled = data.platebreakerEnabled == true
    breathstealerEnabled = data.breathstealerEnabled == true
    heavyHitterEnabled = data.heavyHitterEnabled == true
    staggeringBlowEnabled = data.staggeringBlowEnabled == true
    ironBellEnabled = data.ironBellEnabled == true
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

local function isOneHandedBluntWeaponRecord(record)
    return weaponTypeEquals(record, "BluntOneHand")
end

local function isTwoHandedBluntWeaponRecord(record)
    return weaponTypeEquals(record, "BluntTwoClose")
        or weaponTypeEquals(record, "BluntTwoWide")
end

local function isBluntWeaponRecord(record)
    return isOneHandedBluntWeaponRecord(record) or isTwoHandedBluntWeaponRecord(record)
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

local function getEquippedBluntWeaponRecord(actor)
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

    local record = getWeaponRecord(weapon)
    if not isBluntWeaponRecord(record) then
        return nil
    end

    return record
end

local function actorHasEquippedBluntWeapon(actor)
    return getEquippedBluntWeaponRecord(actor) ~= nil
end

local function applyFatigueDamage(amount, allowNegative)
    local fatigueAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return false
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil or type(fatigue.current) ~= "number" then
        return false
    end

    if allowNegative and fatigue.current <= 0 then
        return false
    end

    local newFatigue = fatigue.current - math.max(0, tonumber(amount) or 0)
    if not allowNegative then
        newFatigue = math.max(0, newFatigue)
    end
    fatigue.current = newFatigue
    return true
end

local function isAttackType(attack, typeName)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    local expected = attackTypes ~= nil and tonumber(attackTypes[typeName]) or nil
    local actual = tonumber(attack.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isMeleeAttack(attack)
    local sourceTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_SOURCE_TYPES or nil
    local expected = sourceTypes ~= nil and tonumber(sourceTypes.Melee) or nil
    local actual = tonumber(attack.sourceType)
    return expected == nil or actual == nil or actual == expected
end

local function calculatePlatebreakerConditionDamage(attack)
    local strength = math.max(0, math.min(1, tonumber(attack.strength) or 1))
    return math.max(10, math.min(25, math.floor(10 + (15 * strength) + 0.5)))
end

local function isSuccessfulPlatebreakerHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not platebreakerEnabled then
        return false
    end
    if type(strengthInArmsPlayerId) ~= "string" or strengthInArmsPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= strengthInArmsPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) or not isAttackType(attack, "Slash") then
        return false
    end
    if type(attack.damage) ~= "table" or (tonumber(attack.damage.health) or 0) <= 0 then
        return false
    end

    return actorHasEquippedBluntWeapon(attack.attacker)
end

local function requestPlatebreakerArmorDamage(attack)
    if not isSuccessfulPlatebreakerHit(attack) then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyPlatebreakerArmorDamage", {
        target = pself,
        conditionDamage = ironBellEnabled
            and isTwoHandedBluntWeaponRecord(getEquippedBluntWeaponRecord(attack.attacker))
            and IRON_BELL_CONDITION_DAMAGE
            or calculatePlatebreakerConditionDamage(attack),
    })
end


local function wasBlockedAttack(attack)
    if type(attack) ~= "table" then
        return false
    end

    local blockedFlag = attack.blocked == true or attack.isBlocked == true or attack.block == true
    local blockedBy = string.lower(tostring(attack.blockedBy or attack.blockType or attack.defenseType or ""))
    if blockedBy:find("parry", 1, true) ~= nil or attack.parried == true or attack.isParry == true then
        return false
    end

    if blockedBy:find("shield", 1, true) ~= nil then
        return true
    end
    if blockedFlag then
        return true
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local totalDamage = (tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)
    return attack.successful == true and totalDamage <= 0
end

local function isHeavyHitterBlock(attack)
    if not heavyHitterEnabled then
        return false
    end
    if type(strengthInArmsPlayerId) ~= "string" or strengthInArmsPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= strengthInArmsPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) or not isAttackType(attack, "Chop") then
        return false
    end
    if not wasBlockedAttack(attack) then
        return false
    end

    return actorHasEquippedBluntWeapon(attack.attacker)
end

local function requestHeavyHitterShieldDamage(attack)
    if not isHeavyHitterBlock(attack) then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyHeavyHitterShieldDamage", {
        target = pself,
        conditionDamage = HEAVY_HITTER_SHIELD_CONDITION_DAMAGE
            + (
                ironBellEnabled
                    and isOneHandedBluntWeaponRecord(getEquippedBluntWeaponRecord(attack.attacker))
                    and IRON_BELL_CONDITION_DAMAGE
                or 0
            ),
    })
end

local function isSuccessfulBreathstealerHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not breathstealerEnabled then
        return false
    end
    if type(strengthInArmsPlayerId) ~= "string" or strengthInArmsPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= strengthInArmsPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) or not isAttackType(attack, "Thrust") then
        return false
    end
    if type(attack.damage) ~= "table" or (tonumber(attack.damage.health) or 0) <= 0 then
        return false
    end

    return actorHasEquippedBluntWeapon(attack.attacker)
end

local function applyBreathstealerFatigueDamage(attack)
    if isSuccessfulBreathstealerHit(attack) then
        applyFatigueDamage(BREATHSTEALER_FATIGUE_DAMAGE, ironBellEnabled)
    end
end

local function isSuccessfulStrengthInArmsHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not strengthInArmsEnabled or strengthInArmsDamageBonus <= 0 then
        return false
    end
    if type(strengthInArmsPlayerId) ~= "string" or strengthInArmsPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= strengthInArmsPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if type(attack.damage) ~= "table" or (tonumber(attack.damage.health) or 0) <= 0 then
        return false
    end

    return actorHasEquippedBluntWeapon(attack.attacker)
end

local function isSuccessfulStaggeringBlowHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not staggeringBlowEnabled then
        return false
    end
    if type(strengthInArmsPlayerId) ~= "string" or strengthInArmsPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= strengthInArmsPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) or not isAttackType(attack, "Chop") then
        return false
    end
    if type(attack.damage) ~= "table" or (tonumber(attack.damage.health) or 0) <= 0 then
        return false
    end

    return actorHasEquippedBluntWeapon(attack.attacker)
end

local function onHit(attack)
    if isSuccessfulStrengthInArmsHit(attack) then
        attack.damage.health = (tonumber(attack.damage.health) or 0) + strengthInArmsDamageBonus
    end
    if isSuccessfulStaggeringBlowHit(attack) then
        attack.damage.health = (tonumber(attack.damage.health) or 0) * STAGGERING_BLOW_CHOP_DAMAGE_MULTIPLIER
    end
    requestPlatebreakerArmorDamage(attack)
    applyBreathstealerFatigueDamage(attack)
    requestHeavyHitterShieldDamage(attack)
end

local script = {
    eventHandlers = {
        SkillPerkSystem_BluntWeaponStrengthInArmsRefresh = setStrengthInArmsState,
    },
    engineHandlers = {
        onInit = function(initData)
            setStrengthInArmsState(initData)
        end,
        onLoad = function(savedData, initData)
            if type(savedData) == "table" then
                setStrengthInArmsState(savedData)
            else
                setStrengthInArmsState(initData)
            end
        end,
        onSave = function()
            return {
                enabled = strengthInArmsEnabled,
                damageBonus = strengthInArmsDamageBonus,
                platebreakerEnabled = platebreakerEnabled,
                breathstealerEnabled = breathstealerEnabled,
                heavyHitterEnabled = heavyHitterEnabled,
                staggeringBlowEnabled = staggeringBlowEnabled,
                ironBellEnabled = ironBellEnabled,
                playerId = strengthInArmsPlayerId,
            }
        end,
    },
}

    blunt.eventHandlers = script.eventHandlers or {}
    blunt.engineHandlers = script.engineHandlers or {}
    blunt.onHit = onHit
end

-- 5. duelist tempo target state/effects
do
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

local script = {
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

    duelistTempo.eventHandlers = script.eventHandlers or {}
    duelistTempo.engineHandlers = script.engineHandlers or {}
    duelistTempo.onHit = onHit
end

-- 6. aegis rite target state/effects
do
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")

local primedPlayerId = nil
local remainingTime = 0

local function setState(data)
    if type(data) ~= "table" then
        return
    end

    if type(data.playerId) == "string" then
        primedPlayerId = data.playerId
    end
    if data.duration ~= nil then
        remainingTime = math.max(0, tonumber(data.duration) or 0)
    end
end

local function clearAndRequestRemoval()
    remainingTime = 0
    core.sendGlobalEvent("SkillPerkSystem_RemoveAegisRiteTarget", {
        target = selfObj,
    })
end

local function isSuccessfulPlayerMeleeHit(attack)
    if type(attack) ~= "table" then
        return false
    end
    if attack.attacker == nil then
        return false
    end
    if type(primedPlayerId) ~= "string" or primedPlayerId == "" then
        return false
    end
    if attack.attacker.id ~= primedPlayerId then
        return false
    end
    if attack.successful ~= true then
        return false
    end

    local combatInterface = interfaces.Combat
    local meleeType = combatInterface and combatInterface.ATTACK_SOURCE_TYPES and combatInterface.ATTACK_SOURCE_TYPES.Melee or nil
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return true
end

local function onHit(attack)
    if remainingTime <= 0 then
        return
    end
    if not isSuccessfulPlayerMeleeHit(attack) then
        return
    end

    if attack.attacker ~= nil and attack.attacker:isValid() then
        attack.attacker:sendEvent("SkillPerkSystem_TryConsumeAegisRite", {
            target = selfObj,
        })
    end

    remainingTime = 0
end

local script = {
    eventHandlers = {
        SkillPerkSystem_AegisRiteRefresh = function(data)
            setState(data)
        end,
    },
    engineHandlers = {
        onInit = function(initData)
            setState(initData)
        end,
        onLoad = function(savedData, initData)
            if type(savedData) == "table" then
                setState(savedData)
            else
                setState(initData)
            end
        end,
        onSave = function()
            return {
                playerId = primedPlayerId,
                duration = remainingTime,
            }
        end,
        onUpdate = function(dt)
            if remainingTime <= 0 then
                return
            end

            remainingTime = math.max(0, remainingTime - (tonumber(dt) or 0))
            if remainingTime <= 0 then
                clearAndRequestRemoval()
            end
        end,
    },
}

    aegisRite.eventHandlers = script.eventHandlers or {}
    aegisRite.engineHandlers = script.engineHandlers or {}
    aegisRite.onHit = onHit
end

-- 7. combined eventHandlers
local eventHandlers = {}

local function copyEventHandlers(source)
    for name, handler in pairs(source or {}) do
        eventHandlers[name] = handler
    end
end

copyEventHandlers(axe.eventHandlers)
copyEventHandlers(blunt.eventHandlers)
copyEventHandlers(duelistTempo.eventHandlers)
copyEventHandlers(aegisRite.eventHandlers)

local function combinedOnHit(attack)
    axe.onHit(attack)
    blunt.onHit(attack)
    duelistTempo.onHit(attack)
    aegisRite.onHit(attack)
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(combinedOnHit)
end

-- 8. combined engineHandlers
local function callEngineHandler(subsystem, name, ...)
    local handler = subsystem.engineHandlers ~= nil and subsystem.engineHandlers[name] or nil
    if type(handler) == "function" then
        handler(...)
    end
end

return {
    eventHandlers = eventHandlers,
    engineHandlers = {
        onInit = function(initData)
            callEngineHandler(axe, "onInit", initData)
            callEngineHandler(blunt, "onInit", initData)
            callEngineHandler(duelistTempo, "onInit", initData)
            callEngineHandler(aegisRite, "onInit", initData)
        end,
        onLoad = function(savedData, initData)
            local axeData = type(savedData) == "table" and type(savedData.axe) == "table" and savedData.axe or savedData
            local bluntData = type(savedData) == "table" and type(savedData.blunt) == "table" and savedData.blunt or savedData
            local duelistTempoData = type(savedData) == "table" and type(savedData.duelistTempo) == "table" and savedData.duelistTempo or savedData
            local aegisRiteData = type(savedData) == "table" and type(savedData.aegisRite) == "table" and savedData.aegisRite or savedData

            callEngineHandler(axe, "onLoad", axeData, initData)
            callEngineHandler(blunt, "onLoad", bluntData, initData)
            callEngineHandler(duelistTempo, "onLoad", duelistTempoData, initData)
            callEngineHandler(aegisRite, "onLoad", aegisRiteData, initData)
        end,
        onSave = function()
            return {
                axe = type(axe.engineHandlers.onSave) == "function" and axe.engineHandlers.onSave() or nil,
                blunt = type(blunt.engineHandlers.onSave) == "function" and blunt.engineHandlers.onSave() or nil,
                duelistTempo = type(duelistTempo.engineHandlers.onSave) == "function" and duelistTempo.engineHandlers.onSave() or nil,
                aegisRite = type(aegisRite.engineHandlers.onSave) == "function" and aegisRite.engineHandlers.onSave() or nil,
            }
        end,
        onUpdate = function(dt)
            callEngineHandler(axe, "onUpdate", dt)
            callEngineHandler(blunt, "onUpdate", dt)
            callEngineHandler(duelistTempo, "onUpdate", dt)
            callEngineHandler(aegisRite, "onUpdate", dt)
        end,
    },
}
