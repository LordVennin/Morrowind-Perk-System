local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects"
local ENABLED_KEY = "security.treasure_sense.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TREASURE_SENSE_PERK_ID = "security_treasure_sense"
local TREASURE_SECTION_ID = "SkillPerkSystem_BasePack_TreasureSense"
local GOLD_RECORD_ID = "gold_001"

local effectsSection = storage.playerSection(EFFECTS_SECTION_ID)
local treasureSection = storage.globalSection(TREASURE_SECTION_ID)

local function treasureSenseEnabled()
    if effectsSection:get(ENABLED_KEY) ~= true then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(TREASURE_SENSE_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(TREASURE_SENSE_PERK_ID) then
        return false
    end

    return true
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

    effectsSection:set(ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor ~= pself and actor ~= world.players[1] then
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
