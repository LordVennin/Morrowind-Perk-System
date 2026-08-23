-- Spear player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
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
local POINT_CONTROL_PERK_ID = "spear_point_control"
local DRIVING_STEP_PERK_ID = "spear_driving_step"
local HOOK_AND_TURN_PERK_ID = "spear_hook_and_turn"
local LINE_BREAKER_PERK_ID = "spear_line_breaker"
local MASTER_VANGUARD_PERK_ID = "spear_master_vanguard"
local POINT_CONTROL_ENDURANCE_BONUS = 5
local HOOK_AND_TURN_WINDOW = 5.0
local HOOK_AND_TURN_HEALTH_MULTIPLIER = 1.15
local HOOK_AND_TURN_FATIGUE_DAMAGE = 10
local MASTER_VANGUARD_ATTRIBUTE_BONUS = 5
local MASTER_VANGUARD_DURATION = 10.0
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_Spear"
local MASTER_VANGUARD_ENDURANCE_APPLIED_KEY = "master_vanguard.applied_endurance_bonus"
local MASTER_VANGUARD_AGILITY_APPLIED_KEY = "master_vanguard.applied_agility_bonus"
local SPEAR_STATE_EVENT = "SkillPerkSystem_SpearPointControlState"
local SPEAR_STATE_REFRESH_INTERVAL = 0.5
local SPEAR_EQUIPMENT_SCAN_WINDOW = 1.5

local storageSection = storage.playerSection(STORAGE_SECTION_ID)

local appliedPointControlEnduranceBonus = 0
local spearStateDirty = true
local spearEquipmentScanRemaining = SPEAR_EQUIPMENT_SCAN_WINDOW
local spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
local lastSpearStateKey = nil
local hookAndTurnPrimedUntil = 0
local appliedMasterVanguardEnduranceBonus = tonumber(storageSection:get(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY)) or 0
local appliedMasterVanguardAgilityBonus = tonumber(storageSection:get(MASTER_VANGUARD_AGILITY_APPLIED_KEY)) or 0
local masterVanguardRemaining = 0
local spearRuntimeTime = 0
local lastMasterVanguardTarget = nil
local lastMasterVanguardApplyTime = -1

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

local function isSpearRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.SpearTwoWide)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function getEquippedSpearRecord()
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
    if not isSpearRecord(record) then
        return nil
    end

    return record
end

local function isMeleeAttack(attack)
    local sourceTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_SOURCE_TYPES or nil
    local expected = sourceTypes ~= nil and tonumber(sourceTypes.Melee) or nil
    local actual = type(attack) == "table" and tonumber(attack.sourceType) or nil
    return expected == nil or actual == nil or actual == expected
end


local function resolveAttackShapeFromText(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = string.lower(value)
    if string.find(normalized, "thrust", 1, true) ~= nil then
        return "thrust"
    end
    if string.find(normalized, "slash", 1, true) ~= nil then
        return "slash"
    end
    if string.find(normalized, "chop", 1, true) ~= nil then
        return "chop"
    end

    return nil
end

local function resolveAttackShapeFromType(value)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    if attackTypes ~= nil then
        if value == attackTypes.Chop then
            return "chop"
        end
        if value == attackTypes.Slash then
            return "slash"
        end
        if value == attackTypes.Thrust then
            return "thrust"
        end
    end

    return resolveAttackShapeFromText(value)
end

local function resolveSpearAttackShape(attack)
    if type(attack) ~= "table" then
        return nil
    end

    local candidates = {
        attack.attackType,
        attack.type,
        attack.attack,
        attack.attackKind,
        attack.attackSource,
        attack.source,
        attack.animation,
        attack.animationName,
        attack.groupName,
        attack.startKey,
        attack.stopKey,
    }

    for _, candidate in ipairs(candidates) do
        local shape = resolveAttackShapeFromType(candidate)
        if shape ~= nil then
            return shape
        end
    end

    return nil
end

local function isSuccessfulPlayerSpearHit(attack)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if getEquippedSpearRecord() == nil then
        return false
    end

    return type(attack.damage) == "table"
end

local function isSuccessfulPlayerSpearHitForPerk(attack, perkID)
    if type(attack) ~= "table" or attack.successful ~= true then
        return false
    end
    if attack.attacker ~= pself then
        return false
    end
    if not hasEnabledPerk(perkID) then
        return false
    end
    if not isMeleeAttack(attack) then
        return false
    end
    if getEquippedSpearRecord() == nil then
        return false
    end

    return type(attack.damage) == "table"
end

local function resolveMasterVanguardAttributeStat(attributeName)
    local attributes = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes
        or nil
    local accessor = nil
    if attributeName == "endurance" then
        accessor = attributes ~= nil and attributes.endurance or nil
    elseif attributeName == "agility" then
        accessor = attributes ~= nil and attributes.agility or nil
    end
    if type(accessor) ~= "function" then
        return nil
    end

    local ok, stat = pcall(accessor, pself)
    if not ok then
        return nil
    end

    return stat
end

local function applyAttributeBonus(attributeName, currentBonus, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(currentBonus) or 0))
    if desired == current then
        return current
    end

    local stat = resolveMasterVanguardAttributeStat(attributeName)
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    return desired
end

