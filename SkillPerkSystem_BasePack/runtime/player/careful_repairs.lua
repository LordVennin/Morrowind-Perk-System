-- Careful Repairs player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_shared_state = require("scripts.SkillPerkSystem_BasePack.runtime.shared")
local __basepack_repair_tool_state = __basepack_shared_state.repairToolState
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")

local NO_CONSUME_CHANCE = 0.15
local SUPPRESS_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_SuppressRepairToolDrops"
local MODIFY_REPAIR_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_ModifyRepairToolCondition"
local REFUND_RESULT_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_RefundResult"
local REPAIR_TOOL_USE_EVENT = "SkillPerkSystem_RecordRepairTool"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local CAREFUL_REPAIRS_PERK_ID = "armorer_careful_repairs"
local MAX_CONDITION_ROLLS_PER_UPDATE = 8
local LOG_TAG = "[SkillPerkSystem_BasePack][CarefulRepairs]"

local trackedToolsByKey = {}
local suppressDropsRemaining = 0
local repairToolScanRemaining = 0
local repairToolScanTimer = 0
local repairToolsDirty = false
local repairMenuActive = false
local REPAIR_TOOL_SCAN_WINDOW = 2.0
local REPAIR_TOOL_SCAN_INTERVAL = 0.25

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

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        return "record:" .. recordId
    end

    local okId, id = pcall(function()
        return item.id
    end)
    if okId and id ~= nil then
        return "id:" .. tostring(id)
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        return "record:" .. recordId .. ":" .. tostring(item)
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

local function findRepairToolByRecordId(recordId, excludeItem)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local fallback = nil
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and item ~= excludeItem and item.recordId == recordId and types.Repair.objectIsInstance(item) then
            local condition = repairToolCondition(item)
            if type(condition) == "number" and condition > 0 then
                return item
            end
            fallback = fallback or item
        end
    end

    return fallback
end

local function findAnyUsableRepairTool(excludeItem)
    local fallback = nil
    for _, item in ipairs(getRepairTools()) do
        if item ~= nil and item ~= excludeItem and types.Repair.objectIsInstance(item) then
            local condition = repairToolCondition(item)
            if type(condition) == "number" and condition > 0 then
                return item
            end
            fallback = fallback or item
        end
    end
    return fallback
end

local function switchSharedActiveRepairTool(item, source, resetCondition)
    if item == nil or not types.Repair.objectIsInstance(item) then
        return nil
    end

    __basepack_repair_tool_state.item = item
    __basepack_repair_tool_state.recordId = item.recordId
    if resetCondition ~= false then
        __basepack_repair_tool_state.lastCondition = repairToolCondition(item)
    end
    __basepack_repair_tool_state.source = source
    return item
end

local function resolveSharedActiveRepairTool()
    local item = __basepack_repair_tool_state.item
    if item ~= nil and types.Repair.objectIsInstance(item) then
        local condition = repairToolCondition(item)
        if type(condition) == "number" then
            if condition > 0 or __basepack_repair_tool_state.lastCondition ~= condition then
                return item
            end

            if not repairMenuActive then
                return item
            end
        end

        if repairMenuActive then
            local replacement = findRepairToolByRecordId(__basepack_repair_tool_state.recordId, item)
                or findAnyUsableRepairTool(item)
            if replacement ~= nil then
                return switchSharedActiveRepairTool(replacement, "repairMenuRollover")
            end
        end
    end

    item = findRepairToolByRecordId(__basepack_repair_tool_state.recordId)
    if item == nil and repairMenuActive then
        item = findAnyUsableRepairTool(nil)
    end

    return switchSharedActiveRepairTool(item, "repairToolResolve")
end

