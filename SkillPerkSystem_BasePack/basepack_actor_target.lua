-- Consolidated CUSTOM actor-side target runtime for SkillPerkSystem_BasePack.
-- Supersedes axe_target.lua, bluntweapon_target.lua, duelists_tempo_target.lua, and aegis_rite_target.lua.

-- 1. shared requires/constants/helpers
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")

local axe = {}
local spear = {}
local blunt = {}
local duelistTempo = {}
local aegisRite = {}
local handToHand = {}
local TARGET_SCRIPT_IDLE_EVENT = "SkillPerkSystem_BasePack_TargetScriptIdle"

-- 2. shared actor/stat/weapon/combat helpers
-- Subsystem-specific copies remain local below to preserve existing behavior and API fallbacks.

-- 3. axe target state/effects
do
local core = require("openmw.core")
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
local THROWN_FUNDAMENTALS_DURATION = 3.0
local TRICK_THROW_THROWN_BLEED_DURATION = 5.0
local THROWN_FUNDAMENTALS_DAMAGE_INTERVAL = 1.0
local THROWN_FUNDAMENTALS_DAMAGE_PER_TICK = 1
local DEADEYE_MASTERY_THROWN_BLEED_DURATION = 5.0
local DEADEYE_MASTERY_THROWN_DAMAGE_PER_TICK = 0.5
local THROWN_FUNDAMENTALS_BLOOD_INTERVAL = 1.0
local PINNING_SHOT_DURATION = 5.0
local PINNING_SHOT_SPEED_PENALTY_PER_STACK = 10
local PINNING_SHOT_MAX_STACKS = 3

local kindlingGripEnabled = false
local kindlingGripPlayerId = nil
local kindlingGripDamageBonusCount = 0
local bloodletterEnabled = false
local draggingWoundEnabled = false
local hewerHeartEnabled = false
local crimsonCleaveEnabled = false
local ironCanopyEnabled = false
local thrownFundamentalsEnabled = false
local trickThrowEnabled = false
local pinningShotEnabled = false
local deadeyeMasteryEnabled = false
local steadyDrawPlayerId = nil
local steadyDrawMultiplier = 1
local steadyDrawExpiresAt = 0
local steadyDrawSequence = 0
local steadyDrawConsumedSequence = 0

local bloodletterRemainingTime = 0
local bloodletterDamageTimer = 0
local bloodletterBloodTimer = 0
local bloodletterDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK
local bloodletterSpeedPenaltyApplied = 0
local hewerHeartRemainingTime = 0
local hewerHeartDamageTimer = 0
local hewerHeartBloodTimer = 0
local hewerHeartDamagePerTick = BLOODLETTER_DAMAGE_PER_TICK
local thrownFundamentalsBleedStacks = {}
local deadeyeMasteryBleedStacks = {}
local pinningShotStacks = {}
local pinningShotSpeedPenaltyApplied = 0

local updateBleedSpeedPenalty
local updatePinningShotSpeedPenalty

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
    thrownFundamentalsEnabled = data.thrownFundamentalsEnabled == true
    trickThrowEnabled = data.trickThrowEnabled == true
    pinningShotEnabled = data.pinningShotEnabled == true
    deadeyeMasteryEnabled = data.deadeyeMasteryEnabled == true
    steadyDrawPlayerId = type(data.steadyDrawPlayerId) == "string" and data.steadyDrawPlayerId or nil
    steadyDrawMultiplier = math.max(1, tonumber(data.steadyDrawMultiplier) or 1)
    steadyDrawExpiresAt = math.max(0, tonumber(data.steadyDrawExpiresAt) or 0)
    steadyDrawSequence = math.max(0, math.floor(tonumber(data.steadyDrawSequence) or 0))
    updateBleedSpeedPenalty()
    updatePinningShotSpeedPenalty()
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


local function applyPinningShotSpeedPenalty(targetPenalty)
    local desired = math.max(0, math.floor(tonumber(targetPenalty) or 0))
    local current = math.max(0, math.floor(tonumber(pinningShotSpeedPenaltyApplied) or 0))
    if desired == current then
        return
    end

    local stat = resolveSpeedStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier + current - desired
    pinningShotSpeedPenaltyApplied = desired
end