local function applyMasterVanguardBonuses(targetBonus)
    appliedMasterVanguardEnduranceBonus = applyAttributeBonus(
        "endurance",
        appliedMasterVanguardEnduranceBonus,
        targetBonus
    )
    appliedMasterVanguardAgilityBonus = applyAttributeBonus(
        "agility",
        appliedMasterVanguardAgilityBonus,
        targetBonus
    )
    storageSection:set(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY, appliedMasterVanguardEnduranceBonus)
    storageSection:set(MASTER_VANGUARD_AGILITY_APPLIED_KEY, appliedMasterVanguardAgilityBonus)
end

local function clearMasterVanguardBonuses()
    masterVanguardRemaining = 0
    applyMasterVanguardBonuses(0)
end

local function refreshMasterVanguardBonuses(dt)
    if masterVanguardRemaining > 0 then
        masterVanguardRemaining = math.max(0, masterVanguardRemaining - (tonumber(dt) or 0))
        if masterVanguardRemaining <= 0
            or not hasEnabledPerk(MASTER_VANGUARD_PERK_ID)
            or getEquippedSpearRecord() == nil then
            clearMasterVanguardBonuses()
        end
    elseif appliedMasterVanguardEnduranceBonus ~= 0 or appliedMasterVanguardAgilityBonus ~= 0 then
        clearMasterVanguardBonuses()
    end
end

local function recentlyAppliedMasterVanguard(target)
    return target ~= nil and target == lastMasterVanguardTarget and (spearRuntimeTime - lastMasterVanguardApplyTime) < 0.05
end

local function rememberMasterVanguardApplication(target)
    lastMasterVanguardTarget = target
    lastMasterVanguardApplyTime = spearRuntimeTime
end

local function tryApplyMasterVanguard(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target ~= nil and type(target.isValid) == "function" and not target:isValid() then
        return
    end
    if not hasEnabledPerk(MASTER_VANGUARD_PERK_ID) or getEquippedSpearRecord() == nil then
        return
    end
    if recentlyAppliedMasterVanguard(target) then
        return
    end

    rememberMasterVanguardApplication(target)
    masterVanguardRemaining = MASTER_VANGUARD_DURATION
    applyMasterVanguardBonuses(MASTER_VANGUARD_ATTRIBUTE_BONUS)
end

local function updateHookAndTurn(attack)
    if not isSuccessfulPlayerSpearHitForPerk(attack, HOOK_AND_TURN_PERK_ID) then
        return
    end

    local shape = resolveSpearAttackShape(attack)
    if shape == nil then
        return
    end

    local now = core.getSimulationTime()
    if shape == "chop" or shape == "slash" then
        hookAndTurnPrimedUntil = now + HOOK_AND_TURN_WINDOW
        return
    end

    if shape ~= "thrust" then
        return
    end

    if hookAndTurnPrimedUntil <= 0 or hookAndTurnPrimedUntil < now then
        hookAndTurnPrimedUntil = 0
        return
    end

    hookAndTurnPrimedUntil = 0
    attack.damage.health = (tonumber(attack.damage.health) or 0) * HOOK_AND_TURN_HEALTH_MULTIPLIER
    attack.damage.fatigue = (tonumber(attack.damage.fatigue) or 0) + HOOK_AND_TURN_FATIGUE_DAMAGE
end
local function resolveEnduranceStat()
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.endurance
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyPointControlEnduranceBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedPointControlEnduranceBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveEnduranceStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedPointControlEnduranceBonus = desired
end

local function refreshPointControlEnduranceBonus()
    local desiredBonus = 0
    if hasEnabledPerk(POINT_CONTROL_PERK_ID) and getEquippedSpearRecord() ~= nil then
        desiredBonus = POINT_CONTROL_ENDURANCE_BONUS
    end

    applyPointControlEnduranceBonus(desiredBonus)
end

local function publishSpearPointControlState(force)
    local pointControlEnabled = hasEnabledPerk(POINT_CONTROL_PERK_ID)
    local masterVanguardEnabled = hasEnabledPerk(MASTER_VANGUARD_PERK_ID)
    local drivingStepEnabled = hasEnabledPerk(DRIVING_STEP_PERK_ID)
    local hookAndTurnEnabled = hasEnabledPerk(HOOK_AND_TURN_PERK_ID)
    local lineBreakerEnabled = hasEnabledPerk(LINE_BREAKER_PERK_ID)
    local stateKey = tostring(pointControlEnabled) .. ":" .. tostring(drivingStepEnabled) .. ":" .. tostring(hookAndTurnEnabled) .. ":" .. tostring(lineBreakerEnabled) .. ":" .. tostring(masterVanguardEnabled)
    if not force and stateKey == lastSpearStateKey then
        return
    end

    lastSpearStateKey = stateKey
    core.sendGlobalEvent(SPEAR_STATE_EVENT, {
        playerId = pself.id,
        pointControlEnabled = pointControlEnabled,
        drivingStepEnabled = drivingStepEnabled,
        hookAndTurnEnabled = hookAndTurnEnabled,
        lineBreakerEnabled = lineBreakerEnabled,
        masterVanguardEnabled = masterVanguardEnabled,
    })
end

local function markSpearStateDirty(scanWindow)
    spearStateDirty = true
    spearEquipmentScanRemaining = math.max(spearEquipmentScanRemaining, tonumber(scanWindow) or SPEAR_EQUIPMENT_SCAN_WINDOW)
    spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" then
        return
    end

    if data.perkID == POINT_CONTROL_PERK_ID or data.perkID == DRIVING_STEP_PERK_ID or data.perkID == HOOK_AND_TURN_PERK_ID or data.perkID == LINE_BREAKER_PERK_ID or data.perkID == MASTER_VANGUARD_PERK_ID then
        markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW)
    end
