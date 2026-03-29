local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local ENABLED_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.treasure_sense.enabled"
local FORTUNES_HABIT_ENABLED_KEY = "security.fortunes_habit.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"
local FORTUNES_HABIT_TOGGLE_EVENT = "SkillPerkSystem_BasePack_FortunesHabit_Toggle"
local GOLD_RECORD_ID = "gold_001"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TREASURE_SENSE_PERK_ID = "security_treasure_sense"

local enabledSection = storage.globalSection(ENABLED_SECTION_ID)

-- Per-save state
local rewardedChests = {}

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

local function fortunesHabitEnabled()
    return enabledSection:get(FORTUNES_HABIT_ENABLED_KEY) == true
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
    return tostring(object.id or object.formId or object.recordId)
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

local function goldFromLuck(actor)
    local luckStat = resolveLuckStat(actor)
    local luck = 0

    local okModified, modified = pcall(function()
        return luckStat.modified
    end)

    if okModified and type(modified) == "number" then
        luck = math.max(0, math.floor(modified))
    end

    local luckDivisor = fortunesHabitEnabled() and 8 or 10
    local bonus = math.floor(luck / luckDivisor)
    local rollA = math.random(1, 20)
    local rollB = math.random(0, bonus)
    local amount = rollA + rollB
    if fortunesHabitEnabled() then
        amount = math.floor(amount * 1.10)
    end

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

local function handleFortunesHabitToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledSection:set(FORTUNES_HABIT_ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor == nil or actor ~= world.players[1] then
        return
    end

    if not treasureSenseEnabled() then
        return
    end

    if not types.Container.objectIsInstance(object) then
        return
    end

    if not isChestLikeContainer(object) then
        return
    end

    local key = objectKey(object)
    if rewardedChests[key] then
        return
    end

    local goldCount = goldFromLuck(actor)
    addGoldToContainer(object, goldCount)
    rewardedChests[key] = true
end

local function onSave()
    return {
        rewardedChests = rewardedChests,
    }
end

local function onLoad(savedData)
    rewardedChests = {}

    if type(savedData) == "table" and type(savedData.rewardedChests) == "table" then
        rewardedChests = savedData.rewardedChests
    end
end

local function onNewGame()
    rewardedChests = {}
    enabledSection:set(FORTUNES_HABIT_ENABLED_KEY, false)
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
        [FORTUNES_HABIT_TOGGLE_EVENT] = handleFortunesHabitToggle,
    },
}
