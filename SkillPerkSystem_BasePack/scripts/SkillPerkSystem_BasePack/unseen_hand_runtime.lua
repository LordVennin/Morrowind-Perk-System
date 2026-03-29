local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

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

local unseenHandSpellRecordReady = false
local activeUnseenHandSpellRecordId = nil

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

local function parseCreatedRecordId(createdRecord)
    if type(createdRecord) == "string" and createdRecord ~= "" then
        return createdRecord
    end

    if createdRecord ~= nil then
        local okId, idValue = pcall(function()
            return createdRecord.id
        end)
        if okId and type(idValue) == "string" and idValue ~= "" then
            return idValue
        end
    end

    return nil
end

local function createUnseenHandSpellRecord()
    if type(types.Spell) ~= "table" then
        return nil
    end

    if type(types.Spell.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        return nil
    end

    local effectType = core.magic and core.magic.EFFECT_TYPE
    local spellType = core.magic and core.magic.SPELL_TYPE
    local range = core.magic and core.magic.RANGE
    if type(effectType) ~= "table" or type(spellType) ~= "table" or type(range) ~= "table" then
        return nil
    end

    local okDraft, recordDraft = pcall(types.Spell.createRecordDraft, {
        name = "Burglar's Instinct",
        type = spellType.Ability,
        cost = 0,
        effects = {
            {
                id = effectType.Chameleon,
                range = range.Self,
                magnitudeMin = 15,
                magnitudeMax = 15,
                duration = 1,
                area = 0,
            },
            {
                id = effectType.Sanctuary,
                range = range.Self,
                magnitudeMin = 15,
                magnitudeMax = 15,
                duration = 1,
                area = 0,
            },
        },
    })
    if not okDraft or recordDraft == nil then
        return nil
    end

    local okCreate, createdRecord = pcall(world.createRecord, recordDraft)
    if not okCreate then
        return nil
    end

    return parseCreatedRecordId(createdRecord)
end

local function ensureUnseenHandSpellRecord()
    if unseenHandSpellRecordReady then
        return true
    end

    if type(activeUnseenHandSpellRecordId) == "string"
        and activeUnseenHandSpellRecordId ~= ""
        and spellRecordExists(activeUnseenHandSpellRecordId)
    then
        unseenHandSpellRecordReady = true
        return true
    end

    if spellRecordExists(DEFAULT_SPELL_RECORD_ID) then
        activeUnseenHandSpellRecordId = DEFAULT_SPELL_RECORD_ID
        effectsSection:set(SPELL_RECORD_ID_KEY, activeUnseenHandSpellRecordId)
        unseenHandSpellRecordReady = true
        return true
    end

    local savedRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    if spellRecordExists(savedRecordId) then
        activeUnseenHandSpellRecordId = savedRecordId
        unseenHandSpellRecordReady = true
        return true
    end

    local createdId = createUnseenHandSpellRecord()
    if type(createdId) ~= "string" or createdId == "" then
        return false
    end

    activeUnseenHandSpellRecordId = createdId
    effectsSection:set(SPELL_RECORD_ID_KEY, activeUnseenHandSpellRecordId)
    unseenHandSpellRecordReady = true
    return true
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
    if not ensureUnseenHandSpellRecord() then
        return
    end

    local spellRecordId = activeUnseenHandSpellRecordId
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
        activeUnseenHandSpellRecordId = spellRecordId
        unseenHandSpellRecordReady = false
    end

    refreshUnseenHandAbility()
end

local function onLoad()
    unseenHandSpellRecordReady = false
    activeUnseenHandSpellRecordId = nil
    refreshUnseenHandAbility()
end

local function onNewGame()
    unseenHandSpellRecordReady = false
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
