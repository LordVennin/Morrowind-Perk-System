local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LONG_BLADE_FUNDAMENTALS_PERK_ID = "longblade_fundamentals"
local FATIGUE_THRESHOLD = 0.8
local LONG_BLADE_BONUS = 5
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_LongBlade"
local APPLIED_BONUS_KEY = "fundamentals.applied_bonus"

local storageSection = storage.playerSection(STORAGE_SECTION_ID)
local appliedLongBladeBonus = tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0

local function longBladeFundamentalsEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(LONG_BLADE_FUNDAMENTALS_PERK_ID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(LONG_BLADE_FUNDAMENTALS_PERK_ID)
    end

    return true
end

local function getFatiguePercent()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return 0
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return 0
    end

    return current / maxFatigue
end

local function resolveLongBladeStat()
    local accessor = types.NPC ~= nil
        and types.NPC.stats ~= nil
        and types.NPC.stats.skills ~= nil
        and types.NPC.stats.skills.longblade
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyLongBladeBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedLongBladeBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveLongBladeStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedLongBladeBonus = desired
    storageSection:set(APPLIED_BONUS_KEY, desired)
end

local function refreshLongBladeFundamentals()
    local desiredBonus = 0
    if longBladeFundamentalsEnabled() and getFatiguePercent() > FATIGUE_THRESHOLD then
        desiredBonus = LONG_BLADE_BONUS
    end

    applyLongBladeBonus(desiredBonus)
end

local function onLoad()
    appliedLongBladeBonus = math.max(0, math.floor(tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0))
    refreshLongBladeFundamentals()
end

return {
    engineHandlers = {
        onUpdate = refreshLongBladeFundamentals,
        onLoad = onLoad,
    },
}
