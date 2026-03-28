local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local COIN_RECORD_ID_KEY = "security.lucky_find.coin_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"
local GOLD_TEMPLATE_RECORD_ID = "gold_001"

-- Lucky Coin record ID used for Lucky Find drops.
-- We try to create this record at runtime from gold_001 if it's missing.
local CONFIGURED_LUCKY_COIN_RECORD_ID = "sps_lucky_coin"

local FIND_CHANCE = 0.02
local DEBUG_LUCKY_FIND = true

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

-- Per-save state.
local checkedContainers = {}
local appliedLuckBonus = 0
local luckyCoinRecordReady = false
local activeLuckyCoinRecordId = nil
local lastLoggedCoinCount = nil

local function log(message)
    if not DEBUG_LUCKY_FIND then
        return
    end
    print("[SkillPerkSystem_BasePack][LuckyFind] " .. tostring(message))
end

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
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] failed to create lucky coin object from record '%s'",
            tostring(recordId)
        ))
        return false
    end

    coin:moveInto(types.Container.inventory(container))
    log(string.format("added %d lucky coin(s) to container=%s record=%s", amount, tostring(container), tostring(recordId)))
    return true
end

local function clampNonNegativeInteger(value)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then
        return 0
    end
    return n
end

local function ensureLuckyCoinRecord()
    if luckyCoinRecordReady then
        return true
    end

    if types.Miscellaneous == nil then
        print("[SkillPerkSystem_BasePack][LuckyFind] types.Miscellaneous unavailable")
        return false
    end
    local okRecords, records = pcall(function()
        return types.Miscellaneous.records
    end)
    if not okRecords or records == nil then
        print("[SkillPerkSystem_BasePack][LuckyFind] types.Miscellaneous.records unavailable")
        return false
    end

    if type(activeLuckyCoinRecordId) == "string"
        and activeLuckyCoinRecordId ~= ""
        and records[activeLuckyCoinRecordId] ~= nil
    then
        luckyCoinRecordReady = true
        return true
    end

    local configuredRecord = records[CONFIGURED_LUCKY_COIN_RECORD_ID]
    if configuredRecord ~= nil then
        activeLuckyCoinRecordId = CONFIGURED_LUCKY_COIN_RECORD_ID
        effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
        luckyCoinRecordReady = true
        log(string.format("using configured lucky coin record '%s'", tostring(activeLuckyCoinRecordId)))
        return true
    end

    local savedRecordId = effectsSection:get(COIN_RECORD_ID_KEY)
    if type(savedRecordId) == "string" and savedRecordId ~= "" and records[savedRecordId] ~= nil then
        activeLuckyCoinRecordId = savedRecordId
        luckyCoinRecordReady = true
        log(string.format("using saved lucky coin record '%s'", tostring(activeLuckyCoinRecordId)))
        return true
    end

    if type(types.Miscellaneous.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] missing record API; add '%s' as a Misc record in a plugin",
            tostring(CONFIGURED_LUCKY_COIN_RECORD_ID)
        ))
        return false
    end

    local template = records[GOLD_TEMPLATE_RECORD_ID]
    if template == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] missing template record '%s' while creating '%s'",
            tostring(GOLD_TEMPLATE_RECORD_ID),
            tostring(CONFIGURED_LUCKY_COIN_RECORD_ID)
        ))
        return false
    end

    local okDraft, recordDraft = pcall(types.Miscellaneous.createRecordDraft, {
        template = template,
        name = "Lucky Coin",
        weight = 0.01,
    })
    if not okDraft or recordDraft == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] failed to build record draft '%s': %s",
            tostring(CONFIGURED_LUCKY_COIN_RECORD_ID),
            tostring(recordDraft)
        ))
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
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] failed to create record '%s': %s",
            tostring(CONFIGURED_LUCKY_COIN_RECORD_ID),
            tostring(createdRecord)
        ))
        return false
    end

    activeLuckyCoinRecordId = createdId
    effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
    luckyCoinRecordReady = true
    log(string.format(
        "created runtime record '%s' (Lucky Coin) from '%s'",
        tostring(activeLuckyCoinRecordId),
        tostring(GOLD_TEMPLATE_RECORD_ID)
    ))
    return true
end

