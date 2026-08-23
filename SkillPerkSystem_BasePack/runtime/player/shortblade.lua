-- Shortblade player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local VITAL_STRIKE_PERK_ID = "shortblade_vital_strike"
local FLASH_CUT_PERK_ID = "shortblade_flash_cut"
local CLOSE_MEASURE_PERK_ID = "shortblade_close_measure"
local SHADOW_STEP_PERK_ID = "shortblade_shadow_step"
local MASTER_OF_KNIVES_PERK_ID = "shortblade_master_of_knives"
local SHADOW_STEP_ABILITY_ID = "sps_daggersense"
local SHADOW_STEP_REFRESH_INTERVAL = 0.5
local SHORT_BLADE_STATE_EVENT = "SkillPerkSystem_ShortBladeState"
local CLOSE_MEASURE_TRIGGER_EVENT = "SkillPerkSystem_CloseMeasureTriggered"
local MASTER_OF_KNIVES_TRIGGER_EVENT = "SkillPerkSystem_MasterOfKnivesTriggered"
local SHORT_BLADE_STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_ShortBlade"
local CLOSE_MEASURE_APPLIED_KEY = "close_measure.applied_agility_bonus"
local CLOSE_MEASURE_MAX_STACKS = 5
local CLOSE_MEASURE_DURATION = 5.0
local CLOSE_MEASURE_AGILITY_PER_STACK = 2
local MASTER_OF_KNIVES_AGILITY_APPLIED_KEY = "master_of_knives.applied_agility_bonus"
local MASTER_OF_KNIVES_LUCK_APPLIED_KEY = "master_of_knives.applied_luck_bonus"
local MASTER_OF_KNIVES_DURATION = 5.0
local MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK = 2

local Actor = types.Actor
local Weapon = types.Weapon
local shortBladeStorageSection = storage.playerSection(SHORT_BLADE_STORAGE_SECTION_ID)
local shortBladeStateDirty = true
local lastShortBladeStateKey = nil
local closeMeasureStacks = 0
local closeMeasureRemaining = 0
local appliedCloseMeasureAgilityBonus = tonumber(shortBladeStorageSection:get(CLOSE_MEASURE_APPLIED_KEY)) or 0
local masterOfKnivesStacks = {}
local appliedMasterOfKnivesAgilityBonus = tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_AGILITY_APPLIED_KEY)) or 0
local appliedMasterOfKnivesLuckBonus = tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_LUCK_APPLIED_KEY)) or 0
local shadowStepAbilityApplied = false
local shadowStepRefreshTimer = SHADOW_STEP_REFRESH_INTERVAL
local shadowStepRefreshDue = true

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



local function shadowStepEnabled()
    return hasEnabledPerk(SHADOW_STEP_PERK_ID)
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

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    local recordId = type(item) == "string" and item or item.recordId
    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[recordId]
    end

    if type(item) == "table" and item.type ~= nil and type(item.type.records) == "table" and type(recordId) == "string" then
        return item.type.records[recordId]
    end

    return nil
end

local function isShortBladeRecord(record)
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.ShortBladeOneHand)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function hasEquippedShortBlade()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return false
    end

    local weapon = getEquippedItem(Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return false
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return false
    end

    return isShortBladeRecord(getWeaponRecord(weapon))
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        return nil
    end

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
        local okHasById, hasById = pcall(function() return spells:has(abilityId) end)
        if okHasById and hasById == true then
            return true
        end

        local record = resolveAbilityRecord(abilityId)
        if record ~= nil then
            local okHasByRecord, hasByRecord = pcall(function() return spells:has(record) end)
            if okHasByRecord and hasByRecord == true then
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
        return false
    end

    local okAddById = pcall(function() spells:add(abilityId) end)
    if okAddById then
        return true
    end

    local record = resolveAbilityRecord(abilityId)
    if record == nil then
        return false
    end

    local okAddByRecord = pcall(function() spells:add(record) end)
    return okAddByRecord == true
end

local function removeAbility(spells, abilityId)
    if type(spells.remove) ~= "function" then
        return false
    end

    local okRemoveById = pcall(function() spells:remove(abilityId) end)
    if okRemoveById then
        return true
    end

    local record = resolveAbilityRecord(abilityId)
    if record == nil then
        return false
    end

    local okRemoveByRecord = pcall(function() spells:remove(record) end)
    return okRemoveByRecord == true
end

local function updateShadowStepAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHave = shadowStepEnabled() and hasEquippedShortBlade()
    local hasAbility = spellBookHasAbility(spells, SHADOW_STEP_ABILITY_ID)
    if shouldHave and not hasAbility then
        if addAbility(spells, SHADOW_STEP_ABILITY_ID) then
            shadowStepAbilityApplied = true
        end
    elseif (not shouldHave) and (hasAbility or shadowStepAbilityApplied) then
        if removeAbility(spells, SHADOW_STEP_ABILITY_ID) then
            shadowStepAbilityApplied = false
        end
    else
        shadowStepAbilityApplied = hasAbility and shouldHave
    end
end

local function resolveAttributeStat(attributeName)
    local attributes = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes
    local accessor = attributes ~= nil and attributes[attributeName] or nil
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
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

local function resolveLuckStat()
    return resolveAttributeStat("luck")
end

local function applyCloseMeasureAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedCloseMeasureAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedCloseMeasureAgilityBonus = desired
    shortBladeStorageSection:set(CLOSE_MEASURE_APPLIED_KEY, desired)
end

local function clearCloseMeasureBonus()
    closeMeasureStacks = 0
    closeMeasureRemaining = 0
    applyCloseMeasureAgilityBonus(0)
end


local function applyMasterOfKnivesAttributeBonus(statResolver, appliedBonus, storageKey, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBonus) or 0))
    if desired == current then
        return current
    end

    local stat = statResolver()
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    shortBladeStorageSection:set(storageKey, desired)
    return desired
