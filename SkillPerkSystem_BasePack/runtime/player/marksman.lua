-- Marksman player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
local multiplyAnimationSpeed = __basepack_animation.multiplyAnimationSpeed
local registerBasepackAnimationHandler = __basepack_animation.registerHandler
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local input = require("openmw.input")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local BOW_FUNDAMENTALS_PERK_ID = "marksman_bow_fundamentals"
local QUICK_CAST_PERK_ID = "marksman_quick_cast"
local STEADY_DRAW_PERK_ID = "marksman_steady_draw"
local DEADEYE_MASTERY_PERK_ID = "marksman_deadeye_mastery"
local BOW_FUNDAMENTALS_DRAW_SPEED_MULTIPLIER = 1.20
local BOW_FUNDAMENTALS_AGILITY_BONUS = 5
local DEADEYE_MASTERY_AGILITY_BONUS = 10
local QUICK_CAST_ATTACK_SPEED_MULTIPLIER = 1.80
local STEADY_DRAW_MAX_HOLD_SECONDS = 4.0
local STEADY_DRAW_MAX_DAMAGE_BONUS = 0.30
local STEADY_DRAW_PENDING_SHOT_WINDOW = 5.0
local STEADY_DRAW_STATE_EVENT = "SkillPerkSystem_MarksmanSteadyDrawState"
local MARKSMAN_STATE_REFRESH_INTERVAL = 0.5
local STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL = 0.25
local MARKSMAN_EQUIPMENT_SCAN_WINDOW = 1.5
local appliedBowFundamentalsAgilityBonus = 0
local bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
local steadyDrawIdleFrameCheckTimer = STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL
local marksmanAgilityDirty = true
local marksmanEquipmentScanRemaining = 0
local steadyDrawArmedWindowRemaining = 0
local steadyDrawHoldSeconds = 0
local steadyDrawWasHoldingAttack = false
local steadyDrawShotSequence = 0

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

local function isBowRecord(record)
    return weaponTypeEquals(record, "MarksmanBow")
end

local function isCrossbowRecord(record)
    return weaponTypeEquals(record, "MarksmanCrossbow")
end

local function isBowOrCrossbowRecord(record)
    return isBowRecord(record) or isCrossbowRecord(record)
end

local function getEquippedBowRecord()
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
    if not isBowRecord(record) then
        return nil
    end

    return record
end

local function getEquippedBowOrCrossbowRecord()
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
    if not isBowOrCrossbowRecord(record) then
        return nil
    end

    return record
end

local function resolveAgilityStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyBowFundamentalsAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBowFundamentalsAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedBowFundamentalsAgilityBonus = desired
end

local function refreshBowFundamentalsAgilityBonus()
    local desiredBonus = 0
    local bowOrCrossbowRecord = getEquippedBowOrCrossbowRecord()
    if hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) and bowOrCrossbowRecord ~= nil then
        desiredBonus = desiredBonus + BOW_FUNDAMENTALS_AGILITY_BONUS
    end

    if hasEnabledPerk(DEADEYE_MASTERY_PERK_ID) and bowOrCrossbowRecord ~= nil then
        desiredBonus = desiredBonus + DEADEYE_MASTERY_AGILITY_BONUS
    end

    applyBowFundamentalsAgilityBonus(desiredBonus)
end

local function markMarksmanEquipmentDirty(scanWindow)
    marksmanAgilityDirty = true
    marksmanEquipmentScanRemaining = math.max(marksmanEquipmentScanRemaining, tonumber(scanWindow) or MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
end

local MARKSMAN_STATE_PERKS = {
    marksman_bow_fundamentals = true,
    marksman_deadeye_mastery = true,
    marksman_steady_draw = true,
}

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or MARKSMAN_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    if data.perkID == STEADY_DRAW_PERK_ID then
        steadyDrawArmedWindowRemaining = math.max(steadyDrawArmedWindowRemaining, MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    end
end

local function shouldUpdateBowFundamentals(dt)
    if marksmanAgilityDirty then
        return true
    end

    if appliedBowFundamentalsAgilityBonus ~= 0
        and (not (hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) or hasEnabledPerk(DEADEYE_MASTERY_PERK_ID))
            or getEquippedBowOrCrossbowRecord() == nil) then
        return true
    end

    marksmanEquipmentScanRemaining = math.max(0, marksmanEquipmentScanRemaining - (tonumber(dt) or 0))
    if marksmanEquipmentScanRemaining <= 0 then
        return false
    end

    bowFundamentalsRefreshTimer = bowFundamentalsRefreshTimer + (tonumber(dt) or 0)
    return bowFundamentalsRefreshTimer >= MARKSMAN_STATE_REFRESH_INTERVAL
end

local function getEquippedThrownMarksmanRecord()
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
    if not weaponTypeEquals(record, "MarksmanThrown") then
        return nil
    end

    return record
end

local function steadyDrawAttackHeld()
    if input == nil or type(input.getBooleanActionValue) ~= "function" then
        return false
    end

    return input.getBooleanActionValue("Use") == true
end

local function clearSteadyDrawCharge()
    steadyDrawHoldSeconds = 0
    steadyDrawWasHoldingAttack = false
end

local function publishSteadyDrawShot(multiplier, expiresAt)
    steadyDrawShotSequence = steadyDrawShotSequence + 1
    core.sendGlobalEvent(STEADY_DRAW_STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        multiplier = multiplier,
        expiresAt = expiresAt,
        sequence = steadyDrawShotSequence,
    })
