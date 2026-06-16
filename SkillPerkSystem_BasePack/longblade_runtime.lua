local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LONG_BLADE_FUNDAMENTALS_PERK_ID = "longblade_fundamentals"
local DUELISTS_TEMPO_PERK_ID = "longblade_demo_precision"
local FATIGUE_THRESHOLD = 0.8
local LONG_BLADE_BONUS = 5
local STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_LongBlade"
local APPLIED_BONUS_KEY = "fundamentals.applied_bonus"
local DUELISTS_TEMPO_APPLIED_KEY = "duelists_tempo.applied_agility_bonus"

local DUELISTS_TEMPO_MAX_STACKS = 5
local DUELISTS_TEMPO_DURATION = 4.0
local DUELISTS_TEMPO_AGILITY_PER_STACK = 3

local storageSection = storage.playerSection(STORAGE_SECTION_ID)
local appliedLongBladeBonus = tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0
local duelistTempoStacks = 0
local duelistTempoRemaining = 0
local appliedDuelistTempoAgilityBonus = tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function longBladeFundamentalsEnabled()
    return hasEnabledPerk(LONG_BLADE_FUNDAMENTALS_PERK_ID)
end

local function duelistsTempoEnabled()
    return hasEnabledPerk(DUELISTS_TEMPO_PERK_ID)
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

local function resolveAgilityStat(actor)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes.agility
    if type(accessor) ~= "function" or actor == nil then
        return nil
    end

    return accessor(actor)
end

local function applyDuelistTempoAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedDuelistTempoAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveAgilityStat(pself)
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedDuelistTempoAgilityBonus = desired
    storageSection:set(DUELISTS_TEMPO_APPLIED_KEY, desired)
end

local function clearDuelistTempoBonus()
    duelistTempoStacks = 0
    duelistTempoRemaining = 0
    applyDuelistTempoAgilityBonus(0)
end

local function refreshLongBladeFundamentals()
    local desiredBonus = 0
    if longBladeFundamentalsEnabled() and getFatiguePercent() > FATIGUE_THRESHOLD then
        desiredBonus = LONG_BLADE_BONUS
    end

    applyLongBladeBonus(desiredBonus)
end

local function getEquippedOneHandedLongBlade()
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local slot = Actor.EQUIPMENT_SLOT.CarriedRight
    if slot == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local okEquipment, weapon = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment or weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = nil
    if type(Weapon.record) == "function" then
        local okRecord, value = pcall(Weapon.record, weapon)
        if okRecord then
            record = value
        end
    end

    if record == nil or Weapon.TYPE == nil or record.type ~= Weapon.TYPE.LongBladeOneHand then
        return nil
    end

    return weapon
end

local function isValidDuelistTempoTarget(target)
    return target ~= nil and type(target.isValid) == "function" and target:isValid()
end

local function applyDuelistTempoToTarget(target, stacks)
    if not isValidDuelistTempoTarget(target) then
        return
    end

    target:sendEvent("SkillPerkSystem_DuelistsTempoRefresh", {
        stacks = stacks,
        duration = DUELISTS_TEMPO_DURATION,
        agilityPerStack = DUELISTS_TEMPO_AGILITY_PER_STACK,
    })
end

local function tryApplyDuelistTempo(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if not isValidDuelistTempoTarget(target) then
        return
    end
    if not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
        return
    end

    duelistTempoStacks = math.min(DUELISTS_TEMPO_MAX_STACKS, duelistTempoStacks + 1)
    duelistTempoRemaining = DUELISTS_TEMPO_DURATION
    applyDuelistTempoAgilityBonus(duelistTempoStacks * DUELISTS_TEMPO_AGILITY_PER_STACK)
    applyDuelistTempoToTarget(target, duelistTempoStacks)
end

local function onLoad()
    appliedLongBladeBonus = math.max(0, math.floor(tonumber(storageSection:get(APPLIED_BONUS_KEY)) or 0))
    appliedDuelistTempoAgilityBonus = math.max(0, math.floor(tonumber(storageSection:get(DUELISTS_TEMPO_APPLIED_KEY)) or 0))
    clearDuelistTempoBonus()
    refreshLongBladeFundamentals()
end

local function onUpdate(dt)
    refreshLongBladeFundamentals()

    if duelistTempoRemaining > 0 then
        duelistTempoRemaining = math.max(0, duelistTempoRemaining - (tonumber(dt) or 0))
        if duelistTempoRemaining <= 0 or not duelistsTempoEnabled() or getEquippedOneHandedLongBlade() == nil then
            clearDuelistTempoBonus()
        end
    elseif appliedDuelistTempoAgilityBonus ~= 0 then
        clearDuelistTempoBonus()
    end
end

return {
    eventHandlers = {
        SkillPerkSystem_TryDuelistsTempo = tryApplyDuelistTempo,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = onLoad,
    },
}