end

local function applyMasterOfKnivesBonus(targetBonus)
    appliedMasterOfKnivesAgilityBonus = applyMasterOfKnivesAttributeBonus(
        resolveAgilityStat,
        appliedMasterOfKnivesAgilityBonus,
        MASTER_OF_KNIVES_AGILITY_APPLIED_KEY,
        targetBonus
    )
    appliedMasterOfKnivesLuckBonus = applyMasterOfKnivesAttributeBonus(
        resolveLuckStat,
        appliedMasterOfKnivesLuckBonus,
        MASTER_OF_KNIVES_LUCK_APPLIED_KEY,
        targetBonus
    )
end

local function clearMasterOfKnivesBonus()
    masterOfKnivesStacks = {}
    applyMasterOfKnivesBonus(0)
end

local function refreshMasterOfKnivesBonus(dt)
    local elapsed = math.max(0, tonumber(dt) or 0)
    for index = #masterOfKnivesStacks, 1, -1 do
        local remaining = math.max(0, tonumber(masterOfKnivesStacks[index]) or 0) - elapsed
        if remaining <= 0 then
            table.remove(masterOfKnivesStacks, index)
        else
            masterOfKnivesStacks[index] = remaining
        end
    end

    if #masterOfKnivesStacks == 0 then
        applyMasterOfKnivesBonus(0)
    else
        applyMasterOfKnivesBonus(#masterOfKnivesStacks * MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK)
    end
end

local function markShortBladeStateDirty()
    shortBladeStateDirty = true
end

local function publishShortBladeState(force)
    local vitalStrikeEnabled = hasEnabledPerk(VITAL_STRIKE_PERK_ID)
    local flashCutEnabled = hasEnabledPerk(FLASH_CUT_PERK_ID)
    local closeMeasureEnabled = hasEnabledPerk(CLOSE_MEASURE_PERK_ID)
    local masterOfKnivesEnabled = hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID)
    local stateKey = tostring(vitalStrikeEnabled) .. ":" .. tostring(flashCutEnabled) .. ":" .. tostring(closeMeasureEnabled) .. ":" .. tostring(masterOfKnivesEnabled)
    if not force and stateKey == lastShortBladeStateKey then
        return
    end

    lastShortBladeStateKey = stateKey
    core.sendGlobalEvent(SHORT_BLADE_STATE_EVENT, {
        playerId = pself.id,
        vitalStrikeEnabled = vitalStrikeEnabled,
        flashCutEnabled = flashCutEnabled,
        closeMeasureEnabled = closeMeasureEnabled,
        masterOfKnivesEnabled = masterOfKnivesEnabled,
    })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" then
        return
    end
    if data.perkID == VITAL_STRIKE_PERK_ID or data.perkID == FLASH_CUT_PERK_ID or data.perkID == CLOSE_MEASURE_PERK_ID or data.perkID == SHADOW_STEP_PERK_ID or data.perkID == MASTER_OF_KNIVES_PERK_ID then
        markShortBladeStateDirty()
        if data.perkID == SHADOW_STEP_PERK_ID then
            shadowStepRefreshDue = true
        end
        if data.perkID == CLOSE_MEASURE_PERK_ID and not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
            clearCloseMeasureBonus()
        end
        if data.perkID == MASTER_OF_KNIVES_PERK_ID and not hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
            clearMasterOfKnivesBonus()
        end
    end
