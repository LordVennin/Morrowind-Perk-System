local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local ENABLED_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.treasure_sense.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"
local TREASURE_SECTION_ID = "SkillPerkSystem_BasePack_TreasureSense"
local GOLD_RECORD_ID = "gold_001"

local enabledSection = storage.globalSection(ENABLED_SECTION_ID)
local treasureSection = storage.globalSection(TREASURE_SECTION_ID)

local function treasureSenseEnabled()
    return enabledSection:get(ENABLED_KEY) == true
end

local function isChestLikeContainer(container)
    if not types.Container.objectIsInstance(container) then
        return false
    end

    local record = types.Container.record(container)
    if record == nil or type(record.name) ~= "string" then
        return false
    end

    return string.find(string.lower(record.name), "chest", 1, true) ~= nil
end

local function objectKey(object)
    return tostring(object.formId or object.recordId or object.id)
end

local function goldFromLuck(actor)
    local luckAccessor = types.NPC.stats.attribute.luck
    if type(luckAccessor) ~= "function" then
        return math.random(1, 20)
    end

    local luckStat = luckAccessor(actor)
    local luck = 0
    if type(luckStat) == "table" and type(luckStat.modified) == "number" then
        luck = math.max(0, math.floor(luckStat.modified))
    end

    local bonus = math.floor(luck / 10)
    local amount = math.random(1, 20) + math.random(0, bonus)
    return math.max(1, math.floor(amount))
end

local function addGoldToContainer(container, amount)
    if amount <= 0 then
        return
    end

    local gold = world.createObject(GOLD_RECORD_ID, amount)
    gold:moveInto(types.Container.inventory(container))
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledSection:set(ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor == nil or actor ~= world.players[1] then
        return
    end

    if not treasureSenseEnabled() then
        return
    end

    if not isChestLikeContainer(object) then
        return
    end

    local key = objectKey(object)
    if treasureSection:get(key) then
        return
    end

    local goldCount = goldFromLuck(actor)
    addGoldToContainer(object, goldCount)
    treasureSection:set(key, true)

    local record = types.Container.record(object)
    local chestName = record and record.name or tostring(object.recordId)
    print(string.format("[SkillPerkSystem_BasePack][TreasureSense] added %d gold to %s", goldCount, chestName))
end

return {
    engineHandlers = {
        onActivate = onActivate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
