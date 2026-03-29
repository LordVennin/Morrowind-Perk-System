local core = require("openmw.core")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.unseen_hand.enabled"
local SPELL_RECORD_ID_KEY = "security.unseen_hand.spell_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_Toggle"
local DEFAULT_SPELL_RECORD_ID = "sps_security_burglars_instinct_ability"
local LOG_TAG = "[SkillPerkSystem_BasePack][UnseenHand][Global] "

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)
local activeSpellRecordId = nil
local spellReady = false
local lastForwardedEnabled = nil
local lastForwardedSpellRecordId = nil
local lastFailureKey = nil

local function logDebug(message)
    print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
end

local function logFailureOnce(failureKey, message)
    if lastFailureKey == failureKey then
        return
    end

    lastFailureKey = failureKey
    logDebug(message)
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

local function resolveSpellRecordDraftCreator()
    if type(types.Spell) == "table" and type(types.Spell.createRecordDraft) == "function" then
        return types.Spell.createRecordDraft, "types.Spell.createRecordDraft"
    end

    if core.magic and core.magic.spells and type(core.magic.spells.createRecordDraft) == "function" then
        return core.magic.spells.createRecordDraft, "core.magic.spells.createRecordDraft"
    end

    return nil, nil
end

local function createUnseenHandSpellRecord()
    local createRecordDraftFn, createRecordDraftSource = resolveSpellRecordDraftCreator()
    local worldCreateRecordExists = type(world.createRecord) == "function"
    if type(createRecordDraftFn) ~= "function" or not worldCreateRecordExists then
        logFailureOnce(
            "create:record-api-missing",
            string.format(
                "createUnseenHandSpellRecord early return: types.Spell exists=%s types.Spell.createRecordDraft exists=%s core.magic.spells.createRecordDraft exists=%s world.createRecord exists=%s",
                tostring(type(types.Spell) == "table"),
                tostring(type(types.Spell) == "table" and type(types.Spell.createRecordDraft) == "function"),
                tostring(core.magic and core.magic.spells and type(core.magic.spells.createRecordDraft) == "function"),
                tostring(worldCreateRecordExists)
            )
        )
        return nil
    end

    local effectType = core.magic and core.magic.EFFECT_TYPE
    local spellType = core.magic and core.magic.SPELL_TYPE
    local range = core.magic and core.magic.RANGE
    if type(effectType) ~= "table" or type(spellType) ~= "table" or type(range) ~= "table" then
        return nil
    end

    local okDraft, recordDraft = pcall(createRecordDraftFn, {
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
        logFailureOnce(
            "create:draft-failed",
            string.format("createUnseenHandSpellRecord draft creation failed source=%s exception=%s", tostring(createRecordDraftSource), tostring(recordDraft))
        )
        return nil
    end

    local okCreate, createdRecord = pcall(world.createRecord, recordDraft)
    if not okCreate then
        logFailureOnce(
            "create:record-create-failed",
            string.format("createUnseenHandSpellRecord createRecord failed exception=%s", tostring(createdRecord))
        )
        return nil
    end

    local parsedCreatedRecordId = parseCreatedRecordId(createdRecord)
    if type(parsedCreatedRecordId) ~= "string" or parsedCreatedRecordId == "" then
        logFailureOnce(
            "create:parsed-record-id-invalid",
            string.format(
                "createUnseenHandSpellRecord parsed created record id value=%s",
                tostring(parsedCreatedRecordId)
            )
        )
        return nil
    end

    lastFailureKey = nil
    return parsedCreatedRecordId
end

local function ensureSpellRecord()
    if spellReady then
        return activeSpellRecordId
    end

    if type(activeSpellRecordId) == "string" and activeSpellRecordId ~= "" and spellRecordExists(activeSpellRecordId) then
        spellReady = true
        return activeSpellRecordId
    end

    if spellRecordExists(DEFAULT_SPELL_RECORD_ID) then
        activeSpellRecordId = DEFAULT_SPELL_RECORD_ID
        effectsSection:set(SPELL_RECORD_ID_KEY, activeSpellRecordId)
        spellReady = true
        return activeSpellRecordId
    end

    local savedSpellRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    if spellRecordExists(savedSpellRecordId) then
        activeSpellRecordId = savedSpellRecordId
        spellReady = true
        return activeSpellRecordId
    end

    local createdSpellRecordId = createUnseenHandSpellRecord()
    if type(createdSpellRecordId) ~= "string" or createdSpellRecordId == "" then
        if type(lastFailureKey) == "string" and string.sub(lastFailureKey, 1, 7) == "create:" then
            return nil
        end
        logFailureOnce(
            "ensure:created-record-id-invalid",
            string.format("ensureSpellRecord early return: parsed created record id value=%s", tostring(createdSpellRecordId))
        )
        return nil
    end

    activeSpellRecordId = createdSpellRecordId
    effectsSection:set(SPELL_RECORD_ID_KEY, activeSpellRecordId)
    spellReady = true
    lastFailureKey = nil
    return activeSpellRecordId
end

local function forwardToggleToPlayer()
    local player = world.players[1]
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    local enabled = effectsSection:get(ENABLED_KEY) == true
    local spellRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    if enabled then
        spellRecordId = ensureSpellRecord() or spellRecordId
    end

    if lastForwardedEnabled == enabled and lastForwardedSpellRecordId == spellRecordId then
        return
    end

    player:sendEvent(TOGGLE_EVENT, {
        enable = enabled,
        spellRecordId = spellRecordId,
    })
    lastForwardedEnabled = enabled
    lastForwardedSpellRecordId = spellRecordId
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    local enabled = data.enable == true
    effectsSection:set(ENABLED_KEY, enabled)

    if enabled then
        local spellRecordId = ensureSpellRecord()
        if type(spellRecordId) == "string" and spellRecordId ~= "" then
            effectsSection:set(SPELL_RECORD_ID_KEY, spellRecordId)
        end
    end

    forwardToggleToPlayer()
end

local function onLoad()
    activeSpellRecordId = effectsSection:get(SPELL_RECORD_ID_KEY)
    spellReady = false
    lastForwardedEnabled = nil
    lastForwardedSpellRecordId = nil
    ensureSpellRecord()
    forwardToggleToPlayer()
end

local function onNewGame()
    activeSpellRecordId = nil
    spellReady = false
    lastForwardedEnabled = nil
    lastForwardedSpellRecordId = nil
    effectsSection:set(ENABLED_KEY, false)
    effectsSection:set(SPELL_RECORD_ID_KEY, nil)
    ensureSpellRecord()
    forwardToggleToPlayer()
end

return {
    engineHandlers = {
        onLoad = onLoad,
        onNewGame = onNewGame,
        onUpdate = forwardToggleToPlayer,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
