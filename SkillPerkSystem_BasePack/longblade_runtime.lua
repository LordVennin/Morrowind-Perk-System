local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LONG_BLADE_FUNDAMENTALS_PERK_ID = "longblade_fundamentals"
local DUELISTS_TEMPO_PERK_ID = "longblade_demo_precision"
local DUELISTS_FORM_PERK_ID = "longblade_demo_duelist"
local FATIGUE_THRESHOLD = 0.8
local LONG_BLADE_BONUS = 5
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_LongBlade"
local APPLIED_BONUS_KEY = "fundamentals.applied_bonus"
local DUELISTS_TEMPO_APPLIED_KEY = "duelists_tempo.applied_agility_bonus"
local DUELISTS_FORM_ABILITY_ID = "sps_duelistbuff"
local LOG_TAG = "[SkillPerkSystem_BasePack][LongBlade]"

local DUELISTS_TEMPO_MAX_STACKS = 5
local DUELISTS_TEMPO_DURATION = 4.0
local DUELISTS_TEMPO_AGILITY_PER_STACK = 3

local storageSection = storage.playerSection(STORAGE_SECTION_ID)
local appliedLongBladeBonus = tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0
local duelistTempoStacks = 0
local duelistTempoRemaining = 0
local appliedDuelistTempoAgilityBonus = tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0
local runtimeTime = 0
local lastDuelistTempoTarget = nil
local lastDuelistTempoApplyTime = -1
local duelistsFormAbilityApplied = false
local duelistsFormAbilityAddFailureLogged = false
local duelistsFormAbilityRemoveFailureLogged = false
local duelistsFormSpellBookFailureState = nil

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

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

local function longBladeFundamentalsEnabled()
    return hasEnabledPerk(LONG_BLADE_FUNDAMENTALS_PERK_ID)
end

local function duelistsTempoEnabled()
    return hasEnabledPerk(DUELISTS_TEMPO_PERK_ID)
end

local function duelistsFormEnabled()
    return hasEnabledPerk(DUELISTS_FORM_PERK_ID)
end

local function getFatiguePercent()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return 0
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return 0
    end

    return current / maxFatigue
end

local function resolveLongBladeStat()
    local accessor = types.NPC ~= nil
        and types.NPC.stats ~= nil
        and types.NPC.stats.skills ~= nil
        and types.NPC.stats.skills.longblade
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyLongBladeBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedLongBladeBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveLongBladeStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedLongBladeBonus = desired
    storageSection:set(APPLIED_BONUS_KEY, desired)
end

local function resolveAgilityStat(actor)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" or actor == nil then
        return nil
    end

    return accessor(actor)
end

local function applyDuelistTempoAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedDuelistTempoAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat(pself)
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedDuelistTempoAgilityBonus = desired
    storageSection:set(DUELISTS_TEMPO_APPLIED_KEY, desired)
end

local function clearDuelistTempoBonus()
    duelistTempoStacks = 0
    duelistTempoRemaining = 0
    applyDuelistTempoAgilityBonus(0)
end

local function refreshLongBladeFundamentals()
    local desiredBonus = 0
    if longBladeFundamentalsEnabled() and getFatiguePercent() > FATIGUE_THRESHOLD then
        desiredBonus = LONG_BLADE_BONUS
    end

    applyLongBladeBonus(desiredBonus)
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

local function getArmorRecord(item)
    if item == nil or Armor == nil then
        return nil
    end

    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Armor.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Armor.records) == "table" then
        return Armor.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function isLongBladeOneHandRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local weaponType = tonumber(record.type)
    local oneHandLongBladeType = tonumber(Weapon.TYPE.LongBladeOneHand)
    return weaponType ~= nil and oneHandLongBladeType ~= nil and weaponType == oneHandLongBladeType
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

local function getEquippedOneHandedLongBlade()
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
    if not isLongBladeOneHandRecord(record) then
        return nil
    end

    return weapon
end

local function hasEquippedOffHandShield()
    if Actor == nil or Armor == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local leftSlot = Actor.EQUIPMENT_SLOT.CarriedLeft
    if leftSlot == nil then
        return false
    end

    local offHand = getEquippedItem(leftSlot)
    if offHand == nil then
        return false
    end

    if type(Armor.objectIsInstance) == "function" and not Armor.objectIsInstance(offHand) then
        return false
    end

    local record = getArmorRecord(offHand)
    return record ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE.Shield
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if duelistsFormSpellBookFailureState ~= "unavailable" then
            duelistsFormSpellBookFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust duelist's form state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if duelistsFormSpellBookFailureState ~= "error" then
            duelistsFormSpellBookFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust duelist's form state")
        end
        return nil
    end

    duelistsFormSpellBookFailureState = nil
    return spells
end

local function resolveDuelistsFormAbilityRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[DUELISTS_FORM_ABILITY_ID]
end

