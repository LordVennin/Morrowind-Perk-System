local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local ENABLED_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.treasure_sense.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"
local TREASURE_SECTION_ID = "SkillPerkSystem_BasePack_TreasureSense"
local GOLD_RECORD_ID = "gold_001"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local DEBUG_LOGS = true
local TREASURE_SENSE_PERK_ID = "security_treasure_sense"

local enabledSection = storage.globalSection(ENABLED_SECTION_ID)
local treasureSection = storage.globalSection(TREASURE_SECTION_ID)

local function perkInterfaceSaysEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local hasPerk = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(TREASURE_SENSE_PERK_ID)
    if not hasPerk then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(TREASURE_SENSE_PERK_ID)
    end

    return true
end

local function treasureSenseEnabled()
    if enabledSection:get(ENABLED_KEY) == true then
        return true
    end

    return perkInterfaceSaysEnabled()
end

local function stringHasChest(value)
    if type(value) ~= "string" then
        return false
    end
    return string.find(string.lower(value), "chest", 1, true) ~= nil
end

local function isChestLikeContainer(container)
    if not types.Container.objectIsInstance(container) then
        return false
    end

    local record = types.Container.record(container)
    if record ~= nil and stringHasChest(record.name) then
        return true
    end

    return stringHasChest(container.recordId)
end

local function objectKey(object)
    return tostring(object.formId or object.id or object.recordId)
end

local function resolveLuckStat(actor)
    if actor == nil or actor.type == nil or actor.type.stats == nil then
        return nil
    end

    local attrs = actor.type.stats.attributes
    if type(attrs) == "table" and type(attrs.luck) == "function" then
        local ok, stat = pcall(attrs.luck, actor)
        if ok then
            return stat
        end
    end

    return nil
end

local function goldFromLuck(actor)
    local luckStat = resolveLuckStat(actor)
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

local function debugLog(message)
    if not DEBUG_LOGS then
        return
    end
    print("[SkillPerkSystem_BasePack][TreasureSense] " .. tostring(message))
end

local function onActivate(object, actor)
    debugLog("onActivate fired")

    if actor == nil or actor ~= world.players[1] then
        debugLog("actor check failed")
        return
    end

    if not treasureSenseEnabled() then
        debugLog("perk not enabled")
        return
    end

    if not types.Container.objectIsInstance(object) then
        debugLog("activated object is not a container")
        return
    end

    local record = types.Container.record(object)
    local recordName = record and record.name or "nil"
    debugLog(string.format("container name=%s recordId=%s", tostring(recordName), tostring(object.recordId)))

    if not isChestLikeContainer(object) then
        debugLog("container is not chest-like")
        return
    end

    local key = objectKey(object)
    if treasureSection:get(key) then
        debugLog("already rewarded key=" .. tostring(key))
        return
    end

    local goldCount = goldFromLuck(actor)
    addGoldToContainer(object, goldCount)
    treasureSection:set(key, true)

    debugLog(string.format("added %d gold key=%s", goldCount, tostring(key)))
end

return {
    engineHandlers = {
        onActivate = onActivate,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