end

local function shouldUpdateSpear(dt)
    if spearStateDirty then
        return true
    end

    if appliedPointControlEnduranceBonus ~= 0
        and (not hasEnabledPerk(POINT_CONTROL_PERK_ID) or getEquippedSpearRecord() == nil) then
        return true
    end

    if masterVanguardRemaining > 0 or appliedMasterVanguardEnduranceBonus ~= 0 or appliedMasterVanguardAgilityBonus ~= 0 then
        return true
    end

    spearEquipmentScanRemaining = math.max(0, spearEquipmentScanRemaining - (tonumber(dt) or 0))
    if spearEquipmentScanRemaining <= 0 then
        return false
    end

    spearRefreshTimer = spearRefreshTimer + (tonumber(dt) or 0)
    return spearRefreshTimer >= SPEAR_STATE_REFRESH_INTERVAL
end

local function handleSpearAnimation()
    markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW)
end
registerBasepackAnimationHandler(handleSpearAnimation)

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(updateHookAndTurn)
    addOnHitHandler(updateMasterVanguard)
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function(dt)
            spearRuntimeTime = spearRuntimeTime + (tonumber(dt) or 0)
            refreshMasterVanguardBonuses(dt)

            spearStateDirty = false
            spearRefreshTimer = 0
            refreshPointControlEnduranceBonus()
            refreshMasterVanguardBonuses()
            publishSpearPointControlState(false)
        end,
        shouldUpdate = shouldUpdateSpear,
        onLoad = function()
            appliedPointControlEnduranceBonus = 0
            spearStateDirty = true
            spearEquipmentScanRemaining = SPEAR_EQUIPMENT_SCAN_WINDOW
            spearRefreshTimer = SPEAR_STATE_REFRESH_INTERVAL
            lastSpearStateKey = nil
            hookAndTurnPrimedUntil = 0
            appliedMasterVanguardEnduranceBonus = math.max(0, math.floor(tonumber(storageSection:get(MASTER_VANGUARD_ENDURANCE_APPLIED_KEY)) or 0))
            appliedMasterVanguardAgilityBonus = math.max(0, math.floor(tonumber(storageSection:get(MASTER_VANGUARD_AGILITY_APPLIED_KEY)) or 0))
            clearMasterVanguardBonuses()
            spearRuntimeTime = 0
            lastMasterVanguardTarget = nil
            lastMasterVanguardApplyTime = -1
            refreshPointControlEnduranceBonus()
            publishSpearPointControlState(true)
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_TryMasterVanguard = tryApplyMasterVanguard,
        SkillPerkSystem_SpearStateDirty = function() markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW) end,
        UiModeChanged = function() markSpearStateDirty(SPEAR_EQUIPMENT_SCAN_WINDOW) end,
    },
}


return __basepack_subsystem_result
