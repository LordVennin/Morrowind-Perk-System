local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"

-- This record is expected to be provided by a content file.
-- It should mirror gold_001 visuals and use weight 0.01.
local LUCKY_COIN_RECORD_ID = "sps_lucky_coin"

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LUCKY_FIND_PERK_ID = "security_lucky_find"
local FIND_CHANCE = 0.02

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

-- Per-save state.
local checkedContainers = {}
local appliedLuckBonus = 0

local function perkInterfaceSaysEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local hasPerk = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(LUCKY_FIND_PERK_ID)
    if not hasPerk then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(LUCKY_FIND_PERK_ID)
    end

    return true
end

local function luckyFindEnabled()
    if effectsSection:get(ENABLED_KEY) == true then
        return true
    end

    return perkInterfaceSaysEnabled()
end

local function objectKey(object)
    return tostring(object.id or object.formId or object.recordId)
end

local function addLuckyCoinsToContainer(container, amount)
    if amount <= 0 then
        return false
    end

    local ok, coin = pcall(world.createObject, LUCKY_COIN_RECORD_ID, amount)
    if not ok or coin == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][LuckyFind] failed to create lucky coin record '%s'",
            tostring(LUCKY_COIN_RECORD_ID)
        ))
        return false
    end

    coin:moveInto(types.Container.inventory(container))
    return true
end

local function clampNonNegativeInteger(value)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then
        return 0
    end
    return n
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

    local okCount, count = pcall(inventory.countOf, inventory, LUCKY_COIN_RECORD_ID)
    if not okCount then
        return 0
    end

    return clampNonNegativeInteger(count)
end

local function applyLuckBonus(actor, targetBonus)
    local accessor = types.NPC.stats.attributes.luck
    if type(accessor) ~= "function" then
        return
    end

    local desired = clampNonNegativeInteger(targetBonus)
    local currentApplied = clampNonNegativeInteger(appliedLuckBonus)
    if currentApplied == desired then
        return
    end

    local stat = accessor(actor)
    if stat == nil or type(stat.base) ~= "number" then
        return
    end

    local newBase = math.max(0, math.floor(stat.base - currentApplied + desired))
    stat.base = newBase
    appliedLuckBonus = desired
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

    -- Only one Lucky Find check should happen per container.
    checkedContainers[key] = true

    if math.random() <= FIND_CHANCE then
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
