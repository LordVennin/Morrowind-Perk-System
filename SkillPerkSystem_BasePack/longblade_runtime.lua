local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local ui = require("openmw.ui")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LONG_BLADE_FUNDAMENTALS_PERK_ID = "longblade_fundamentals"
local DUELISTS_TEMPO_PERK_ID = "longblade_demo_precision"
local GREATBLADE_FORM_PERK_ID = "longblade_greatblade_form"
local DUELISTS_FORM_PERK_ID = "longblade_demo_duelist"
local GREATBLADE_CRITICALS_PERK_ID = "longblade_demo_whirlwind"
local FATIGUE_THRESHOLD = 0.8
local LONG_BLADE_BONUS = 5
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_LongBlade"
local APPLIED_BONUS_KEY = "fundamentals.applied_bonus"
local DUELISTS_TEMPO_APPLIED_KEY = "duelists_tempo.applied_agility_bonus"
local DUELISTS_FORM_ABILITY_ID = "sps_duelistbuff"
local GREATBLADE_FORM_ABILITY_ID = "sps_greatbladeform"
local LOG_TAG = "[SkillPerkSystem_BasePack][LongBlade]"

local DUELISTS_TEMPO_MAX_STACKS = 5
local DUELISTS_TEMPO_DURATION = 4.0
local DUELISTS_TEMPO_AGILITY_PER_STACK = 3
local GREATBLADE_CRITICAL_CHANCE = 0.25
local GREATBLADE_CRITICAL_DAMAGE = 20
local GREATBLADE_CRITICAL_MESSAGE = "Critical hit!"

local storageSection = storage.playerSection(STORAGE_SECTION_ID)
local appliedLongBladeBonus = tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0
local duelistTempoStacks = 0
local duelistTempoRemaining = 0
local appliedDuelistTempoAgilityBonus = tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0
local runtimeTime = 0
local lastDuelistTempoTarget = nil
local lastDuelistTempoApplyTime = -1
local duelistsFormAbilityApplied = false
local greatbladeFormAbilityApplied = false
local spellAbilityFailureStates = {}
local playerSpellBookFailureState = nil

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

local function greatbladeFormEnabled()
    return hasEnabledPerk(GREATBLADE_FORM_PERK_ID)
end

local function duelistsFormEnabled()
    return hasEnabledPerk(DUELISTS_FORM_PERK_ID)
end

local function greatbladeCriticalsEnabled()
    return hasEnabledPerk(GREATBLADE_CRITICALS_PERK_ID)
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

local function isLongBladeTwoHandRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local weaponType = tonumber(record.type)
    local twoHandLongBladeType = tonumber(Weapon.TYPE.LongBladeTwoHand)
    return weaponType ~= nil and twoHandLongBladeType ~= nil and weaponType == twoHandLongBladeType
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

local function getEquippedLongBladeWeapon(matcher)
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil or type(matcher) ~= "function" then
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
    if not matcher(record) then
        return nil
    end

    return weapon
end

local function getEquippedOneHandedLongBlade()
    return getEquippedLongBladeWeapon(isLongBladeOneHandRecord)
end

local function getEquippedTwoHandedLongBlade()
    return getEquippedLongBladeWeapon(isLongBladeTwoHandRecord)
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
        if playerSpellBookFailureState ~= "unavailable" then
            playerSpellBookFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust long blade ability state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if playerSpellBookFailureState ~= "error" then
            playerSpellBookFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust long blade ability state")
        end
        return nil
    end

    playerSpellBookFailureState = nil
    return spells
end

local function resolveAbilityRecord(abilityId)
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[abilityId]
end

local function spellBookHasAbility(spells, abilityId)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(abilityId)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveAbilityRecord(abilityId)
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
        if type(spell) == "table" and spell.id == abilityId then
            return true
        end
    end

    return false
end

local function addAbility(spells, abilityId)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(abilityId)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveAbilityRecord(abilityId)
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

local function removeAbility(spells, abilityId)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(abilityId)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveAbilityRecord(abilityId)
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

local function updateConditionalAbility(spells, abilityId, shouldHaveAbility, applied)
    local hasAbility = spellBookHasAbility(spells, abilityId)
    local failureState = spellAbilityFailureStates[abilityId] or {}

    if shouldHaveAbility and not hasAbility then
        local okAdd, addError = addAbility(spells, abilityId)
        if not okAdd then
            if not failureState.add then
                failureState.add = true
                logDebug(string.format("failed to add %s: %s", abilityId, tostring(addError)))
            end
            spellAbilityFailureStates[abilityId] = failureState
            return applied
        end
        failureState.add = false
        spellAbilityFailureStates[abilityId] = failureState
        return true
    elseif (not shouldHaveAbility) and (hasAbility or applied) then
        local okRemove, removeError = removeAbility(spells, abilityId)
        if not okRemove then
            if not failureState.remove then
                failureState.remove = true
                logDebug(string.format("failed to remove %s: %s", abilityId, tostring(removeError)))
            end
            spellAbilityFailureStates[abilityId] = failureState
            return applied
        end
        failureState.remove = false
        spellAbilityFailureStates[abilityId] = failureState
        return false
    end

    return applied
end

local function updateLongBladeAbilities()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    greatbladeFormAbilityApplied = updateConditionalAbility(
        spells,
        GREATBLADE_FORM_ABILITY_ID,
        greatbladeFormEnabled() and getEquippedTwoHandedLongBlade() ~= nil,
        greatbladeFormAbilityApplied
    )

    duelistsFormAbilityApplied = updateConditionalAbility(
        spells,
        DUELISTS_FORM_ABILITY_ID,
        duelistsFormEnabled() and getEquippedOneHandedLongBlade() ~= nil and not hasEquippedOffHandShield(),
        duelistsFormAbilityApplied
    )
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

local function showMessage(text)
    ui.showMessage(text, { showInDialogue = false })
end

local function applyGreatbladeCriticalDamage(target)
    target:sendEvent("ModifyStat", {
        stat = "health",
        amount = -GREATBLADE_CRITICAL_DAMAGE,
    })
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


local function tryApplyGreatbladeCritical(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not greatbladeCriticalsEnabled() or getEquippedTwoHandedLongBlade() == nil then
        return
    end
    if math.random() >= GREATBLADE_CRITICAL_CHANCE then
        return
    end

    showMessage(GREATBLADE_CRITICAL_MESSAGE)
    applyGreatbladeCriticalDamage(target)
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

    local target = getAttackTarget(attack)
    tryApplyDuelistTempo({
        target = target,
    })
    tryApplyGreatbladeCritical({
        target = target,
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
    updateLongBladeAbilities()

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
    updateLongBladeAbilities()

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