local function requestRefund(toolState, amount)
    if toolState == nil or toolState.item == nil then
        return false
    end

    if type(amount) ~= "number" or amount <= 0 then
        return false
    end

    core.sendGlobalEvent(MODIFY_REPAIR_TOOL_CONDITION_EVENT, {
        player = getActorObject(),
        tool = toolState.item,
        recordId = toolState.recordId,
        amount = amount,
    })
    return true
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

    if requestRefund(toolState, refunds) then
        log(string.format("refund requested uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
    else
        log(string.format("refund request failed uses=%d recordId=%s", refunds, tostring(toolState.recordId)))
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

local function hasTrackedRepairTools()
    return next(trackedToolsByKey) ~= nil
end

local function openRepairToolScanWindow(scanWindow)
    repairToolsDirty = true
    repairToolScanRemaining = math.max(repairToolScanRemaining, tonumber(scanWindow) or REPAIR_TOOL_SCAN_WINDOW)
    repairToolScanTimer = REPAIR_TOOL_SCAN_INTERVAL
end

local function shouldUpdateCarefulRepairs(dt)
    if suppressDropsRemaining > 0 or repairToolsDirty then
        return true
    end

    if repairMenuActive then
        repairToolScanRemaining = math.max(repairToolScanRemaining, REPAIR_TOOL_SCAN_WINDOW)
        repairToolScanTimer = 0
        return true
    end

    if hasTrackedRepairTools() and repairToolScanRemaining > 0 then
        local deltaTime = tonumber(dt) or 0
        repairToolScanRemaining = math.max(0, repairToolScanRemaining - deltaTime)
        if repairToolScanRemaining <= 0 then
            trackedToolsByKey = {}
            return false
        end

        repairToolScanTimer = repairToolScanTimer + deltaTime
        if repairToolScanTimer < REPAIR_TOOL_SCAN_INTERVAL then
            return false
        end

        repairToolScanTimer = 0
        return true
    end

    return false
end

local function maybeRefundMissingTools(previousToolsByKey, currentToolsByKey)
    for key, previousState in pairs(previousToolsByKey) do
        if currentToolsByKey[key] == nil and type(previousState.condition) == "number" and previousState.condition <= 1 then
            if suppressDropsRemaining > 0 then
                suppressDropsRemaining = math.max(0, suppressDropsRemaining - 1)
                log(string.format("suppressed disappeared repair tool drop remaining=%d recordId=%s", suppressDropsRemaining, tostring(previousState.recordId)))
            else
                rollAndRefund(previousState, 1)
            end
        end
    end
end

local function compareSharedActiveRepairTool()
    local item = resolveSharedActiveRepairTool()
    if item == nil then
        __basepack_repair_tool_state.lastCondition = nil
        return nil, nil
    end

    local condition = repairToolCondition(item)
    local key = objectKey(item)
    local currentState = {
        item = item,
        recordId = item.recordId,
        condition = condition,
    }

    local previousCondition = __basepack_repair_tool_state.lastCondition
    if type(condition) ~= "number" then
        return key, currentState
    end

    if type(previousCondition) == "number" and condition < previousCondition then
        local delta = math.floor(previousCondition - condition)
        if delta < 1 then
            delta = 1
        end
        local rollAttempts = math.min(delta, MAX_CONDITION_ROLLS_PER_UPDATE)
        rollAndRefund(currentState, rollAttempts)

        if condition <= 0 and repairMenuActive then
            local replacement = findRepairToolByRecordId(item.recordId, item) or findAnyUsableRepairTool(item)
            if replacement ~= nil then
                local replacementCondition = repairToolCondition(replacement)
                switchSharedActiveRepairTool(replacement, "repairToolConsumed")
                return objectKey(replacement), {
                    item = replacement,
                    recordId = replacement.recordId,
                    condition = replacementCondition,
                }
            end
        end
    end

    __basepack_repair_tool_state.item = item
    __basepack_repair_tool_state.recordId = item.recordId
    __basepack_repair_tool_state.lastCondition = condition
    return key, currentState
end

local function shouldFrameCarefulRepairs()
    return repairMenuActive or repairToolsDirty
end

local function onUpdate()
    if not carefulRepairsEnabled() then
        trackedToolsByKey = {}
        suppressDropsRemaining = 0
        return
    end

    repairToolsDirty = false
    local activeKey, activeState = compareSharedActiveRepairTool()
    local currentToolsByKey = snapshotRepairTools()
    if activeKey ~= nil and activeState ~= nil then
        currentToolsByKey[activeKey] = activeState
    end

    for key, currentState in pairs(currentToolsByKey) do
        if key ~= activeKey then
            maybeRefundCondition(trackedToolsByKey[key], currentState)
        end
    end
    maybeRefundMissingTools(trackedToolsByKey, currentToolsByKey)

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

    if data.source == "apprentice_hammer_overrepair" then
        trackedToolsByKey = {}
        repairToolsDirty = false
        repairToolScanRemaining = 0
        repairToolScanTimer = 0
        log(string.format("skipping overrepair tool-drop scan amount=%d", amount))
        return
    end

    suppressDropsRemaining = suppressDropsRemaining + amount
    trackedToolsByKey = snapshotRepairTools()
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("suppressing next repair tool drops amount=%d total=%d", amount, suppressDropsRemaining))
end

local function handleRepairToolUse(data)
    if type(data) ~= "table" or data.item == nil then
        return
    end

    if not carefulRepairsEnabled() then
        return
    end

    __basepack_repair_tool_state.item = data.item
    __basepack_repair_tool_state.recordId = data.recordId or data.item.recordId
    __basepack_repair_tool_state.lastCondition = repairToolCondition(data.item)
    __basepack_repair_tool_state.source = "recordRepairTool"
    trackedToolsByKey = snapshotRepairTools()
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("repair tool use captured recordId=%s", tostring(data.recordId or data.item.recordId)))
end

local function handleUiModeChanged(data)
    if type(data) ~= "table" then
        return
    end

    repairMenuActive = data.newMode == "Repair"
    if repairMenuActive then
        openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    elseif data.newMode == nil or data.newMode == "MainMenu" then
        repairToolScanRemaining = math.min(repairToolScanRemaining, REPAIR_TOOL_SCAN_WINDOW)
    end
end

local function handleRefundResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success ~= true then
        log(string.format(
            "refund failed uses=%s recordId=%s reason=%s",
            tostring(data.amount),
            tostring(data.recordId),
            tostring(data.reason)
        ))
        return
    end

    local amount = math.floor(tonumber(data.amount) or 0)
    if amount <= 0 then
        return
    end

    local useLabel = amount == 1 and "use" or "uses"
    ui.showMessage(string.format("Careful Repairs preserved %d repair tool %s.", amount, useLabel), { showInDialogue = false })
    openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
    log(string.format("refunded uses=%d recordId=%s", amount, tostring(data.recordId)))
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdateCarefulRepairs,
        onFrame = onUpdate,
        shouldFrame = shouldFrameCarefulRepairs,
        onLoad = function(data)
            suppressDropsRemaining = math.max(0, math.floor(tonumber(type(data) == "table" and data.suppressDropsRemaining) or 0))
            trackedToolsByKey = {}
            if suppressDropsRemaining > 0 then
                openRepairToolScanWindow(REPAIR_TOOL_SCAN_WINDOW)
            end
        end,
        onSave = function()
            return {
                suppressDropsRemaining = suppressDropsRemaining,
            }
        end,
    },
    eventHandlers = {
        UiModeChanged = handleUiModeChanged,
        [REPAIR_TOOL_USE_EVENT] = handleRepairToolUse,
        [SUPPRESS_EVENT] = handleSuppressRepairToolDrops,
        [REFUND_RESULT_EVENT] = handleRefundResult,
    },
}


return __basepack_subsystem_result
