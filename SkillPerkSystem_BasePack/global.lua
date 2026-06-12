local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local types = require("openmw.types")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"
local APPRENTICE_HAMMER_OVERREPAIR_REQUEST_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest"
local APPRENTICE_HAMMER_OVERREPAIR_RESULT_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairResult"
local DRAIN_LOCKPICK_EVENT = "DrainLockpick"
local TUMBLER_SENSE_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local TUMBLER_SENSE_FAILURE_SOURCE = "drain_lockpick_event"

local function classifySecurityTool(item)
    if item == nil then
        return nil
    end
    if types.Lockpick.objectIsInstance(item) then
        return "Lockpick"
    end
    if types.Probe.objectIsInstance(item) then
        return "Probe"
    end
    return nil
end

local function apprenticeHammerLog(message)
    print("[SkillPerkSystem_BasePack][ApprenticeHammer][Global] " .. tostring(message))
end

local function sendOverrepairResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(APPRENTICE_HAMMER_OVERREPAIR_RESULT_EVENT, result)
    end
end

local function safeGetRecordField(record, fieldName)
    if record == nil then return nil end

    local okField, value = pcall(function()
        return record[fieldName]
    end)
    if okField then
        return value
    end
    return nil
end

local function getEquipmentRecord(item)
    if item == nil then return nil end

    if types.Weapon.objectIsInstance(item) then
        local okRecord, record = pcall(types.Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Weapon.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    elseif types.Armor.objectIsInstance(item) then
        local okRecord, record = pcall(types.Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Armor.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    end

    return nil
end

local function getEquipmentMaxCondition(item)
    local record = getEquipmentRecord(item)
    return tonumber(safeGetRecordField(record, "health") or safeGetRecordField(record, "maxCondition"))
end

local function isAtNormalMaxCondition(currentCondition, maxCondition)
    if type(currentCondition) ~= "number" or type(maxCondition) ~= "number" then
        return false
    end

    local currentRounded = math.floor(currentCondition + 0.5)
    local maxRounded = math.floor(maxCondition + 0.5)
    return currentRounded == maxRounded
end

local function getObjectCount(item)
    if item == nil then return 1 end

    local okCount, count = pcall(function()
        return item.count
    end)
    if okCount and type(count) == "number" and count > 0 then
        return count
    end

    return 1
end

local function splitOneFromStack(item)
    if getObjectCount(item) <= 1 then
        return item, false
    end

    local okSplit, splitItem = pcall(function()
        return item:split(1)
    end)
    if okSplit and splitItem ~= nil then
        return splitItem, true
    end

    return nil, false
end

local function moveIntoPlayerInventory(player, item)
    if player == nil or item == nil then
        return false
    end

    local okInventory, inventory = pcall(types.Actor.inventory, player)
    if not okInventory or inventory == nil then
        return false
    end

    local okMove = pcall(function()
        item:moveInto(inventory)
    end)
    return okMove
end

local function overrepairFailure(player, reason, message, recordId)
    apprenticeHammerLog("overrepair failed reason=" .. tostring(reason) .. " recordId=" .. tostring(recordId))
    sendOverrepairResult(player, {
        success = false,
        reason = reason,
        message = message,
        recordId = recordId,
    })
end

local function applyApprenticeHammerOverrepair(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local repairTool = data.repairTool
    local targetItem = data.targetItem
    local recordId = targetItem ~= nil and targetItem.recordId or nil
    local targetName = data.targetName or recordId or "Item"
    local usesCost = tonumber(data.usesCost) or 5
    local multiplier = tonumber(data.multiplier) or 1.10

    if player == nil then
        overrepairFailure(nil, "missing_player", "That item could not be over-repaired.", recordId)
        return
    end
    if repairTool == nil or not types.Repair.objectIsInstance(repairTool) then
        overrepairFailure(player, "missing_repair_tool", "No repair tool found.", recordId)
        return
    end
    if targetItem == nil or not (types.Weapon.objectIsInstance(targetItem) or types.Armor.objectIsInstance(targetItem)) then
        overrepairFailure(player, "missing_target", "That item is no longer eligible.", recordId)
        return
    end

    local repairToolData = types.Item.itemData(repairTool)
    local repairToolCondition = repairToolData ~= nil and repairToolData.condition or nil
    local sourceTargetData = types.Item.itemData(targetItem)
    local currentCondition = sourceTargetData ~= nil and sourceTargetData.condition or nil
    local maxCondition = getEquipmentMaxCondition(targetItem)

    if type(repairToolCondition) ~= "number" or repairToolCondition < usesCost then
        overrepairFailure(player, "not_enough_tool_uses", "Not enough hammer uses remaining (need 5).", recordId)
        return
    end
    if sourceTargetData == nil or type(currentCondition) ~= "number" then
        overrepairFailure(player, "missing_target_condition", "That item could not be over-repaired.", recordId)
        return
    end
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        overrepairFailure(player, "missing_max_condition", "That item could not be over-repaired.", recordId)
        return
    end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then
        overrepairFailure(player, "target_not_at_normal_max", "That item is no longer eligible.", recordId)
        return
    end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then
        overrepairFailure(player, "target_condition_not_higher", "That item could not be over-repaired.", recordId)
        return
    end

    local remainingToolCondition = repairToolCondition - usesCost
    local targetStackCount = getObjectCount(targetItem)
    local repairToolStackCount = getObjectCount(repairTool)
    local targetStackSplit = false
    local repairToolStackSplit = false
    local okWrite, err = pcall(function()
        local targetToModify = targetItem
        if targetStackCount > 1 then
            targetToModify, targetStackSplit = splitOneFromStack(targetItem)
            if targetToModify == nil then
                error("failed to split target stack")
            end
        end

        local targetData = types.Item.itemData(targetToModify)
        if targetData == nil then
            error("split target has no item data")
        end
        targetData.condition = targetCondition
        if targetStackSplit and not moveIntoPlayerInventory(player, targetToModify) then
            error("failed to move split target back into player inventory")
        end

        if remainingToolCondition <= 0 then
            repairTool:remove(1)
        else
            local repairToolToModify = repairTool
            local writableRepairToolData = repairToolData
            if repairToolStackCount > 1 then
                repairToolToModify, repairToolStackSplit = splitOneFromStack(repairTool)
                if repairToolToModify == nil then
                    error("failed to split repair tool stack")
                end
                writableRepairToolData = types.Item.itemData(repairToolToModify)
                if writableRepairToolData == nil then
                    error("split repair tool has no item data")
                end
            end
            writableRepairToolData.condition = remainingToolCondition
            if repairToolStackSplit and not moveIntoPlayerInventory(player, repairToolToModify) then
                error("failed to move split repair tool back into player inventory")
            end
        end
    end)
    if not okWrite then
        overrepairFailure(player, "write_failed", "That item could not be over-repaired.", recordId)
        apprenticeHammerLog("overrepair write failed err=" .. tostring(err) .. " recordId=" .. tostring(recordId))
        return
    end

    apprenticeHammerLog("overrepair success recordId=" .. tostring(recordId) .. " target=" .. tostring(targetCondition) .. " toolUses=" .. tostring(math.max(remainingToolCondition, 0)) .. " toolRemoved=" .. tostring(remainingToolCondition <= 0) .. " targetSplit=" .. tostring(targetStackSplit) .. " repairToolSplit=" .. tostring(repairToolStackSplit))
    sendOverrepairResult(player, {
        success = true,
        recordId = recordId,
        name = targetName,
        targetCondition = targetCondition,
        repairToolCondition = math.max(remainingToolCondition, 0),
        repairToolRemoved = remainingToolCondition <= 0,
        targetStackSplit = targetStackSplit,
        repairToolStackSplit = repairToolStackSplit,
    })
end

local function writeToolCondition(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil then
        return
    end
    local slot = data.slot
    if slot == nil then
        slot = types.Actor.EQUIPMENT_SLOT.CarriedRight
    end

    local tool = types.Actor.getEquipment(player, slot)
    local toolType = classifySecurityTool(tool)
    if toolType == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no security tool resolved) slot=%s player=%s amount=%s",
            tostring(slot),
            tostring(player),
            tostring(data.amount)
        ))
        return
    end

    local amount = tonumber(data.amount) or 0
    if amount == 0 then
        return
    end

    local itemData = types.Item.itemData(tool)
    if itemData == nil or type(itemData.condition) ~= "number" then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no numeric itemData.condition) slot=%s type=%s amount=%s",
            tostring(slot),
            tostring(toolType),
            tostring(amount)
        ))
        return
    end

    local currentCondition = itemData.condition
    local newCondition = currentCondition + amount

    if newCondition <= 0 then
        tool:remove()
        return
    end

    types.Item.itemData(tool).condition = newCondition
