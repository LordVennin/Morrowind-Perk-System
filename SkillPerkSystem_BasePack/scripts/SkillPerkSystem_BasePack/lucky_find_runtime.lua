local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local COIN_RECORD_ID_KEY = "security.lucky_find.coin_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"
local GOLD_TEMPLATE_RECORD_ID = "gold_001"
local CONFIGURED_LUCKY_COIN_RECORD_ID = "sps_lucky_coin"
local FIND_CHANCE = 0.02

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

local checkedContainers = {}
local luckyCoinRecordReady = false
local activeLuckyCoinRecordId = nil

local function luckyFindEnabled()
    return effectsSection:get(ENABLED_KEY) == true
end

local function objectKey(object)
    local explicitId = object.id or object.formId
    if explicitId ~= nil then
        return "id:" .. tostring(explicitId)
    end

    local recordId = tostring(object.recordId or "<unknown>")
    local cellPart = "cell:<unknown>"
    local okCell, cell = pcall(function()
        return object.cell
    end)
    if okCell and cell ~= nil then
        local name = cell.name or cell.id
        if type(name) == "string" and name ~= "" then
            cellPart = "cell:" .. name
        end
    end

    local posPart = "pos:<unknown>"
    local okPos, pos = pcall(function()
        return object.position
    end)
    if okPos and pos ~= nil and type(pos.x) == "number" and type(pos.y) == "number" and type(pos.z) == "number" then
        posPart = string.format("pos:%.3f,%.3f,%.3f", pos.x, pos.y, pos.z)
    end

    return table.concat({
        "record:" .. recordId,
        cellPart,
        posPart,
    }, "|")
end

local function ensureLuckyCoinRecord()
    if luckyCoinRecordReady then
        return true
    end

    if types.Miscellaneous == nil then
        return false
    end

    local okRecords, records = pcall(function()
        return types.Miscellaneous.records
    end)
    if not okRecords or records == nil then
        return false
    end

    if type(activeLuckyCoinRecordId) == "string" and activeLuckyCoinRecordId ~= "" and records[activeLuckyCoinRecordId] ~= nil then
        luckyCoinRecordReady = true
        return true
    end

    local configuredRecord = records[CONFIGURED_LUCKY_COIN_RECORD_ID]
    if configuredRecord ~= nil then
        activeLuckyCoinRecordId = CONFIGURED_LUCKY_COIN_RECORD_ID
        effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
        luckyCoinRecordReady = true
        return true
    end

    local savedRecordId = effectsSection:get(COIN_RECORD_ID_KEY)
    if type(savedRecordId) == "string" and savedRecordId ~= "" and records[savedRecordId] ~= nil then
        activeLuckyCoinRecordId = savedRecordId
        luckyCoinRecordReady = true
        return true
    end

    if type(types.Miscellaneous.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        return false
    end

    local template = records[GOLD_TEMPLATE_RECORD_ID]
    if template == nil then
        return false
    end

    local okDraft, recordDraft = pcall(types.Miscellaneous.createRecordDraft, {
        template = template,
        name = "Lucky Coin",
        weight = 0.01,
    })
    if not okDraft or recordDraft == nil then
        return false
    end

    local okCreate, createdRecord = pcall(world.createRecord, recordDraft)
    local createdId = nil
    if type(createdRecord) == "string" then
        createdId = createdRecord
    elseif createdRecord ~= nil then
        local okId, idValue = pcall(function()
            return createdRecord.id
        end)
        if okId and type(idValue) == "string" and idValue ~= "" then
            createdId = idValue
        end
    end

    if not okCreate or type(createdId) ~= "string" or createdId == "" then
        return false
    end

    activeLuckyCoinRecordId = createdId
    effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
    luckyCoinRecordReady = true
    return true
end

local function addLuckyCoinsToContainer(container, amount)
    if amount <= 0 then
        return false
    end

    local recordId = activeLuckyCoinRecordId
    if type(recordId) ~= "string" or recordId == "" then
        return false
    end

    local ok, coin = pcall(world.createObject, recordId, amount)
    if not ok or coin == nil then
        return false
    end

    coin:moveInto(types.Container.inventory(container))
    return true
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    effectsSection:set(ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor == nil or actor ~= world.players[1] then
        return
    end

    if not luckyFindEnabled() then
        return
    end

    if not types.Container.objectIsInstance(object) then
        return
    end

    local key = objectKey(object)
    if checkedContainers[key] then
        return
    end

    local foundCoin = math.random() <= FIND_CHANCE
    if foundCoin and not ensureLuckyCoinRecord() then
        return
    end

    checkedContainers[key] = true

    if foundCoin then
        addLuckyCoinsToContainer(object, 1)
    end
end

local function onSave()
    return {
        checkedContainers = checkedContainers,
    }
end

local function onLoad(savedData)
    checkedContainers = {}
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    effectsSection:set(ENABLED_KEY, false)

    if type(savedData) == "table" and type(savedData.checkedContainers) == "table" then
        checkedContainers = savedData.checkedContainers
    end
end

local function onNewGame()
    checkedContainers = {}
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    effectsSection:set(ENABLED_KEY, false)
    effectsSection:set(COIN_RECORD_ID_KEY, nil)
end

return {
    engineHandlers = {
        onActivate = onActivate,
        onSave = onSave,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
