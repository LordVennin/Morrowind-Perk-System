local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local PERK_ID = "armorer_apprentice_hammer"
local TRIGGER_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_Trigger"
local SECTION_ID = "SkillPerkSystem_BasePack_ApprenticeHammer"
local APPLY_UNTIL_KEY = "applyUntil"
local MULTIPLIER_KEY = "multiplier"
local WINDOW_SECONDS_KEY = "windowSeconds"

local DEFAULT_MULTIPLIER = 1.10
local DEFAULT_WINDOW_SECONDS = 6

local section = storage.playerSection(SECTION_ID)

local function nowSeconds()
    return tonumber(core.getSimulationTime()) or 0
end

local function clampMultiplier(value)
    local n = tonumber(value) or DEFAULT_MULTIPLIER
    if n < 1.0 then
        return 1.0
    end
    return n
end

local function clampWindow(value)
    local n = tonumber(value) or DEFAULT_WINDOW_SECONDS
    if n < 0 then
        return 0
    end
    return n
end

local function isPerkActive()
    local playerApi = interfaces.SkillPerkSystemPlayer
    if type(playerApi) ~= "table" or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(PERK_ID)
    end

    return true
end

local function getItemCondition(item)
    if item == nil then
        return nil
    end

    local itemData = types.Item.itemData(item)
    if itemData == nil or type(itemData.condition) ~= "number" then
        return nil
    end

    return itemData.condition, itemData
end

local function getMaxCondition(item)
    if item == nil then
        return nil
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    if types.Weapon.objectIsInstance(item) then
        local record = types.Weapon.records[recordId]
        if type(record) == "table" then
            return tonumber(record.health or record.maxCondition)
        end
    elseif types.Armor.objectIsInstance(item) then
        local record = types.Armor.records[recordId]
        if type(record) == "table" then
            return tonumber(record.health or record.maxCondition)
        end
    end

    return nil
end

local function applyOverrepairToItem(item, multiplier)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" then
        return false
    end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        return false
    end

    if currentCondition < maxCondition then
        return false
    end

    local target = math.floor(maxCondition * multiplier + 0.5)
    if target <= currentCondition then
        return false
    end

    itemData.condition = target
    return true
end

local function applyOverrepairToEquippedItems()
    local slots = types.Actor.EQUIPMENT_SLOT
    if type(slots) ~= "table" then
        return
    end

    local multiplier = clampMultiplier(section:get(MULTIPLIER_KEY))
    local changedAny = false

    for _, slot in pairs(slots) do
        local okItem, item = pcall(types.Actor.getEquipment, pself, slot)
        if okItem and item ~= nil then
            if types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item) then
                changedAny = applyOverrepairToItem(item, multiplier) or changedAny
            end
        end
    end

    if changedAny then
        section:set(APPLY_UNTIL_KEY, nil)
    end
end

local function triggerWindow(data)
    if not isPerkActive() then
        return
    end

    local windowSeconds = clampWindow(type(data) == "table" and data.windowSeconds or section:get(WINDOW_SECONDS_KEY))
    section:set(APPLY_UNTIL_KEY, nowSeconds() + windowSeconds)
end

local function onUpdate()
    if not isPerkActive() then
        section:set(APPLY_UNTIL_KEY, nil)
        return
    end

    local applyUntil = tonumber(section:get(APPLY_UNTIL_KEY))
    if applyUntil == nil or nowSeconds() > applyUntil then
        return
    end

    applyOverrepairToEquippedItems()
end

local function registerItemUseHook()
    local itemUsage = interfaces.ItemUsage
    if type(itemUsage) ~= "table" or type(itemUsage.addHandlerForType) ~= "function" then
        return
    end

    itemUsage.addHandlerForType(types.Repair, function(_, actor)
        if actor ~= pself then
            return
        end

        pself:sendEvent(TRIGGER_EVENT, {
            windowSeconds = section:get(WINDOW_SECONDS_KEY),
        })
    end)
end

section:set(MULTIPLIER_KEY, clampMultiplier(section:get(MULTIPLIER_KEY)))
section:set(WINDOW_SECONDS_KEY, clampWindow(section:get(WINDOW_SECONDS_KEY)))
registerItemUseHook()

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        [TRIGGER_EVENT] = triggerWindow,
    },
}
