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

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)

local function resolveSpellRecordId()
    local configured = effectsSection:get(SPELL_RECORD_ID_KEY)
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    return DEFAULT_SPELL_RECORD_ID
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
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        return nil
    end

    return spells
end

local function ensureSpellState(shouldHave)
    local spellRecordId = resolveSpellRecordId()
    if type(spellRecordId) ~= "string" or spellRecordId == "" then
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
        pcall(function()
            spells:add(spellRecordId)
        end)
    elseif (not shouldHave) and hasSpell and type(spells.remove) == "function" then
        pcall(function()
            spells:remove(spellRecordId)
        end)
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
    elseif data.enable ~= true then
        effectsSection:set(SPELL_RECORD_ID_KEY, DEFAULT_SPELL_RECORD_ID)
    end

    refreshUnseenHandAbility()
end

local function onLoad()
    refreshUnseenHandAbility()
end

local function onNewGame()
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