local function spellBookHasDuelistsFormAbility(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(DUELISTS_FORM_ABILITY_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveDuelistsFormAbilityRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == DUELISTS_FORM_ABILITY_ID then
            return true
        end
    end

    return false
end

local function addDuelistsFormAbility(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(DUELISTS_FORM_ABILITY_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveDuelistsFormAbilityRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeDuelistsFormAbility(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(DUELISTS_FORM_ABILITY_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveDuelistsFormAbilityRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateDuelistsFormAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHaveAbility = duelistsFormEnabled()
        and getEquippedOneHandedLongBlade() ~= nil
        and not hasEquippedOffHandShield()
    local hasAbility = spellBookHasDuelistsFormAbility(spells)

    if shouldHaveAbility and not hasAbility then
        local okAdd, addError = addDuelistsFormAbility(spells)
        if not okAdd then
            if not duelistsFormAbilityAddFailureLogged then
                duelistsFormAbilityAddFailureLogged = true
                logDebug(string.format("failed to add %s: %s", DUELISTS_FORM_ABILITY_ID, tostring(addError)))
            end
            return
        end
        duelistsFormAbilityAddFailureLogged = false
        duelistsFormAbilityApplied = true
    elseif (not shouldHaveAbility) and (hasAbility or duelistsFormAbilityApplied) then
        local okRemove, removeError = removeDuelistsFormAbility(spells)
        if not okRemove then
            if not duelistsFormAbilityRemoveFailureLogged then
                duelistsFormAbilityRemoveFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", DUELISTS_FORM_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        duelistsFormAbilityRemoveFailureLogged = false
        duelistsFormAbilityApplied = false
    end
end

local function isValidDuelistTempoTarget(target)
    return target ~= nil and type(target.isValid) == "function" and target:isValid()
end

local function applyDuelistTempoToTarget(target, stacks)
    if not isValidDuelistTempoTarget(target) then
        return
    end

    target:sendEvent("SkillPerkSystem_DuelistsTempoRefresh", {
        stacks = stacks,
        duration = DUELISTS_TEMPO_DURATION,
        agilityPerStack = DUELISTS_TEMPO_AGILITY_PER_STACK,
    })
end

local function recentlyAppliedDuelistTempo(target)
    return target ~= nil and target == lastDuelistTempoTarget and (runtimeTime - lastDuelistTempoApplyTime) < 0.05
end

local function rememberDuelistTempoApplication(target)
    lastDuelistTempoTarget = target
    lastDuelistTempoApplyTime = runtimeTime
end

local function tryApplyDuelistTempo(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
        return
    end
    if recentlyAppliedDuelistTempo(target) then
        return
    end

    rememberDuelistTempoApplication(target)
    duelistTempoStacks = math.min(DUELISTS_TEMPO_MAX_STACKS, duelistTempoStacks + 1)
    duelistTempoRemaining = DUELISTS_TEMPO_DURATION
    applyDuelistTempoAgilityBonus(duelistTempoStacks * DUELISTS_TEMPO_AGILITY_PER_STACK)
    applyDuelistTempoToTarget(target, duelistTempoStacks)
end

local function getAttackTarget(attack)
    if type(attack) ~= "table" then
        return nil
    end

    return attack.target or attack.victim or attack.defender or attack.hitObject or attack.object
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

    tryApplyDuelistTempo({
        target = getAttackTarget(attack),
    })
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

local function onLoad()
    appliedLongBladeBonus = math.max(0, math.floor(tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0))
    appliedDuelistTempoAgilityBonus = math.max(0, math.floor(tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0))
    clearDuelistTempoBonus()
    runtimeTime = 0
    lastDuelistTempoTarget = nil
    lastDuelistTempoApplyTime = -1
    refreshLongBladeFundamentals()
    updateDuelistsFormAbility()

    if duelistTempoRemaining > 0 then
        duelistTempoRemaining = math.max(0, duelistTempoRemaining - (tonumber(dt) or 0))
        if duelistTempoRemaining <= 0 or not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
            clearDuelistTempoBonus()
        end
    elseif appliedDuelistTempoAgilityBonus ~= 0 then
        clearDuelistTempoBonus()
    end
end

local function onUpdate(dt)
    runtimeTime = runtimeTime + (tonumber(dt) or 0)
    refreshLongBladeFundamentals()
    updateDuelistsFormAbility()

    if duelistTempoRemaining > 0 then
        duelistTempoRemaining = math.max(0, duelistTempoRemaining - (tonumber(dt) or 0))
        if duelistTempoRemaining <= 0 or not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
            clearDuelistTempoBonus()
        end
    elseif appliedDuelistTempoAgilityBonus ~= 0 then
        clearDuelistTempoBonus()
    end
end

return {
    eventHandlers = {
        SkillPerkSystem_TryDuelistsTempo = tryApplyDuelistTempo,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = onLoad,
    },
}
