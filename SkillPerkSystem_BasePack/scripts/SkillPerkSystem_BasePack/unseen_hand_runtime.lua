local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Lockpick = types.Lockpick
local Probe = types.Probe

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.unseen_hand.enabled"
local SPELL_RECORD_ID_KEY = "security.unseen_hand.spell_record_id"
local DEFAULT_SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_Toggle"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local PERK_ID = "security_unseen_hand"
local LOG_TAG = "[SkillPerkSystem_BasePack][UnseenHand]"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)

local activeUnseenHandSpellRecordId = nil
local spellRecordResolutionFailureState = nil
local playerSpellsFailureState = nil
local addSpellFailureLogged = false
local removeSpellFailureLogged = false

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function logFirstFailure(stateKey, message)
    if stateKey == nil then
        return
    end

    if stateKey == spellRecordResolutionFailureState then
        return
    end

    spellRecordResolutionFailureState = stateKey
    logDebug(message)
end

local function clearSpellResolutionFailure()
    spellRecordResolutionFailureState = nil
end

local function spellRecordExists(spellRecordId)
    if type(spellRecordId) ~= "string" or spellRecordId == "" then
        return false
    end

    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return false
    end

    return records[spellRecordId] ~= nil
end

local function resolveSpellRecordId()
    local spellRecordId = activeUnseenHandSpellRecordId
    if (type(spellRecordId) ~= "string" or spellRecordId == "") and spellRecordExists(DEFAULT_SPELL_RECORD_ID) then
        spellRecordId = DEFAULT_SPELL_RECORD_ID
    end

    if type(spellRecordId) ~= "string" or spellRecordId == "" then
        spellRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    end

    if type(spellRecordId) ~= "string" or spellRecordId == "" then
        logFirstFailure("record-empty", "resolved spell record id is empty")
        return nil
    end

    if not spellRecordExists(spellRecordId) then
        logFirstFailure(
            "record-unknown:" .. spellRecordId,
            string.format("resolved spell record id is unknown: %s", spellRecordId)
        )
        return nil
    end

    clearSpellResolutionFailure()
    return spellRecordId
end

local function unseenHandEnabled()
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

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

local function getEquippedSecurityTool()
    local right = nil
    local left = nil

    local okRight, rightItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if okRight then
        right = rightItem
    end

    local okLeft, leftItem = pcall(Actor.getEquipment, pself, Actor.EQUIPMENT_SLOT.CarriedLeft)
    if okLeft then
        left = leftItem
    end

    if right and (Lockpick.objectIsInstance(right) or Probe.objectIsInstance(right)) then
        return right
    end

    if left and (Lockpick.objectIsInstance(left) or Probe.objectIsInstance(left)) then
        return left
    end

    return nil
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if playerSpellsFailureState ~= "unavailable" then
            playerSpellsFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust unseen-hand spell state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if playerSpellsFailureState ~= "error" then
            playerSpellsFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust unseen-hand spell state")
        end
        return nil
    end

    playerSpellsFailureState = nil
    return spells
end

local function ensureSpellState(shouldHave)
    local spellRecordId = resolveSpellRecordId()
    if spellRecordId == nil then
        return
    end

    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local hasSpell = false
    if type(spells.has) == "function" then
        local okHas, value = pcall(function()
            return spells:has(spellRecordId)
        end)
        if okHas and value == true then
            hasSpell = true
        end
    end

    if shouldHave and not hasSpell and type(spells.add) == "function" then
        local okAdd, addError = pcall(function()
            spells:add(spellRecordId)
        end)
        if not okAdd then
            if not addSpellFailureLogged then
                addSpellFailureLogged = true
                logDebug(string.format("spells:add(%s) failed: %s", spellRecordId, tostring(addError)))
            end
            return
        end
        addSpellFailureLogged = false
    elseif (not shouldHave) and hasSpell and type(spells.remove) == "function" then
        local okRemove, removeError = pcall(function()
            spells:remove(spellRecordId)
        end)
        if not okRemove then
            if not removeSpellFailureLogged then
                removeSpellFailureLogged = true
                logDebug(string.format("spells:remove(%s) failed: %s", spellRecordId, tostring(removeError)))
            end
            return
        end
        removeSpellFailureLogged = false
    end
end

local function refreshUnseenHandAbility()
    local shouldHave = unseenHandEnabled() and getEquippedSecurityTool() ~= nil
    ensureSpellState(shouldHave)
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    effectsSection:set(ENABLED_KEY, data.enable == true)

    local spellRecordId = data.spellRecordId
    if type(spellRecordId) == "string" and spellRecordId ~= "" then
        effectsSection:set(SPELL_RECORD_ID_KEY, spellRecordId)
        activeUnseenHandSpellRecordId = spellRecordId
    end

    refreshUnseenHandAbility()
end

local function onLoad()
    activeUnseenHandSpellRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    refreshUnseenHandAbility()
end

local function onNewGame()
    activeUnseenHandSpellRecordId = nil
    effectsSection:set(SPELL_RECORD_ID_KEY, nil)
    refreshUnseenHandAbility()
end

return {
    engineHandlers = {
        onUpdate = refreshUnseenHandAbility,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
