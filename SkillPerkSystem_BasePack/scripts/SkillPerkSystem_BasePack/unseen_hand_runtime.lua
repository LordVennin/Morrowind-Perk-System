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

local function refreshBurglarsInstinctAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHave = unseenHandEnabled() and getEquippedSecurityTool() ~= nil

    local hasSpell = false
    if type(spells.has) == "function" then
        local okHas, value = pcall(function()
            return spells:has(SPELL_RECORD_ID)
        end)
        if okHas and value == true then
            hasSpell = true
        end
    end

    if shouldHave and not hasSpell and type(spells.add) == "function" then
        local okAdd, addError = pcall(function()
            spells:add(SPELL_RECORD_ID)
        end)
        if not okAdd then
            if not addSpellFailureLogged then
                addSpellFailureLogged = true
                logDebug(string.format("spells:add(%s) failed: %s", SPELL_RECORD_ID, tostring(addError)))
            end
            return
        end
        addSpellFailureLogged = false
    elseif (not shouldHave) and hasSpell and type(spells.remove) == "function" then
        local okRemove, removeError = pcall(function()
            spells:remove(SPELL_RECORD_ID)
        end)
        if not okRemove then
            if not removeSpellFailureLogged then
                removeSpellFailureLogged = true
                logDebug(string.format("spells:remove(%s) failed: %s", SPELL_RECORD_ID, tostring(removeError)))
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
