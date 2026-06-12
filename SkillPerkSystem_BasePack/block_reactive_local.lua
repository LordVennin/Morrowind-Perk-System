local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon
local Lockpick = types.Lockpick
local Probe = types.Probe
local Repair = types.Repair

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local REACTIVE_ENCHANTING_PERK_ID = "block_reactive_enchanting"

local function perkEnabled(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local owned = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId) or false
    local enabled = owned
    if owned and type(playerApi.isPerkEffectEnabled) == "function" then
        enabled = playerApi.isPerkEffectEnabled(perkId)
    end

    return owned and enabled
end

local function getEquippedItem(actor, slot)
    if actor == nil or Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local ok, equipped = pcall(Actor.getEquipment, actor, slot)
    if not ok then
        return nil
    end

    return equipped
end

local function getEquippedShield(actor)
    if actor == nil or Actor == nil then
        return nil, nil
    end

    local carriedLeftSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedLeft or nil
    if carriedLeftSlot == nil then
        return nil, nil
    end

    local equipped = getEquippedItem(actor, carriedLeftSlot)
    if equipped == nil then
        return nil, nil
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return nil, nil
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, equipped)
        if okRecord then
            record = value
        end
    end

    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil, nil
    end

    return equipped, record
end

local function getEquippedRightHand(actor)
    if actor == nil or Actor == nil then
        return nil
    end

    local rightSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedRight or nil
    if rightSlot == nil then
        return nil
    end

    return getEquippedItem(actor, rightSlot)
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local ok, record = pcall(Weapon.record, item)
        if ok and record ~= nil then
            return record
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    return nil
end

local function isOneHandedWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil then
        return true
    end

    local weaponType = tonumber(record.type)
    if weaponType == nil then
        return true
    end

    if weaponType == 2 then return false end
    if weaponType == 4 then return false end
    if weaponType == 5 then return false end
    if weaponType == 6 then return false end
    if weaponType == 8 then return false end
    if weaponType == 9 then return false end
    if weaponType == 10 then return false end
    if weaponType == 11 then return false end
    if weaponType == 12 then return false end
    if weaponType == 13 then return false end

    return true
end

local function isTool(item)
    if item == nil then
        return false
    end

    if Lockpick ~= nil and type(Lockpick.objectIsInstance) == "function" and Lockpick.objectIsInstance(item) then
        return true
    end
    if Probe ~= nil and type(Probe.objectIsInstance) == "function" and Probe.objectIsInstance(item) then
        return true
    end
    if Repair ~= nil and type(Repair.objectIsInstance) == "function" and Repair.objectIsInstance(item) then
        return true
    end

    return false
end

local function hasValidReactiveShieldSetup(actor)
    local shield = getEquippedShield(actor)
    if shield == nil then
        return false
    end

    local rightHand = getEquippedRightHand(actor)
    if rightHand == nil then
        return false
    end

    return isOneHandedWeapon(rightHand) or isTool(rightHand)
end

local function wasSuccessfulShieldBlock(attack)
    if type(attack) ~= "table" then
        return false
    end

    local blockedFlag = attack.blocked == true or attack.isBlocked == true or attack.block == true
    local blockedBy = string.lower(tostring(attack.blockedBy or attack.blockType or attack.defenseType or ""))
    local isParry = attack.parried == true or attack.isParry == true or blockedBy:find("parry", 1, true) ~= nil

    if isParry then
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
    if attack.successful == true and totalDamage <= 0 then
        return true
    end

    return false
end

local function buildPayload(attack)
    local attacker = attack.attacker
    if attacker == nil then
        return nil
    end

    local shield, shieldRecord = getEquippedShield(selfObj)
    if shield == nil or shieldRecord == nil then
        return nil
    end

    local enchantmentId = shieldRecord.enchant or shieldRecord.enchantment
    if type(enchantmentId) == "table" and type(enchantmentId.id) == "string" then
        enchantmentId = enchantmentId.id
    end
    if type(enchantmentId) ~= "string" or enchantmentId == "" then
        return nil
    end

    return {
        blocker = selfObj,
        attacker = attacker,
        shield = shield,
        enchantmentId = enchantmentId,
    }
end

local function onHit(attack)
    if not perkEnabled(REACTIVE_ENCHANTING_PERK_ID) then
        return
    end
    if not wasSuccessfulShieldBlock(attack) then
        return
    end
    if not hasValidReactiveShieldSetup(selfObj) then
        return
    end

    local payload = buildPayload(attack)
    if payload == nil then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyReactiveShieldEnchant", payload)
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    engineHandlers = {},
}
