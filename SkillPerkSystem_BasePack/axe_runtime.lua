local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local KINDLING_GRIP_PERK_ID = "axe_kindling_grip"
local KINDLING_GRIP_BONUS_MULTIPLIER = 0.10

local runtimeTime = 0
local lastKindlingGripTarget = nil
local lastKindlingGripApplyTime = -1

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function kindlingGripEnabled()
    return hasEnabledPerk(KINDLING_GRIP_PERK_ID)
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

local function getEquippedItem(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getEquippedAxe()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local slot = Actor.EQUIPMENT_SLOT.CarriedRight
    if slot == nil then
        return nil
    end

    local weapon = getEquippedItem(slot)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isAxeRecord(record) then
        return nil
    end

    return weapon
end

local function isValidTarget(target)
    if target == nil then
        return false
    end
    if type(target.isValid) == "function" and not target:isValid() then
        return false
    end
    if Actor ~= nil and type(Actor.isDead) == "function" and Actor.isDead(target) then
        return false
    end

    return true
end

local function getAttackTarget(attack)
    if type(attack) ~= "table" then
        return nil
    end

    return attack.target or attack.victim or attack.defender or attack.hitObject or attack.object
end

local function getAttackHealthDamage(data)
    if type(data) ~= "table" then
        return 0
    end

    local damage = data.damage
    if type(damage) ~= "table" and type(data.attack) == "table" then
        damage = data.attack.damage
    end
    if type(damage) ~= "table" then
        return 0
    end

    return math.max(0, tonumber(damage.health) or 0)
end

local function recentlyAppliedKindlingGrip(target)
    return target ~= nil and target == lastKindlingGripTarget and (runtimeTime - lastKindlingGripApplyTime) < 0.05
end

local function rememberKindlingGripApplication(target)
    lastKindlingGripTarget = target
    lastKindlingGripApplyTime = runtimeTime
end

local function applyKindlingGripDamage(target, damage)
    if target == nil or type(target.sendEvent) ~= "function" then
        return
    end

    target:sendEvent("SkillPerkSystem_ApplyAxeKindlingGripDamage", {
        damage = damage,
    })
end

local function tryApplyKindlingGrip(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target == nil and type(data.attack) == "table" then
        target = getAttackTarget(data.attack)
    end

    if not isValidTarget(target) then
        return
    end
    if not kindlingGripEnabled() or getEquippedAxe() == nil then
        return
    end
    if recentlyAppliedKindlingGrip(target) then
        return
    end

    local bonusDamage = getAttackHealthDamage(data) * KINDLING_GRIP_BONUS_MULTIPLIER
    if bonusDamage <= 0 then
        return
    end

    rememberKindlingGripApplication(target)
    applyKindlingGripDamage(target, bonusDamage)
end

local function isSuccessfulPlayerMeleeHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
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

    tryApplyKindlingGrip({
        attack = attack,
        target = getAttackTarget(attack),
        damage = attack.damage,
    })
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    eventHandlers = {
        SkillPerkSystem_TryAxeKindlingGrip = tryApplyKindlingGrip,
    },
    engineHandlers = {
        onUpdate = function(dt)
            runtimeTime = runtimeTime + (tonumber(dt) or 0)
        end,
        onLoad = function()
            runtimeTime = 0
            lastKindlingGripTarget = nil
            lastKindlingGripApplyTime = -1
        end,
    },
}