end

local function handleMasterOfKnivesTrigger(data)
    if type(data) ~= "table" or data.playerId ~= pself.id then
        return
    end
    if not hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
        clearMasterOfKnivesBonus()
        return
    end

    masterOfKnivesStacks[#masterOfKnivesStacks + 1] = MASTER_OF_KNIVES_DURATION
    applyMasterOfKnivesBonus(#masterOfKnivesStacks * MASTER_OF_KNIVES_ATTRIBUTE_PER_STACK)
end

local function handleCloseMeasureTrigger(data)
    if type(data) ~= "table" or data.playerId ~= pself.id then
        return
    end
    if not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
        clearCloseMeasureBonus()
        return
    end

    closeMeasureStacks = math.min(CLOSE_MEASURE_MAX_STACKS, closeMeasureStacks + 1)
    closeMeasureRemaining = CLOSE_MEASURE_DURATION
    applyCloseMeasureAgilityBonus(closeMeasureStacks * CLOSE_MEASURE_AGILITY_PER_STACK)
end


__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function(dt)
            if #masterOfKnivesStacks > 0 then
                if hasEnabledPerk(MASTER_OF_KNIVES_PERK_ID) then
                    refreshMasterOfKnivesBonus(dt)
                else
                    clearMasterOfKnivesBonus()
                end
            elseif appliedMasterOfKnivesAgilityBonus ~= 0 or appliedMasterOfKnivesLuckBonus ~= 0 then
                clearMasterOfKnivesBonus()
            end

            if closeMeasureRemaining > 0 then
                closeMeasureRemaining = math.max(0, closeMeasureRemaining - (tonumber(dt) or 0))
                if closeMeasureRemaining <= 0 or not hasEnabledPerk(CLOSE_MEASURE_PERK_ID) then
                    clearCloseMeasureBonus()
                end
            elseif appliedCloseMeasureAgilityBonus ~= 0 then
                clearCloseMeasureBonus()
            end

            if shadowStepRefreshDue or shadowStepAbilityApplied then
                shadowStepRefreshDue = false
                shadowStepRefreshTimer = 0
                updateShadowStepAbility()
            end

            if shortBladeStateDirty then
                shortBladeStateDirty = false
                publishShortBladeState(false)
            end
        end,
        shouldUpdate = function(dt)
            if shortBladeStateDirty or closeMeasureRemaining > 0 or appliedCloseMeasureAgilityBonus ~= 0 or #masterOfKnivesStacks > 0 or appliedMasterOfKnivesAgilityBonus ~= 0 or appliedMasterOfKnivesLuckBonus ~= 0 or shadowStepRefreshDue or shadowStepAbilityApplied then
                return true
            end

            if not shadowStepEnabled() then
                return false
            end

            shadowStepRefreshTimer = shadowStepRefreshTimer + (tonumber(dt) or 0)
            if shadowStepRefreshTimer < SHADOW_STEP_REFRESH_INTERVAL then
                return false
            end

            shadowStepRefreshDue = true
            return true
        end,
        onLoad = function()
            lastShortBladeStateKey = nil
            shortBladeStateDirty = true
            appliedCloseMeasureAgilityBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(CLOSE_MEASURE_APPLIED_KEY)) or 0))
            appliedMasterOfKnivesAgilityBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_AGILITY_APPLIED_KEY)) or 0))
            appliedMasterOfKnivesLuckBonus = math.max(0, math.floor(tonumber(shortBladeStorageSection:get(MASTER_OF_KNIVES_LUCK_APPLIED_KEY)) or 0))
            clearCloseMeasureBonus()
            clearMasterOfKnivesBonus()
            shadowStepAbilityApplied = false
            shadowStepRefreshTimer = SHADOW_STEP_REFRESH_INTERVAL
            shadowStepRefreshDue = true
            updateShadowStepAbility()
            publishShortBladeState(true)
            shortBladeStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        [CLOSE_MEASURE_TRIGGER_EVENT] = handleCloseMeasureTrigger,
        [MASTER_OF_KNIVES_TRIGGER_EVENT] = handleMasterOfKnivesTrigger,
        SkillPerkSystem_ShortBladeStateDirty = function() markShortBladeStateDirty() end,
        UiModeChanged = function()
            markShortBladeStateDirty()
            shadowStepRefreshDue = true
        end,
    },
}


return __basepack_subsystem_result