end

local function shouldFrameSteadyDraw(dt)
    if steadyDrawHoldSeconds > 0 or steadyDrawWasHoldingAttack then
        return true
    end

    steadyDrawArmedWindowRemaining = math.max(0, steadyDrawArmedWindowRemaining - (tonumber(dt) or 0))
    if steadyDrawArmedWindowRemaining <= 0 then
        return false
    end

    steadyDrawIdleFrameCheckTimer = steadyDrawIdleFrameCheckTimer + (tonumber(dt) or 0)
    if steadyDrawIdleFrameCheckTimer < STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL then
        return false
    end
    steadyDrawIdleFrameCheckTimer = 0

    return hasEnabledPerk(STEADY_DRAW_PERK_ID) and getEquippedBowOrCrossbowRecord() ~= nil
end

local function updateSteadyDraw(dt)
    if not hasEnabledPerk(STEADY_DRAW_PERK_ID) or getEquippedBowOrCrossbowRecord() == nil then
        clearSteadyDrawCharge()
        return
    end

    local holdingAttack = steadyDrawAttackHeld()
    if holdingAttack then
        steadyDrawHoldSeconds = math.min(
            steadyDrawHoldSeconds + (tonumber(dt) or 0),
            STEADY_DRAW_MAX_HOLD_SECONDS
        )
    elseif steadyDrawWasHoldingAttack and steadyDrawHoldSeconds > 0 then
        local now = core.getSimulationTime()
        local ratio = math.min(steadyDrawHoldSeconds / STEADY_DRAW_MAX_HOLD_SECONDS, 1)
        publishSteadyDrawShot(
            1 + (ratio * STEADY_DRAW_MAX_DAMAGE_BONUS),
            now + STEADY_DRAW_PENDING_SHOT_WINDOW
        )
        steadyDrawHoldSeconds = 0
    end

    steadyDrawWasHoldingAttack = holdingAttack
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(applySteadyDrawDamage)
end

local function handleMarksmanAnimation(event)
    markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    if hasEnabledPerk(STEADY_DRAW_PERK_ID) then
        steadyDrawArmedWindowRemaining = math.max(steadyDrawArmedWindowRemaining, MARKSMAN_EQUIPMENT_SCAN_WINDOW)
    end

    if not event.isWeaponAttackWindup then
        return
    end

    if hasEnabledPerk(BOW_FUNDAMENTALS_PERK_ID) and getEquippedBowRecord() ~= nil then
        multiplyAnimationSpeed(event.options, BOW_FUNDAMENTALS_DRAW_SPEED_MULTIPLIER)
    end

    if hasEnabledPerk(QUICK_CAST_PERK_ID) and getEquippedThrownMarksmanRecord() ~= nil then
        multiplyAnimationSpeed(event.options, QUICK_CAST_ATTACK_SPEED_MULTIPLIER)
    end
end
registerBasepackAnimationHandler(handleMarksmanAnimation)

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function()
            marksmanAgilityDirty = false
            bowFundamentalsRefreshTimer = 0
            refreshBowFundamentalsAgilityBonus()
        end,
        shouldUpdate = shouldUpdateBowFundamentals,
        onFrame = function(dt)
            updateSteadyDraw(dt)
        end,
        shouldFrame = shouldFrameSteadyDraw,
        onLoad = function()
            appliedBowFundamentalsAgilityBonus = 0
            bowFundamentalsRefreshTimer = MARKSMAN_STATE_REFRESH_INTERVAL
            steadyDrawIdleFrameCheckTimer = STEADY_DRAW_IDLE_FRAME_CHECK_INTERVAL
            marksmanAgilityDirty = true
            marksmanEquipmentScanRemaining = MARKSMAN_EQUIPMENT_SCAN_WINDOW
            steadyDrawArmedWindowRemaining = MARKSMAN_EQUIPMENT_SCAN_WINDOW
            steadyDrawHoldSeconds = 0
            steadyDrawWasHoldingAttack = false
            steadyDrawShotSequence = 0
            refreshBowFundamentalsAgilityBonus()
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_MarksmanStateDirty = function() markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW) end,
        UiModeChanged = function() markMarksmanEquipmentDirty(MARKSMAN_EQUIPMENT_SCAN_WINDOW) end,
    },
}


return __basepack_subsystem_result
