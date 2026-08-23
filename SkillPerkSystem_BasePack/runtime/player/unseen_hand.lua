-- Unseen Hand player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_subsystem_result = nil

local interfaces = require("openmw.interfaces")
local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local PERK_ID = "security_unseen_hand"
local PLAYER_TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle"
local LOG_TAG = "[SkillPerkSystem_BasePack][UnseenHand]"

local addSpellFailureLogged = false
local removeSpellFailureLogged = false
local playerSpellsFailureState = nil
local enabledOverride = nil
local spellAddedByRuntime = false
local burglarsInstinctDirty = true
local burglarsInstinctScanRemaining = 0
local burglarsInstinctScanTimer = 0
local BURGLARS_INSTINCT_SCAN_WINDOW = 1.5
local BURGLARS_INSTINCT_SCAN_INTERVAL = 0.25

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function interfaceSaysEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(PERK_ID) then
        return false
    end

    return true
end

local function unseenHandEnabled()
    if enabledOverride ~= nil then
        return enabledOverride == true
    end

    return interfaceSaysEnabled()
end

local function getEquippedSecurityTool()
    local okRight, rightItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if okRight and rightItem and (Lockpick.objectIsInstance(rightItem) or Probe.objectIsInstance(rightItem)) then
        return rightItem
    end

    local okLeft, leftItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedLeft)
    if okLeft and leftItem and (Lockpick.objectIsInstance(leftItem) or Probe.objectIsInstance(leftItem)) then
        return leftItem
    end

    return nil
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if playerSpellsFailureState ~= "unavailable" then
            playerSpellsFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust burglar's instinct state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if playerSpellsFailureState ~= "error" then
            playerSpellsFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust burglar's instinct state")
        end
        return nil
    end

    playerSpellsFailureState = nil
    return spells
end

local function resolveSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[SPELL_RECORD_ID]
end

local function spellBookHasSpell(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(SPELL_RECORD_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveSpellRecord()
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
        if type(spell) == "table" and spell.id == SPELL_RECORD_ID then
            return true
        end
    end

    return false
end

local function addSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(SPELL_RECORD_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveSpellRecord()
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

local function removeSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(SPELL_RECORD_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveSpellRecord()
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

local function refreshBurglarsInstinctAbility(forceDisable)
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local equippedTool = getEquippedSecurityTool()
    local shouldHave = (not forceDisable) and unseenHandEnabled() and (equippedTool ~= nil)
    local hasSpell = spellBookHasSpell(spells)

    if shouldHave and not hasSpell then
        local okAdd, addError = addSpell(spells)
        if not okAdd then
            if not addSpellFailureLogged then
                addSpellFailureLogged = true
                logDebug(string.format("failed to add %s: %s", SPELL_RECORD_ID, tostring(addError)))
            end
            return
        end
        addSpellFailureLogged = false
        spellAddedByRuntime = true
    elseif (not shouldHave) and (hasSpell or spellAddedByRuntime) then
        local okRemove, removeError = removeSpell(spells)
        if not okRemove then
            if not removeSpellFailureLogged then
                removeSpellFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", SPELL_RECORD_ID, tostring(removeError)))
            end
            return
        end
        removeSpellFailureLogged = false
        spellAddedByRuntime = false
    end
end

local function markBurglarsInstinctDirty(scanWindow)
    burglarsInstinctDirty = true
    burglarsInstinctScanRemaining = math.max(burglarsInstinctScanRemaining, tonumber(scanWindow) or BURGLARS_INSTINCT_SCAN_WINDOW)
    burglarsInstinctScanTimer = BURGLARS_INSTINCT_SCAN_INTERVAL
end

local function onPlayerToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledOverride = data.enable == true
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
    if not enabledOverride then
        refreshBurglarsInstinctAbility(true)
        return
    end

    refreshBurglarsInstinctAbility(false)
end

local function handleBurglarsInventoryMaybeChanged()
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
end

local function shouldUpdateBurglarsInstinct(dt)
    if burglarsInstinctDirty
        or addSpellFailureLogged
        or removeSpellFailureLogged
        or (spellAddedByRuntime and not unseenHandEnabled()) then
        return true
    end

    burglarsInstinctScanRemaining = math.max(0, burglarsInstinctScanRemaining - (tonumber(dt) or 0))
    if burglarsInstinctScanRemaining <= 0 then
        return false
    end

    burglarsInstinctScanTimer = burglarsInstinctScanTimer + (tonumber(dt) or 0)
    if burglarsInstinctScanTimer < BURGLARS_INSTINCT_SCAN_INTERVAL then
        return false
    end

    burglarsInstinctScanTimer = 0
    return true
end

local function onLoad(data)
    enabledOverride = nil
    spellAddedByRuntime = type(data) == "table" and data.spellAddedByRuntime == true
    markBurglarsInstinctDirty(BURGLARS_INSTINCT_SCAN_WINDOW)
    refreshBurglarsInstinctAbility(false)
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function()
            burglarsInstinctDirty = false
            refreshBurglarsInstinctAbility(false)
        end,
        shouldUpdate = shouldUpdateBurglarsInstinct,
        onLoad = onLoad,
        onSave = function()
            return {
                spellAddedByRuntime = spellAddedByRuntime,
            }
        end,
    },
    eventHandlers = {
        [PLAYER_TOGGLE_EVENT] = onPlayerToggle,
        UiModeChanged = handleBurglarsInventoryMaybeChanged,
    },
}


return __basepack_subsystem_result
