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

local BREATHSTEALER_FATIGUE_DAMAGE = 20

local function setStrengthInArmsState(data)
    if type(data) ~= "table" then
        return
    end

    strengthInArmsEnabled = (data.strengthInArmsEnabled == true or data.enabled == true) and (tonumber(data.damageBonus) or 0) > 0
    strengthInArmsDamageBonus = math.max(0, math.floor(tonumber(data.damageBonus) or 0))
    strengthInArmsPlayerId = type(data.playerId) == "string" and data.playerId or nil
    platebreakerEnabled = data.platebreakerEnabled == true
    breathstealerEnabled = data.breathstealerEnabled == true
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

local function isBluntWeaponRecord(record)
    return weaponTypeEquals(record, "BluntOneHand")
        or weaponTypeEquals(record, "BluntTwoClose")
        or weaponTypeEquals(record, "BluntTwoWide")
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

local function actorHasEquippedBluntWeapon(actor)
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

    return isBluntWeaponRecord(getWeaponRecord(weapon))
end


local function applyFatigueDamage(amount)
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

    fatigue.current = math.max(0, fatigue.current - math.max(0, tonumber(amount) or 0))
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
        conditionDamage = calculatePlatebreakerConditionDamage(attack),
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
        applyFatigueDamage(BREATHSTEALER_FATIGUE_DAMAGE)
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

local function onHit(attack)
    if isSuccessfulStrengthInArmsHit(attack) then
        attack.damage.health = (tonumber(attack.damage.health) or 0) + strengthInArmsDamageBonus
    end
    requestPlatebreakerArmorDamage(attack)
    applyBreathstealerFatigueDamage(attack)
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
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
                playerId = strengthInArmsPlayerId,
            }
        end,
    },
}
