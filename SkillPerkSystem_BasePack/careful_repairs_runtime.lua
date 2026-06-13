local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")

local NO_CONSUME_CHANCE = 0.15
local SUPPRESS_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_SuppressRepairToolDrops"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local CAREFUL_REPAIRS_PERK_ID = "armorer_careful_repairs"
local MAX_CONDITION_ROLLS_PER_UPDATE = 8
local LOG_TAG = "[SkillPerkSystem_BasePack][CarefulRepairs]"

local trackedToolsByKey = {}
local suppressDropsRemaining = 0

local function log(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function carefulRepairsEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(CAREFUL_REPAIRS_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(CAREFUL_REPAIRS_PERK_ID) then
        return false
    end

    return true
end

local function getActorObject()
    return pself.object or pself
end

local function getPlayerInventory()
    local okInv, inventory = pcall(types.Actor.inventory, getActorObject())
    if not okInv or inventory == nil then
        return nil
    end
    return inventory
end

local function sequenceToArray(seq)
    if seq == nil then
        return {}
    end

    local out = {}
    local okLen, len = pcall(function()
        return #seq
    end)
    if okLen and type(len) == "number" then
        for i = 1, len do
            out[#out + 1] = seq[i]
        end
        return out
    end

    local okPairs = pcall(function()
        for _, item in pairs(seq) do
            out[#out + 1] = item
        end
    end)
    if not okPairs then
        return {}
    end

    return out
end

local function getRepairTools()
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll(types.Repair)
    end)
    if okAll and items ~= nil then
        return sequenceToArray(items)
    end

    return {}
end

local function repairToolCondition(item)
    if item == nil or not types.Repair.objectIsInstance(item) then
        return nil
    end

    local okData, data = pcall(types.Item.itemData, item)
    if not okData or data == nil then
        return nil
    end

    local okCondition, condition = pcall(function()
        return data.condition
    end)
    if okCondition and type(condition) == "number" then
        return condition, data
    end

    return nil, data
end

local function repairToolMaxCondition(item)
    if item == nil then
        return nil
    end

    local okRecord, record = pcall(types.Repair.record, item)
    if okRecord and record ~= nil then
        local okMax, maxCondition = pcall(function()
            return record.maxCondition
        end)
        if okMax and type(maxCondition) == "number" then
            return maxCondition
        end
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        local okById, recordById = pcall(function()
            return types.Repair.records[recordId]
        end)
        if okById and recordById ~= nil then
            local okMax, maxCondition = pcall(function()
                return recordById.maxCondition
            end)
            if okMax and type(maxCondition) == "number" then
                return maxCondition
            end
        end
    end

    return nil
end

local function objectKey(item)
    if item == nil then
        return nil
    end

    local okId, id = pcall(function()
        return item.id
    end)
    if okId and id ~= nil then
        return tostring(id)
    end

    return tostring(item)
end

local function snapshotRepairTools()
    local out = {}
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and types.Repair.objectIsInstance(item) then
            local key = objectKey(item)
            local condition = repairToolCondition(item)
            if key ~= nil then
                out[key] = {
                    item = item,
                    recordId = item.recordId,
                    condition = condition,
                }
            end
        end
    end
    return out
end

local function writeRefund(toolState, amount)
    if toolState == nil or toolState.item == nil then
        return false
    end

    local currentCondition, data = repairToolCondition(toolState.item)
    if type(currentCondition) ~= "number" or data == nil then
        return false
    end

    local newCondition = currentCondition + amount
    local maxCondition = repairToolMaxCondition(toolState.item)
    if type(maxCondition) == "number" and newCondition > maxCondition then
        newCondition = maxCondition
    end

    local okWrite = pcall(function()
        data.condition = newCondition
    end)
    return okWrite
end

local function rollAndRefund(toolState, attempts)
    if not carefulRepairsEnabled() then
        return
    end

    local chance = NO_CONSUME_CHANCE

    local refunds = 0
    for _ = 1, attempts do
        if math.random() < chance then
            refunds = refunds + 1
        end
    end

    if refunds <= 0 then
        return
    end

    if writeRefund(toolState, refunds) then
        local useLabel = refunds == 1 and "use" or "uses"
        ui.showMessage(string.format("Careful Repairs preserved %d repair tool %s.", refunds, useLabel), { showInDialogue = false })
        log(string.format("refunded uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
    else
        log(string.format("refund failed uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
    end
end

local function maybeRefundCondition(previousState, currentState)
    if previousState == nil or currentState == nil then
        return
    end

    local oldCondition = previousState.condition
    local newCondition = currentState.condition
    if type(oldCondition) ~= "number" or type(newCondition) ~= "number" then
        return
    end
    if newCondition >= oldCondition then
        return
    end

    local delta = math.floor(oldCondition - newCondition)
    if delta < 1 then
        delta = 1
    end

    if suppressDropsRemaining > 0 then
        suppressDropsRemaining = math.max(0, suppressDropsRemaining - delta)
        log(string.format("suppressed repair tool drop delta=%d remaining=%d recordId=%s", delta, suppressDropsRemaining, tostring(currentState.recordId)))
        return
    end

    local rollAttempts = math.min(delta, MAX_CONDITION_ROLLS_PER_UPDATE)
    if delta > rollAttempts then
        log(string.format("multi-use repair tool drop capped delta=%d cap=%d recordId=%s", delta, MAX_CONDITION_ROLLS_PER_UPDATE, tostring(currentState.recordId)))
    end

    rollAndRefund(currentState, rollAttempts)
end

local function onUpdate()
    local currentToolsByKey = snapshotRepairTools()

    if not carefulRepairsEnabled() then
        trackedToolsByKey = currentToolsByKey
        return
    end

    for key, currentState in pairs(currentToolsByKey) do
        maybeRefundCondition(trackedToolsByKey[key], currentState)
    end

    trackedToolsByKey = currentToolsByKey
end

local function handleSuppressRepairToolDrops(data)
    if type(data) ~= "table" then
        return
    end

    local amount = math.floor(tonumber(data.amount) or 0)
    if amount <= 0 then
        return
    end

    suppressDropsRemaining = suppressDropsRemaining + amount
    trackedToolsByKey = snapshotRepairTools()
    log(string.format("suppressing next repair tool drops amount=%d total=%d", amount, suppressDropsRemaining))
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        [SUPPRESS_EVENT] = handleSuppressRepairToolDrops,
    },
}