updatePinningShotSpeedPenalty = function()
    applyPinningShotSpeedPenalty(math.min(#pinningShotStacks, PINNING_SHOT_MAX_STACKS) * PINNING_SHOT_SPEED_PENALTY_PER_STACK)
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

local function safeObjectField(object, fieldName)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object[fieldName]
    end)
    if not ok then
        return nil
    end

    return value
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

        local recordId = safeObjectField(item, "recordId")
        if type(recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    local recordId = safeObjectField(item, "recordId")
    if type(recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[recordId]
    end

    local itemType = safeObjectField(item, "type")
    if itemType ~= nil and type(itemType.records) == "table" and type(recordId) == "string" then
        return itemType.records[recordId]
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

local function isThrownWeaponRecord(record)
    return weaponTypeEquals(record, "MarksmanThrown")
end

local function isBowOrCrossbowRecord(record)
    return weaponTypeEquals(record, "MarksmanBow") or weaponTypeEquals(record, "MarksmanCrossbow")
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

local function actorHasEquippedThrownWeapon(actor)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(actor, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" then
        local okInstance, isInstance = pcall(Weapon.objectIsInstance, weapon)
        if not okInstance or not isInstance then
            return false
        end
    end

    return isThrownWeaponRecord(getWeaponRecord(weapon))
end

local function actorHasEquippedBowOrCrossbow(actor)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(actor, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" then
        local okInstance, isInstance = pcall(Weapon.objectIsInstance, weapon)
        if not okInstance or not isInstance then
            return false
        end
    end

    return isBowOrCrossbowRecord(getWeaponRecord(weapon))
end

local function actorHasEquippedAxe(actor)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(actor, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" then
        local okInstance, isInstance = pcall(Weapon.objectIsInstance, weapon)
        if not okInstance or not isInstance then
            return false
        end
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


local function getAttackWeaponRecord(attack)
    if type(attack) == "table" and attack.weapon ~= nil then
        return getWeaponRecord(attack.weapon)
    end

    return nil
end

local function isRangedAttack(attack)
    local rangedType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Ranged
    return rangedType == nil or (type(attack) == "table" and attack.sourceType == rangedType)
end

local function isSuccessfulThrownWeaponHit(attack, perkEnabled)
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
    if not isRangedAttack(attack) then
        return false
    end

    local attackWeaponRecord = getAttackWeaponRecord(attack)
    if attackWeaponRecord ~= nil then
        if not isThrownWeaponRecord(attackWeaponRecord) then
            return false
        end
    elseif not actorHasEquippedThrownWeapon(attack.attacker) then
        return false
    end

    return type(attack.damage) == "table" and (tonumber(attack.damage.health) or 0) > 0
end

local function isSuccessfulSteadyDrawHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if type(steadyDrawPlayerId) ~= "string" or steadyDrawPlayerId == "" then
        return false
    end
    if steadyDrawSequence <= 0 or steadyDrawConsumedSequence == steadyDrawSequence then
        return false
    end
    if core.getSimulationTime() >= steadyDrawExpiresAt then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= steadyDrawPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isRangedAttack(attack) then
        return false
    end

    local attackWeaponRecord = getAttackWeaponRecord(attack)
    if attackWeaponRecord ~= nil then
        if not isBowOrCrossbowRecord(attackWeaponRecord) then
            return false
        end
    elseif not actorHasEquippedBowOrCrossbow(attack.attacker) then
        return false
    end

    return type(attack.damage) == "table" and (tonumber(attack.damage.health) or 0) > 0
end

local function applySteadyDrawHit(attack)
    if not isSuccessfulSteadyDrawHit(attack) then
        return
    end

    attack.damage.health = attack.damage.health * steadyDrawMultiplier
    steadyDrawConsumedSequence = steadyDrawSequence
end

local function isSuccessfulPinningShotHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not pinningShotEnabled or type(kindlingGripPlayerId) ~= "string" or kindlingGripPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= kindlingGripPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isRangedAttack(attack) then
        return false
    end

    local attackWeaponRecord = getAttackWeaponRecord(attack)
    if attackWeaponRecord ~= nil then
        if not isBowOrCrossbowRecord(attackWeaponRecord) then
            return false
        end
    elseif not actorHasEquippedBowOrCrossbow(attack.attacker) then
        return false
    end

    return type(attack.damage) == "table" and (tonumber(attack.damage.health) or 0) > 0
end

local function addPinningShotStack()
    if #pinningShotStacks >= PINNING_SHOT_MAX_STACKS then
        table.remove(pinningShotStacks, 1)
    end

    pinningShotStacks[#pinningShotStacks + 1] = {
        remainingTime = PINNING_SHOT_DURATION,
    }
    updatePinningShotSpeedPenalty()
end

local function addThrownFundamentalsBleed(attack)
    if trickThrowEnabled then
        attack.damage.health = attack.damage.health + #thrownFundamentalsBleedStacks + #deadeyeMasteryBleedStacks
    end

    local duration = trickThrowEnabled and TRICK_THROW_THROWN_BLEED_DURATION or THROWN_FUNDAMENTALS_DURATION
    thrownFundamentalsBleedStacks[#thrownFundamentalsBleedStacks + 1] = {
        remainingTime = duration,
        damageTimer = 0,
        bloodTimer = 0,
    }
    spawnBloodSpray(attack.hitPos or selfObj.position)
end

local function clearThrownFundamentalsBleeds()
    thrownFundamentalsBleedStacks = {}
end

local function addDeadeyeMasteryBleed(attack)
    deadeyeMasteryBleedStacks[#deadeyeMasteryBleedStacks + 1] = {
        remainingTime = DEADEYE_MASTERY_THROWN_BLEED_DURATION,
        damageTimer = 0,
        bloodTimer = 0,
    }
    spawnBloodSpray(attack.hitPos or selfObj.position)
end

local function clearDeadeyeMasteryBleeds()
    deadeyeMasteryBleedStacks = {}
end

local function clearPinningShotStacks()
    pinningShotStacks = {}
    updatePinningShotSpeedPenalty()
end

local function onHit(attack)
    if isSuccessfulKindlingGripHit(attack) then
        attack.damage.health = attack.damage.health * (1 + (KINDLING_GRIP_DAMAGE_BONUS * kindlingGripDamageBonusCount))
    end

    applySteadyDrawHit(attack)
    applyIronCanopyHit(attack)

    if isSuccessfulAxeHit(attack, bloodletterEnabled) then
        refreshBloodletterBleed(attack)
    end

    if isSuccessfulAxeHit(attack, hewerHeartEnabled) and isBelowKindlingGripThreshold() then
        refreshHewerHeartBleed(attack)
    end

    if isSuccessfulThrownWeaponHit(attack, thrownFundamentalsEnabled) then
        addThrownFundamentalsBleed(attack)
    end

    if isSuccessfulThrownWeaponHit(attack, deadeyeMasteryEnabled) then
        addDeadeyeMasteryBleed(attack)
    end

    if isSuccessfulPinningShotHit(attack) then
        addPinningShotStack()
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
                thrownFundamentalsBleedStacks = type(savedData.thrownFundamentalsBleedStacks) == "table" and savedData.thrownFundamentalsBleedStacks or {}
                deadeyeMasteryBleedStacks = type(savedData.deadeyeMasteryBleedStacks) == "table" and savedData.deadeyeMasteryBleedStacks or {}
                pinningShotStacks = type(savedData.pinningShotStacks) == "table" and savedData.pinningShotStacks or {}
                pinningShotSpeedPenaltyApplied = math.max(0, math.floor(tonumber(savedData.pinningShotSpeedPenaltyApplied) or 0))
                steadyDrawPlayerId = type(savedData.steadyDrawPlayerId) == "string" and savedData.steadyDrawPlayerId or steadyDrawPlayerId
                steadyDrawMultiplier = math.max(1, tonumber(savedData.steadyDrawMultiplier) or steadyDrawMultiplier)
                steadyDrawExpiresAt = math.max(0, tonumber(savedData.steadyDrawExpiresAt) or steadyDrawExpiresAt)
                steadyDrawSequence = math.max(0, math.floor(tonumber(savedData.steadyDrawSequence) or steadyDrawSequence))
                steadyDrawConsumedSequence = math.max(0, math.floor(tonumber(savedData.steadyDrawConsumedSequence) or steadyDrawConsumedSequence))
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
                thrownFundamentalsEnabled = thrownFundamentalsEnabled,
                trickThrowEnabled = trickThrowEnabled,
                pinningShotEnabled = pinningShotEnabled,
                deadeyeMasteryEnabled = deadeyeMasteryEnabled,
                steadyDrawPlayerId = steadyDrawPlayerId,
                steadyDrawMultiplier = steadyDrawMultiplier,
                steadyDrawExpiresAt = steadyDrawExpiresAt,
                steadyDrawSequence = steadyDrawSequence,
                steadyDrawConsumedSequence = steadyDrawConsumedSequence,
                bloodletterRemainingTime = bloodletterRemainingTime,
                bloodletterDamageTimer = bloodletterDamageTimer,
                bloodletterBloodTimer = bloodletterBloodTimer,
                bloodletterDamagePerTick = bloodletterDamagePerTick,
                bloodletterSpeedPenaltyApplied = bloodletterSpeedPenaltyApplied,
                hewerHeartRemainingTime = hewerHeartRemainingTime,
                hewerHeartDamageTimer = hewerHeartDamageTimer,
                hewerHeartBloodTimer = hewerHeartBloodTimer,
                hewerHeartDamagePerTick = hewerHeartDamagePerTick,
                thrownFundamentalsBleedStacks = thrownFundamentalsBleedStacks,
                deadeyeMasteryBleedStacks = deadeyeMasteryBleedStacks,
                pinningShotStacks = pinningShotStacks,
                pinningShotSpeedPenaltyApplied = pinningShotSpeedPenaltyApplied,
            }
        end,
        onUpdate = function(dt)
            if bloodletterRemainingTime <= 0 and hewerHeartRemainingTime <= 0 and #thrownFundamentalsBleedStacks == 0 and #deadeyeMasteryBleedStacks == 0 and #pinningShotStacks == 0 then
                updateBleedSpeedPenalty()
                updatePinningShotSpeedPenalty()
                return
            end
            if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                clearBloodletterBleed()
                clearHewerHeartBleed()
                clearThrownFundamentalsBleeds()
                clearDeadeyeMasteryBleeds()
                clearPinningShotStacks()
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
                        clearThrownFundamentalsBleeds()
                        clearDeadeyeMasteryBleeds()
                        clearPinningShotStacks()
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
                        clearThrownFundamentalsBleeds()
                        clearDeadeyeMasteryBleeds()
                        clearPinningShotStacks()
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


            for index = #thrownFundamentalsBleedStacks, 1, -1 do
                local stack = thrownFundamentalsBleedStacks[index]
                if type(stack) ~= "table" then
                    table.remove(thrownFundamentalsBleedStacks, index)
                else
                    stack.remainingTime = math.max(0, (tonumber(stack.remainingTime) or 0) - elapsed)
                    stack.damageTimer = (tonumber(stack.damageTimer) or 0) + elapsed
                    stack.bloodTimer = (tonumber(stack.bloodTimer) or 0) + elapsed

                    while stack.remainingTime > 0 and stack.damageTimer >= THROWN_FUNDAMENTALS_DAMAGE_INTERVAL do
                        stack.damageTimer = stack.damageTimer - THROWN_FUNDAMENTALS_DAMAGE_INTERVAL
                        applyHealthDamage(THROWN_FUNDAMENTALS_DAMAGE_PER_TICK)
                        if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                            clearBloodletterBleed()
                            clearHewerHeartBleed()
                            clearThrownFundamentalsBleeds()
                            clearDeadeyeMasteryBleeds()
                            clearPinningShotStacks()
                            return
                        end
                    end

                    if stack.remainingTime <= 0 then
                        table.remove(thrownFundamentalsBleedStacks, index)
                    elseif stack.bloodTimer >= THROWN_FUNDAMENTALS_BLOOD_INTERVAL then
                        stack.bloodTimer = 0
                        spawnBloodSpray(selfObj.position)
                    end
                end
            end


            for index = #deadeyeMasteryBleedStacks, 1, -1 do
                local stack = deadeyeMasteryBleedStacks[index]
                if type(stack) ~= "table" then
                    table.remove(deadeyeMasteryBleedStacks, index)
                else
                    stack.remainingTime = math.max(0, (tonumber(stack.remainingTime) or 0) - elapsed)
                    stack.damageTimer = (tonumber(stack.damageTimer) or 0) + elapsed
                    stack.bloodTimer = (tonumber(stack.bloodTimer) or 0) + elapsed

                    while stack.remainingTime > 0 and stack.damageTimer >= THROWN_FUNDAMENTALS_DAMAGE_INTERVAL do
                        stack.damageTimer = stack.damageTimer - THROWN_FUNDAMENTALS_DAMAGE_INTERVAL
                        applyHealthDamage(DEADEYE_MASTERY_THROWN_DAMAGE_PER_TICK)
                        if type(Actor.isDead) == "function" and Actor.isDead(selfObj) then
                            clearBloodletterBleed()
                            clearHewerHeartBleed()
                            clearThrownFundamentalsBleeds()
                            clearDeadeyeMasteryBleeds()
                            clearPinningShotStacks()
                            return
                        end
                    end

                    if stack.remainingTime <= 0 then
                        table.remove(deadeyeMasteryBleedStacks, index)
                    elseif stack.bloodTimer >= THROWN_FUNDAMENTALS_BLOOD_INTERVAL then
                        stack.bloodTimer = 0
                        spawnBloodSpray(selfObj.position)
                    end
                end
            end

            for index = #pinningShotStacks, 1, -1 do
                local stack = pinningShotStacks[index]
                if type(stack) ~= "table" then
                    table.remove(pinningShotStacks, index)
                else
                    stack.remainingTime = math.max(0, (tonumber(stack.remainingTime) or 0) - elapsed)
                    if stack.remainingTime <= 0 then
                        table.remove(pinningShotStacks, index)
                    end
                end
            end

            updateBleedSpeedPenalty()
            updatePinningShotSpeedPenalty()
        end,
    },
}

    axe.eventHandlers = script.eventHandlers or {}
    axe.engineHandlers = script.engineHandlers or {}
    axe.hasActiveState = function()
        return bloodletterRemainingTime > 0
            or bloodletterSpeedPenaltyApplied > 0
            or hewerHeartRemainingTime > 0
            or #thrownFundamentalsBleedStacks > 0
            or #deadeyeMasteryBleedStacks > 0
            or #pinningShotStacks > 0
            or pinningShotSpeedPenaltyApplied > 0
            or kindlingGripEnabled
            or bloodletterEnabled
            or draggingWoundEnabled
            or hewerHeartEnabled
            or crimsonCleaveEnabled
            or ironCanopyEnabled
            or thrownFundamentalsEnabled
            or trickThrowEnabled
            or pinningShotEnabled
            or deadeyeMasteryEnabled
            or steadyDrawMultiplier > 1
    end
    axe.onHit = onHit
end

-- 4. spear target state/effects
do
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local POINT_CONTROL_DAMAGE_MULTIPLIER = 1.05
local HOOK_AND_TURN_WINDOW = 5.0
local HOOK_AND_TURN_HEALTH_MULTIPLIER = 1.15
local HOOK_AND_TURN_FATIGUE_DAMAGE = 10

local pointControlEnabled = false
local hookAndTurnEnabled = false
local pointControlPlayerId = nil
local hookAndTurnPrimedUntil = 0

local function setPointControlState(data)
    if type(data) ~= "table" then
        return
    end

    pointControlEnabled = data.pointControlEnabled == true
    hookAndTurnEnabled = data.hookAndTurnEnabled == true
    pointControlPlayerId = type(data.playerId) == "string" and data.playerId or nil

    if not hookAndTurnEnabled then
        hookAndTurnPrimedUntil = 0
    end
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

local function isSpearRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.SpearTwoWide)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function getAttackWeaponRecord(attack)
    if type(attack) == "table" and attack.weapon ~= nil then
        return getWeaponRecord(attack.weapon)
    end

    return nil
end

local function attackHasSpearWeapon(attack)
    local record = getAttackWeaponRecord(attack)
    return record ~= nil and isSpearRecord(record)
end

local function actorHasEquippedSpear(actor)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(actor, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" then
        local okInstance, isInstance = pcall(Weapon.objectIsInstance, weapon)
        if not okInstance or not isInstance then
            return false
        end
    end

    return isSpearRecord(getWeaponRecord(weapon))
end

local function isSpearAttack(attack)
    if attackHasSpearWeapon(attack) then
        return true
    end

    return type(attack) == "table" and actorHasEquippedSpear(attack.attacker)
end

local function isMeleeAttack(attack)
    local sourceTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_SOURCE_TYPES or nil
    local expected = sourceTypes ~= nil and sourceTypes.Melee or nil
    if expected == nil then
        return true
    end

    local actual = type(attack) == "table" and attack.sourceType or nil
    return actual == nil or actual == expected or tonumber(actual) == tonumber(expected)
end

local function isAttackType(attack, typeName)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    local expected = attackTypes ~= nil and tonumber(attackTypes[typeName]) or nil
    local actual = type(attack) == "table" and tonumber(attack.type) or nil
    return expected ~= nil and actual ~= nil and actual == expected
end

local function logHookAndTurn(attack, message, now, healthBefore, fatigueBefore, healthAfter, fatigueAfter)
    now = now or core.getSimulationTime()
    print(
        "[SkillPerkSystem_BasePack][Spear][HookAndTurn] "
        .. "message=" .. tostring(message)
        .. " enabled=" .. tostring(hookAndTurnEnabled)
        .. " attacker=" .. tostring(type(attack) == "table" and attack.attacker and attack.attacker.id)
        .. " playerId=" .. tostring(pointControlPlayerId)
        .. " sourceType=" .. tostring(type(attack) == "table" and attack.sourceType)
        .. " type=" .. tostring(type(attack) == "table" and attack.type)
        .. " chop=" .. tostring(isAttackType(attack, "Chop"))
        .. " slash=" .. tostring(isAttackType(attack, "Slash"))
        .. " thrust=" .. tostring(isAttackType(attack, "Thrust"))
        .. " primedUntil=" .. tostring(hookAndTurnPrimedUntil)
        .. " now=" .. tostring(now)
        .. " health=" .. tostring(type(attack) == "table" and attack.damage and attack.damage.health)
        .. " fatigue=" .. tostring(type(attack) == "table" and attack.damage and attack.damage.fatigue)
        .. " healthBefore=" .. tostring(healthBefore)
        .. " fatigueBefore=" .. tostring(fatigueBefore)
        .. " healthAfter=" .. tostring(healthAfter)
        .. " fatigueAfter=" .. tostring(fatigueAfter)
    )
end

local function isSuccessfulPointControlHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not pointControlEnabled or type(pointControlPlayerId) ~= "string" or pointControlPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= pointControlPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if type(attack.damage) ~= "table" or (tonumber(attack.damage.health) or 0) <= 0 then
        return false
    end

    return isSpearAttack(attack)
end

local function isSuccessfulHookAndTurnHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if not hookAndTurnEnabled or type(pointControlPlayerId) ~= "string" or pointControlPlayerId == "" then
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= pointControlPlayerId then
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if type(attack.damage) ~= "table" then
        return false
    end

    return isSpearAttack(attack)
end

local function applyPointControlDamage(attack)
    if isSuccessfulPointControlHit(attack) then
        attack.damage.health = (tonumber(attack.damage.health) or 0) * POINT_CONTROL_DAMAGE_MULTIPLIER
    end
end

local function applyHookAndTurn(attack)
    local now = core.getSimulationTime()
    local healthBefore = type(attack) == "table" and attack.damage and attack.damage.health or nil
    local fatigueBefore = type(attack) == "table" and attack.damage and attack.damage.fatigue or nil
    logHookAndTurn(attack, "evaluating", now, healthBefore, fatigueBefore)

    if not isSuccessfulHookAndTurnHit(attack) then
        return
    end

    if isAttackType(attack, "Chop") or isAttackType(attack, "Slash") then
        hookAndTurnPrimedUntil = now + HOOK_AND_TURN_WINDOW
        logHookAndTurn(attack, "primed", now, healthBefore, fatigueBefore)
        return
    end

    if not isAttackType(attack, "Thrust") then
        return
    end

    if hookAndTurnPrimedUntil <= 0 or hookAndTurnPrimedUntil < now then
        hookAndTurnPrimedUntil = 0
        logHookAndTurn(attack, "thrust_without_active_prime", now, healthBefore, fatigueBefore)
        return
    end

    hookAndTurnPrimedUntil = 0
    attack.damage.health = (tonumber(attack.damage.health) or 0) * HOOK_AND_TURN_HEALTH_MULTIPLIER
    attack.damage.fatigue = (tonumber(attack.damage.fatigue) or 0) + HOOK_AND_TURN_FATIGUE_DAMAGE
    logHookAndTurn(
        attack,
        "consumed_prime",
        now,
        healthBefore,
        fatigueBefore,
        attack.damage.health,
        attack.damage.fatigue
    )
end

local function onHit(attack)
    applyPointControlDamage(attack)
    applyHookAndTurn(attack)
end

spear.eventHandlers = {
    SkillPerkSystem_SpearPointControlRefresh = setPointControlState,
}

spear.engineHandlers = {
    onInit = function(initData)
        setPointControlState(initData)
    end,
    onLoad = function(savedData, initData)
        if type(savedData) == "table" then
            setPointControlState(savedData)
            hookAndTurnPrimedUntil = math.max(0, tonumber(savedData.hookAndTurnPrimedUntil) or 0)
        else
            setPointControlState(initData)
        end
    end,
    onSave = function()
        return {
            playerId = pointControlPlayerId,
            pointControlEnabled = pointControlEnabled,
            hookAndTurnEnabled = hookAndTurnEnabled,
            hookAndTurnPrimedUntil = hookAndTurnPrimedUntil,
        }
    end,
}

spear.hasActiveState = function()
    return pointControlEnabled or hookAndTurnEnabled or hookAndTurnPrimedUntil > 0
end

spear.onHit = onHit

end

-- 5. blunt weapon target state/effects
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
    blunt.hasActiveState = function()
        return strengthInArmsEnabled
            or strengthInArmsDamageBonus > 0
            or platebreakerEnabled
            or breathstealerEnabled
            or heavyHitterEnabled
            or staggeringBlowEnabled
            or ironBellEnabled
    end
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

local function applyDirectHealthDamage(data)
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
    attack.attacker:sendEvent("SkillPerkSystem_TryIronKnucklesDamage", {
        target = selfObj,
    })
    attack.attacker:sendEvent("SkillPerkSystem_TryOpenPalm", {
        target = selfObj,
    })
end

local script = {
    eventHandlers = {
        SkillPerkSystem_DuelistsTempoRefresh = setState,
        SkillPerkSystem_ApplyLongBladeCriticalDamage = applyDirectHealthDamage,
        SkillPerkSystem_ApplyIronKnucklesDamage = applyDirectHealthDamage,
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
    duelistTempo.hasActiveState = function()
        return remainingTime > 0 or appliedPenalty ~= 0
    end
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
    aegisRite.hasActiveState = function()
        return remainingTime > 0
    end
    aegisRite.onHit = onHit
end

-- 7. combined eventHandlers
local eventHandlers = {}

local function copyEventHandlers(source)
    for name, handler in pairs(source or {}) do
        eventHandlers[name] = handler
    end
end


-- 7b. hand-to-hand target damage modifiers
do
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local IRON_KNUCKLES_FATIGUE_DIVISOR = 30
local BREAKING_FIST_FATIGUE_DAMAGE_MULTIPLIER = 0.50
local BREAKING_FIST_HEALTH_DAMAGE_MIN = 5
local BREAKING_FIST_HEALTH_DAMAGE_MAX = 15
local FLOWING_COUNTER_LIGHT_MAGICKA_DAMAGE_MIN = 10
local FLOWING_COUNTER_LIGHT_MAGICKA_DAMAGE_MAX = 20
local FLOWING_COUNTER_MEDIUM_HEALTH_DAMAGE_MIN = 1
local FLOWING_COUNTER_MEDIUM_HEALTH_DAMAGE_MAX = 5
local FLOWING_COUNTER_HEAVY_HEALTH_DAMAGE_MIN = 5
local FLOWING_COUNTER_HEAVY_HEALTH_DAMAGE_MAX = 10

local playerId = nil
local ironKnucklesEnabled = false
local breakingFistEnabled = false
local flowingCounterMode = "none"
local emptyBodyMasteryEnabled = false
local EMPTY_BODY_DEBUG = false

local function logEmptyBodyDebug(message)
    if EMPTY_BODY_DEBUG then
        print("[SkillPerkSystem_BasePack][EmptyBody][Target][debug] " .. tostring(message))
    end
end

local function setState(data)
    if type(data) ~= "table" then
        return
    end

    playerId = type(data.playerId) == "string" and data.playerId or nil
    ironKnucklesEnabled = data.ironKnucklesEnabled == true
    breakingFistEnabled = data.breakingFistEnabled == true
    flowingCounterMode = type(data.flowingCounterMode) == "string" and data.flowingCounterMode or "none"
    emptyBodyMasteryEnabled = data.emptyBodyMasteryEnabled == true
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

local function itemIsWeapon(item)
    return item ~= nil and Weapon ~= nil and type(Weapon.objectIsInstance) == "function" and Weapon.objectIsInstance(item)
end

local function getCurrentFatigue(actor)
    local fatigueAccessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.dynamic ~= nil
        and Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(actor)
    if fatigue == nil then
        return 0
    end

    return math.max(0, tonumber(fatigue.current) or 0)
end

local function isPlayerHandToHandHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        logEmptyBodyDebug("rejected hit: missing attack table or unsuccessful")
        return false
    end
    if type(attack.damage) ~= "table" then
        logEmptyBodyDebug("rejected hit: missing damage table")
        return false
    end
    if attack.attacker == nil or attack.attacker.id ~= playerId then
        logEmptyBodyDebug(
            "rejected hit: attacker mismatch attackerId="
            .. tostring(attack.attacker ~= nil and attack.attacker.id or nil)
            .. " playerId="
            .. tostring(playerId)
        )
        return false
    end
    if type(attack.attacker.isValid) == "function" and not attack.attacker:isValid() then
        logEmptyBodyDebug("rejected hit: attacker invalid")
        return false
    end

    local meleeType = interfaces.Combat ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES ~= nil
        and interfaces.Combat.ATTACK_SOURCE_TYPES.Melee
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        logEmptyBodyDebug("rejected hit: sourceType=" .. tostring(attack.sourceType) .. " meleeType=" .. tostring(meleeType))
        return false
    end

    if itemIsWeapon(attack.weapon) then
        logEmptyBodyDebug("rejected hit: attack weapon is a Weapon instance")
        return false
    end

    if Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        logEmptyBodyDebug("rejected hit: equipment slots unavailable")
        return false
    end

    local carriedRight = getEquippedItem(attack.attacker, Actor.EQUIPMENT_SLOT.CarriedRight)
    if itemIsWeapon(carriedRight) then
        logEmptyBodyDebug("rejected hit: carried right is a Weapon instance")
        return false
    end

    return true
end

local function onHit(attack)
    if not ironKnucklesEnabled
        and not breakingFistEnabled
        and flowingCounterMode == "none"
        and not emptyBodyMasteryEnabled then
        return
    end
    if not isPlayerHandToHandHit(attack) then
        return
    end

    if emptyBodyMasteryEnabled then
        logEmptyBodyDebug("sending request attackType=" .. tostring(attack.type))
        attack.attacker:sendEvent("SkillPerkSystem_TryEmptyBodyMastery", {
            target = selfObj,
            attackType = attack.type,
        })
    end

    if ironKnucklesEnabled then
        local bonusDamage = getCurrentFatigue(attack.attacker) / IRON_KNUCKLES_FATIGUE_DIVISOR
        if bonusDamage > 0 then
            attack.damage.health = (tonumber(attack.damage.health) or 0) + bonusDamage
        end
    end

    if breakingFistEnabled then
        local fatigueDamage = tonumber(attack.damage.fatigue) or 0
        if fatigueDamage > 0 then
            attack.damage.fatigue = fatigueDamage * BREAKING_FIST_FATIGUE_DAMAGE_MULTIPLIER
        end

        attack.damage.health = (tonumber(attack.damage.health) or 0)
            + math.random(BREAKING_FIST_HEALTH_DAMAGE_MIN, BREAKING_FIST_HEALTH_DAMAGE_MAX)
    end

    if flowingCounterMode == "light" then
        attack.damage.magicka = (tonumber(attack.damage.magicka) or 0)
            + math.random(FLOWING_COUNTER_LIGHT_MAGICKA_DAMAGE_MIN, FLOWING_COUNTER_LIGHT_MAGICKA_DAMAGE_MAX)
    elseif flowingCounterMode == "medium" then
        attack.damage.health = (tonumber(attack.damage.health) or 0)
            + math.random(FLOWING_COUNTER_MEDIUM_HEALTH_DAMAGE_MIN, FLOWING_COUNTER_MEDIUM_HEALTH_DAMAGE_MAX)
    elseif flowingCounterMode == "heavy" then
        attack.damage.health = (tonumber(attack.damage.health) or 0)
            + math.random(FLOWING_COUNTER_HEAVY_HEALTH_DAMAGE_MIN, FLOWING_COUNTER_HEAVY_HEALTH_DAMAGE_MAX)
    end
end

handToHand.eventHandlers = {
    SkillPerkSystem_HandToHandRefresh = setState,
}
handToHand.hasActiveState = function()
    return ironKnucklesEnabled or breakingFistEnabled or flowingCounterMode ~= "none" or emptyBodyMasteryEnabled
end

handToHand.engineHandlers = {
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
            playerId = playerId,
            ironKnucklesEnabled = ironKnucklesEnabled,
            breakingFistEnabled = breakingFistEnabled,
            flowingCounterMode = flowingCounterMode,
            emptyBodyMasteryEnabled = emptyBodyMasteryEnabled,
        }
    end,
}
handToHand.onHit = onHit

end

copyEventHandlers(axe.eventHandlers)
copyEventHandlers(spear.eventHandlers)
copyEventHandlers(blunt.eventHandlers)
copyEventHandlers(duelistTempo.eventHandlers)
copyEventHandlers(aegisRite.eventHandlers)
copyEventHandlers(handToHand.eventHandlers)

local function combinedOnHit(attack)
    handToHand.onHit(attack)
    axe.onHit(attack)
    spear.onHit(attack)
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

local function subsystemHasActiveState(subsystem)
    return subsystem ~= nil and type(subsystem.hasActiveState) == "function" and subsystem.hasActiveState() == true
end

local function hasAnyActiveTargetState()
    return subsystemHasActiveState(axe)
        or subsystemHasActiveState(spear)
        or subsystemHasActiveState(blunt)
        or subsystemHasActiveState(duelistTempo)
        or subsystemHasActiveState(aegisRite)
        or subsystemHasActiveState(handToHand)
end

local function requestRemovalIfIdle()
    if hasAnyActiveTargetState() then
        return
    end
    core.sendGlobalEvent(TARGET_SCRIPT_IDLE_EVENT, {
        target = require("openmw.self"),
    })
end

local function callActiveUpdate(subsystem, dt)
    if subsystemHasActiveState(subsystem) then
        callEngineHandler(subsystem, "onUpdate", dt)
    end
end

return {
    eventHandlers = eventHandlers,
    engineHandlers = {
        onInit = function(initData)
            callEngineHandler(axe, "onInit", initData)
            callEngineHandler(spear, "onInit", initData)
            callEngineHandler(blunt, "onInit", initData)
            callEngineHandler(duelistTempo, "onInit", initData)
            callEngineHandler(aegisRite, "onInit", initData)
            callEngineHandler(handToHand, "onInit", initData)
        end,
        onLoad = function(savedData, initData)
            local axeData = type(savedData) == "table" and type(savedData.axe) == "table" and savedData.axe or savedData
            local spearData = type(savedData) == "table" and type(savedData.spear) == "table" and savedData.spear or savedData
            local bluntData = type(savedData) == "table" and type(savedData.blunt) == "table" and savedData.blunt or savedData
            local duelistTempoData = type(savedData) == "table" and type(savedData.duelistTempo) == "table" and savedData.duelistTempo or savedData
            local aegisRiteData = type(savedData) == "table" and type(savedData.aegisRite) == "table" and savedData.aegisRite or savedData
            local handToHandData = type(savedData) == "table" and type(savedData.handToHand) == "table" and savedData.handToHand or savedData

            callEngineHandler(axe, "onLoad", axeData, initData)
            callEngineHandler(spear, "onLoad", spearData, initData)
            callEngineHandler(blunt, "onLoad", bluntData, initData)
            callEngineHandler(duelistTempo, "onLoad", duelistTempoData, initData)
            callEngineHandler(aegisRite, "onLoad", aegisRiteData, initData)
            callEngineHandler(handToHand, "onLoad", handToHandData, initData)
        end,
        onSave = function()
            return {
                axe = type(axe.engineHandlers.onSave) == "function" and axe.engineHandlers.onSave() or nil,
                spear = type(spear.engineHandlers.onSave) == "function" and spear.engineHandlers.onSave() or nil,
                blunt = type(blunt.engineHandlers.onSave) == "function" and blunt.engineHandlers.onSave() or nil,
                duelistTempo = type(duelistTempo.engineHandlers.onSave) == "function" and duelistTempo.engineHandlers.onSave() or nil,
                aegisRite = type(aegisRite.engineHandlers.onSave) == "function" and aegisRite.engineHandlers.onSave() or nil,
                handToHand = type(handToHand.engineHandlers.onSave) == "function" and handToHand.engineHandlers.onSave() or nil,
            }
        end,
        onUpdate = function(dt)
            callActiveUpdate(axe, dt)
            callActiveUpdate(spear, dt)
            callActiveUpdate(blunt, dt)
            callActiveUpdate(duelistTempo, dt)
            callActiveUpdate(aegisRite, dt)
            callActiveUpdate(handToHand, dt)
            requestRemovalIfIdle()
        end,
    },
}
