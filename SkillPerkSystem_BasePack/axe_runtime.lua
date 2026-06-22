-- Superseded by scripts/SkillPerkSystem_BasePack/basepack_player.lua; kept temporarily for save/development compatibility.
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BLOODLETTER_PERK_ID = "axe_bloodletter"
local DRAGGING_WOUND_PERK_ID = "axe_dragging_wound"
local HEWER_HEART_PERK_ID = "axe_hewer_heart"
local CRIMSON_CLEAVE_PERK_ID = "axe_crimson_cleave"
local IRON_CANOPY_PERK_ID = "axe_iron_canopy"
local FELLSTAR_CROWN_PERK_ID = "axe_fellstar_crown"
local EXECUTION_DAMAGE_PERK_IDS = {
    "axe_kindling_grip",
    "axe_crescent_hook",
}
local STATE_EVENT = "SkillPerkSystem_AxeKindlingGripState"
local STATE_REFRESH_INTERVAL = 1.0
local FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER = 1.10
local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local FELLSTAR_CROWN_FEATHER_KEY = "axe.fellstar_crown.feather"

local refreshTimer = STATE_REFRESH_INTERVAL
local lastStateKey = nil
local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local appliedAxeFeather = math.max(0, tonumber(effectsSection:get(FELLSTAR_CROWN_FEATHER_KEY)) or 0)

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

local function executionDamagePerkCount()
    local count = 0
    for _, perkID in ipairs(EXECUTION_DAMAGE_PERK_IDS) do
        if hasEnabledPerk(perkID) then
            count = count + 1
        end
    end
    return count
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

local function getEquippedAxeRecord()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
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

    return record
end

local function getEquippedAxeWeight()
    local record = getEquippedAxeRecord()
    if record == nil then
        return 0
    end

    return math.max(0, tonumber(record.weight) or 0)
end

local function modifyFeather(delta)
    if Actor == nil or type(Actor.activeEffects) ~= "function" then
        return false
    end

    local effectType = core.magic and core.magic.EFFECT_TYPE and core.magic.EFFECT_TYPE.Feather
    if effectType == nil then
        return false
    end

    local okEffects, activeEffects = pcall(Actor.activeEffects, pself)
    if not okEffects or activeEffects == nil or type(activeEffects.modify) ~= "function" then
        return false
    end

    local okModify = pcall(activeEffects.modify, activeEffects, delta, effectType)
    return okModify
end

local function refreshFellstarCrownFeather()
    local targetFeather = 0
    if hasEnabledPerk(FELLSTAR_CROWN_PERK_ID) then
        targetFeather = getEquippedAxeWeight()
    end

    if targetFeather == appliedAxeFeather then
        return
    end

    local delta = targetFeather - appliedAxeFeather
    if modifyFeather(delta) then
        appliedAxeFeather = targetFeather
        effectsSection:set(FELLSTAR_CROWN_FEATHER_KEY, appliedAxeFeather)
    end
end

local function isAxeAttackWindupAnimation(groupName, options)
    if type(options) ~= "table" then
        return false
    end

    local stopKeyRaw = options.stopkey or options.stopKey
    local stopKey = type(stopKeyRaw) == "string" and string.lower(stopKeyRaw) or ""
    if string.sub(stopKey, -11) == " max attack" then
        return true
    end

    if type(groupName) ~= "string" then
        return false
    end

    local g = string.lower(groupName)
    return string.find(g, "attack", 1, true) ~= nil
end

interfaces.AnimationController.addPlayBlendedAnimationHandler(function(groupName, options)
    if not hasEnabledPerk(FELLSTAR_CROWN_PERK_ID) then
        return
    end

    if getEquippedAxeRecord() == nil then
        return
    end

    if not isAxeAttackWindupAnimation(groupName, options) then
        return
    end

    local currentSpeed = type(options.speed) == "number" and options.speed or 1.0
    options.speed = currentSpeed * FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER
end)

local function publishState(force)
    local enabledCount = executionDamagePerkCount()
    local bloodletterEnabled = hasEnabledPerk(BLOODLETTER_PERK_ID)
    local draggingWoundEnabled = hasEnabledPerk(DRAGGING_WOUND_PERK_ID)
    local hewerHeartEnabled = hasEnabledPerk(HEWER_HEART_PERK_ID)
    local crimsonCleaveEnabled = hasEnabledPerk(CRIMSON_CLEAVE_PERK_ID)
    local ironCanopyEnabled = hasEnabledPerk(IRON_CANOPY_PERK_ID)
    local stateKey = tostring(enabledCount) .. ":" .. tostring(bloodletterEnabled) .. ":" .. tostring(draggingWoundEnabled) .. ":" .. tostring(hewerHeartEnabled) .. ":" .. tostring(crimsonCleaveEnabled) .. ":" .. tostring(ironCanopyEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        enabled = enabledCount > 0,
        damageBonusCount = enabledCount,
        bloodletterEnabled = bloodletterEnabled,
        draggingWoundEnabled = draggingWoundEnabled,
        hewerHeartEnabled = hewerHeartEnabled,
        crimsonCleaveEnabled = crimsonCleaveEnabled,
        ironCanopyEnabled = ironCanopyEnabled,
    })
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            refreshTimer = refreshTimer + (tonumber(dt) or 0)
            if refreshTimer >= STATE_REFRESH_INTERVAL then
                refreshTimer = 0
                refreshFellstarCrownFeather()
                publishState(false)
            end
        end,
        onLoad = function()
            refreshTimer = STATE_REFRESH_INTERVAL
            lastStateKey = nil
            appliedAxeFeather = math.max(0, tonumber(effectsSection:get(FELLSTAR_CROWN_FEATHER_KEY)) or 0)
            refreshFellstarCrownFeather()
            publishState(true)
        end,
    },
}