local function countLuckyCoinsInInventory(actor)
    if actor == nil then
        return 0
    end

    if types.Actor == nil or type(types.Actor.inventory) ~= "function" then
        return 0
    end

    local okInventory, inventory = pcall(types.Actor.inventory, actor)
    if not okInventory or inventory == nil then
        return 0
    end

    if type(inventory.countOf) ~= "function" then
        return 0
    end

    if not ensureLuckyCoinRecord() then
        return 0
    end

    local count = nil

    if type(inventory.countOf) == "function" then
        local okCountA, countA = pcall(function()
            return inventory:countOf(activeLuckyCoinRecordId)
        end)
        if okCountA and type(countA) == "number" then
            count = countA
        end

        if (count == nil or count <= 0) and types.Miscellaneous ~= nil then
            local okRecord, record = pcall(function()
                return types.Miscellaneous.records[activeLuckyCoinRecordId]
            end)
            if okRecord and record ~= nil then
                local okCountB, countB = pcall(function()
                    return inventory:countOf(record)
                end)
                if okCountB and type(countB) == "number" then
                    count = countB
                end
            end
        end
    end

    local normalizedCount = clampNonNegativeInteger(count or 0)
    if lastLoggedCoinCount ~= normalizedCount then
        log(string.format("inventory lucky coin count=%d record=%s", normalizedCount, tostring(activeLuckyCoinRecordId)))
        lastLoggedCoinCount = normalizedCount
    end

    return normalizedCount
end

local function resolveLuckStat(actor)
    if actor == nil then
        return nil
    end

    local okType, actorType = pcall(function()
        return actor.type
    end)
    if not okType or actorType == nil then
        return nil
    end

    local function tryLuckGetter(t)
        if t == nil then
            return nil
        end

        local okStats, stats = pcall(function()
            return t.stats
        end)
        if not okStats or stats == nil then
            return nil
        end

        local okAttrs, attrs = pcall(function()
            return stats.attributes
        end)
        if not okAttrs or attrs == nil then
            return nil
        end

        local okFn, fn = pcall(function()
            return attrs.luck
        end)
        if not okFn or type(fn) ~= "function" then
            return nil
        end

        local okStat, stat = pcall(fn, actor)
        if not okStat then
            return nil
        end

        return stat
    end

    local stat = tryLuckGetter(actorType)
    if stat ~= nil then
        return stat
    end

    local okBase, baseType = pcall(function()
        return actorType.baseType
    end)
    if okBase and baseType ~= nil then
        stat = tryLuckGetter(baseType)
        if stat ~= nil then
            return stat
        end
    end

    return nil
end

local function applyLuckBonus(actor, targetBonus)
    local desired = clampNonNegativeInteger(targetBonus)
    local currentApplied = clampNonNegativeInteger(appliedLuckBonus)
    if currentApplied == desired then
        return
    end

    local stat = resolveLuckStat(actor)
    if stat == nil or type(stat.base) ~= "number" then
        log("unable to resolve writable luck stat for player")
        return
    end

    local newBase = math.max(0, math.floor(stat.base - currentApplied + desired))
    stat.base = newBase
    appliedLuckBonus = desired
    log(string.format("applied luck bonus %d -> %d (new base=%d)", currentApplied, desired, newBase))
end

local function refreshLuckBonusForPlayer()
    local actor = world.players[1]
    if actor == nil then
        return
    end

    if not luckyFindEnabled() then
        applyLuckBonus(actor, 0)
        return
    end

    applyLuckBonus(actor, countLuckyCoinsInInventory(actor))
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    effectsSection:set(ENABLED_KEY, data.enable == true)
    log(string.format("toggle enable=%s", tostring(data.enable == true)))
    refreshLuckBonusForPlayer()
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
        -- Don't consume the one-time check when setup failed.
        return
    end

    -- Only one Lucky Find check should happen per container.
    checkedContainers[key] = true

    if foundCoin then
        addLuckyCoinsToContainer(object, 1)
    end
end

local function onUpdate()
    refreshLuckBonusForPlayer()
end

local function onSave()
    return {
        checkedContainers = checkedContainers,
        appliedLuckBonus = appliedLuckBonus,
    }
end

local function onLoad(savedData)
    checkedContainers = {}
    appliedLuckBonus = 0
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    -- onLoad starts disabled until perk effects are synced and toggled back on.
    effectsSection:set(ENABLED_KEY, false)

    if type(savedData) == "table" then
        if type(savedData.checkedContainers) == "table" then
            checkedContainers = savedData.checkedContainers
        end
        if type(savedData.appliedLuckBonus) == "number" then
            appliedLuckBonus = clampNonNegativeInteger(savedData.appliedLuckBonus)
        end
    end

    refreshLuckBonusForPlayer()
end

local function onNewGame()
    checkedContainers = {}
    appliedLuckBonus = 0
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    effectsSection:set(ENABLED_KEY, false)
    effectsSection:set(COIN_RECORD_ID_KEY, nil)
    refreshLuckBonusForPlayer()
end

return {
    engineHandlers = {
        onActivate = onActivate,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