end

local function inferProbeFromItem(item)
    if item == nil then
        return nil
    end

    if types.Probe.objectIsInstance(item) then
        return true
    end

    if types.Lockpick.objectIsInstance(item) then
        return false
    end

    return nil
end

local function inferProbeFromEquipment(player)
    if player == nil or types.Actor == nil or type(types.Actor.getEquipment) ~= "function" then
        return false
    end

    local slots = types.Actor.EQUIPMENT_SLOT or {}
    local rightSlot = slots.CarriedRight
    if rightSlot ~= nil then
        local rightItem = types.Actor.getEquipment(player, rightSlot)
        local probe = inferProbeFromItem(rightItem)
        if probe ~= nil then
            return probe
        end
    end

    local leftSlot = slots.CarriedLeft
    if leftSlot ~= nil then
        local leftItem = types.Actor.getEquipment(player, leftSlot)
        local probe = inferProbeFromItem(leftItem)
        if probe ~= nil then
            return probe
        end
    end

    return false
end

local function normalizeFailureProbe(data)
    if type(data) == "table" and type(data.probe) == "boolean" then
        return data.probe
    end

    if type(data) == "table" then
        local probeFromItem = inferProbeFromItem(data.item)
        if probeFromItem ~= nil then
            return probeFromItem
        end

        return inferProbeFromEquipment(data.player)
    end

    return false
end

local function forwardTumblerSenseFailure(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    local probe = normalizeFailureProbe(data)
    player:sendEvent(TUMBLER_SENSE_FAILURE_EVENT, {
        source = TUMBLER_SENSE_FAILURE_SOURCE,
        probe = probe,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSenseBridge] forwarded failure source=%s mode=%s",
        TUMBLER_SENSE_FAILURE_SOURCE,
        probe and "probe" or "lockpick"
    ))
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
        [APPRENTICE_HAMMER_OVERREPAIR_REQUEST_EVENT] = applyApprenticeHammerOverrepair,
        [DRAIN_LOCKPICK_EVENT] = forwardTumblerSenseFailure,
    },
}
