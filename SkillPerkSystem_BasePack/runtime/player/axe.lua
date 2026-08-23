-- Axe player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
local multiplyAnimationSpeed = __basepack_animation.multiplyAnimationSpeed
local registerBasepackAnimationHandler = __basepack_animation.registerHandler
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BLOODLETTER_PERK_ID = "axe_bloodletter"
local THROWN_FUNDAMENTALS_PERK_ID = "marksman_thrown_fundamentals"
local PINNING_SHOT_PERK_ID = "marksman_pinning_shot"
local TRICK_THROW_PERK_ID = "marksman_trick_throw"
local DEADEYE_MASTERY_PERK_ID = "marksman_deadeye_mastery"
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
local FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER = 1.10
local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local FELLSTAR_CROWN_FEATHER_KEY = "axe.fellstar_crown.feather"

local axeStateDirty = true
local axeFeatherDirty = true
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

local function markAxeStateDirty()
    axeStateDirty = true
    axeFeatherDirty = true
end

local function handleAxeAnimation(event)
    markAxeStateDirty()
    if not event.isWeaponAttackWindup then
        return
    end
    if not hasEnabledPerk(FELLSTAR_CROWN_PERK_ID) then
        return
    end
    if getEquippedAxeRecord() == nil then
        return
    end

    multiplyAnimationSpeed(event.options, FELLSTAR_CROWN_ATTACK_SPEED_MULTIPLIER)
end
registerBasepackAnimationHandler(handleAxeAnimation)

local AXE_STATE_PERKS = {
    axe_kindling_grip = true,
    axe_crescent_hook = true,
    axe_bloodletter = true,
    axe_dragging_wound = true,
    axe_hewer_heart = true,
    axe_crimson_cleave = true,
    axe_iron_canopy = true,
    axe_fellstar_crown = true,
    marksman_thrown_fundamentals = true,
    marksman_pinning_shot = true,
    marksman_trick_throw = true,
    marksman_deadeye_mastery = true,
}

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or AXE_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markAxeStateDirty()
end

local function publishState(force)
    local enabledCount = executionDamagePerkCount()
    local bloodletterEnabled = hasEnabledPerk(BLOODLETTER_PERK_ID)
    local draggingWoundEnabled = hasEnabledPerk(DRAGGING_WOUND_PERK_ID)
    local hewerHeartEnabled = hasEnabledPerk(HEWER_HEART_PERK_ID)
    local crimsonCleaveEnabled = hasEnabledPerk(CRIMSON_CLEAVE_PERK_ID)
    local ironCanopyEnabled = hasEnabledPerk(IRON_CANOPY_PERK_ID)
    local thrownFundamentalsEnabled = hasEnabledPerk(THROWN_FUNDAMENTALS_PERK_ID)
    local trickThrowEnabled = hasEnabledPerk(TRICK_THROW_PERK_ID)
    local pinningShotEnabled = hasEnabledPerk(PINNING_SHOT_PERK_ID)
    local deadeyeMasteryEnabled = hasEnabledPerk(DEADEYE_MASTERY_PERK_ID)
    local stateKey = tostring(enabledCount) .. ":" .. tostring(bloodletterEnabled) .. ":" .. tostring(draggingWoundEnabled) .. ":" .. tostring(hewerHeartEnabled) .. ":" .. tostring(crimsonCleaveEnabled) .. ":" .. tostring(ironCanopyEnabled) .. ":" .. tostring(thrownFundamentalsEnabled) .. ":" .. tostring(trickThrowEnabled) .. ":" .. tostring(pinningShotEnabled) .. ":" .. tostring(deadeyeMasteryEnabled)
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
        thrownFundamentalsEnabled = thrownFundamentalsEnabled,
        trickThrowEnabled = trickThrowEnabled,
        pinningShotEnabled = pinningShotEnabled,
        deadeyeMasteryEnabled = deadeyeMasteryEnabled,
    })
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function()
            if axeFeatherDirty then
                axeFeatherDirty = false
                refreshFellstarCrownFeather()
            end
            if axeStateDirty then
                axeStateDirty = false
                publishState(false)
            end
        end,
        shouldUpdate = function()
            return axeFeatherDirty or axeStateDirty
        end,
        onLoad = function()
            lastStateKey = nil
            appliedAxeFeather = math.max(0, tonumber(effectsSection:get(FELLSTAR_CROWN_FEATHER_KEY)) or 0)
            markAxeStateDirty()
            refreshFellstarCrownFeather()
            publishState(true)
            axeFeatherDirty = false
            axeStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_AxeStateDirty = function() markAxeStateDirty() end,
        UiModeChanged = function() markAxeStateDirty() end,
    },
}


return __basepack_subsystem_result
