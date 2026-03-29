local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local PERK_ID = "security_unseen_hand"
local LOG_TAG = "[SkillPerkSystem_BasePack][UnseenHand]"

local addSpellFailureLogged = false
local removeSpellFailureLogged = false
local playerSpellsFailureState = nil

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function unseenHandEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(PERK_ID)
    end

    return true
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

local function refreshBurglarsInstinctAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHave = unseenHandEnabled() and getEquippedSecurityTool() ~= nil
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
    elseif (not shouldHave) and hasSpell then
        local okRemove, removeError = removeSpell(spells)
        if not okRemove then
            if not removeSpellFailureLogged then
                removeSpellFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", SPELL_RECORD_ID, tostring(removeError)))
            end
            return
        end
        removeSpellFailureLogged = false
    end
end

return {
    engineHandlers = {
        onUpdate = refreshBurglarsInstinctAbility,
        onLoad = refreshBurglarsInstinctAbility,
    },
}
