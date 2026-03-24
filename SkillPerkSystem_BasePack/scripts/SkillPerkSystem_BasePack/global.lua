local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local types = require("openmw.types")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"

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

local function normalizeNumber(value)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function readItemData(item)
    if item == nil then
        return nil
    end
    if type(item.type) == "table" and type(item.type.itemData) == "function" then
        local ok, data = pcall(item.type.itemData, item)
        if ok and data ~= nil then
            return data
        end
    end
    if types.Item ~= nil and type(types.Item.itemData) == "function" then
        local ok, data = pcall(types.Item.itemData, item)
        if ok and data ~= nil then
            return data
        end
    end
    return nil
end

local function readMaxCondition(item)
    if item == nil then
        return nil
    end
    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local records = nil
    if types.Lockpick.objectIsInstance(item) then
        records = types.Lockpick.records
    elseif types.Probe.objectIsInstance(item) then
        records = types.Probe.records
    end
    if type(records) ~= "table" then
        return nil
    end

    local record = records[recordId]
    if type(record) ~= "table" then
        return nil
    end
    return normalizeNumber(record.maxCondition)
end

local function resolveToolAndActor(data)
    if type(data) ~= "table" then
        return nil, nil, nil
    end

    local actor = data.actor
    local slot = data.slot
    if actor ~= nil and slot ~= nil then
        local ok, equipped = pcall(types.Actor.getEquipment, actor, slot)
        if ok and equipped ~= nil then
            return actor, equipped, slot
        end
    end

    local item = data.item
    if item ~= nil then
        return actor, item, slot
    end

    return actor, nil, slot
end

local function writeToolCondition(data)
    local actor, tool, slot = resolveToolAndActor(data)
    local toolType = classifySecurityTool(tool)
    if toolType == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no security tool resolved) slot=%s actor=%s amount=%s",
            tostring(slot),
            tostring(actor),
            tostring(type(data) == "table" and data.amount or nil)
        ))
        return
    end

    local amount = normalizeNumber(data.amount) or 0
    if amount == 0 then
        return
    end

    local itemData = readItemData(tool)
    if itemData == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no itemData) slot=%s type=%s amount=%s",
            tostring(slot),
            tostring(toolType),
            tostring(amount)
        ))
        return
    end

    local maxCondition = readMaxCondition(tool)

    local currentCondition = nil
    local okCurrent, currentValue = pcall(function()
        return itemData.condition
    end)
    if okCurrent then
        if currentValue == nil then
            currentCondition = maxCondition
        else
            currentCondition = normalizeNumber(currentValue)
        end
    end

    if currentCondition == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (invalid condition data) slot=%s type=%s condition=%s maxCondition=%s amount=%s",
            tostring(slot),
            tostring(toolType),
            tostring(okCurrent and currentValue or nil),
            tostring(maxCondition),
            tostring(amount)
        ))
        return
    end

    if maxCondition ~= nil and currentCondition >= maxCondition and amount > 0 then
        return
    end

    local newCondition = currentCondition + amount
    if maxCondition ~= nil and newCondition > maxCondition then
        newCondition = maxCondition
    end

    if newCondition <= 0 then
        local removed = pcall(function()
            tool:remove()
        end)
        if removed then
            return
        end
        newCondition = 0
    end

    local okWrite, writeErr = pcall(function()
        itemData.condition = newCondition
    end)
    if not okWrite then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund write failed slot=%s type=%s amount=%s current=%s target=%s err=%s",
            tostring(slot),
            tostring(toolType),
            tostring(amount),
            tostring(currentCondition),
            tostring(newCondition),
            tostring(writeErr)
        ))
    end
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
    },
}
