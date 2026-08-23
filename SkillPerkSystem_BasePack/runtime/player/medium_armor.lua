-- Medium Armor player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_shared_state = require("scripts.SkillPerkSystem_BasePack.runtime.shared")
local __basepack_shared = __basepack_shared_state.shared
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local NPC = types.NPC
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local C = {
    BALANCED_FIT = "mediumarmor_balanced_fit",
    LAYERED_PADDING = "mediumarmor_layered_padding",
    STEADY_GUARD = "mediumarmor_steady_guard",
    ARMORED_POISE = "mediumarmor_tempered_stride",
    BATTLE_READY = "mediumarmor_battle_ready",
    ARMORED_POISE_ABILITY = "sps_armoredpoise",
    BALANCED_FIT_BONUS = 5,
    LAYERED_PADDING_ARMOR_PER_PIECE = 1,
    STEADY_GUARD_MAX_STACKS = 5,
    STEADY_GUARD_DURATION = 10.0,
    STEADY_GUARD_SKILL_PER_STACK = 3,
    BATTLE_READY_BONUS = 20,
    BATTLE_READY_MIN_FATIGUE = 0.70,
    UPDATE_INTERVAL = 0.5,
}
local state = {
    runtimeTime = 0,
    refreshTimer = C.UPDATE_INTERVAL,
    athletics = 0,
    speed = 0,
    steady = 0,
    battle = 0,
    ability = false,
    stacks = {},
}

local function enabled(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end
    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(perkId) then
        return false
    end
    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(perkId) then
        return false
    end
    return true
end

local function getEquipped(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end
    local ok, equipped = pcall(Actor.getEquipment, pself, slot)
    return ok and equipped or nil
end

local function armorRecord(item)
    if item == nil or Armor == nil or type(Armor.record) ~= "function" then
        return nil
    end
    local ok, record = pcall(Armor.record, item)
    return ok and record or nil
end

local function recordText(record)
    local parts = {}
    if type(record.id) == "string" then parts[#parts + 1] = record.id end
    if type(record.name) == "string" then parts[#parts + 1] = record.name end
    if type(record.icon) == "string" then parts[#parts + 1] = record.icon end
    if type(record.model) == "string" then parts[#parts + 1] = record.model end
    return string.lower(table.concat(parts, " "))
end

local function isMedium(record)
    if record == nil then
        return false
    end
    local armorSkill = string.lower(tostring(record.skill or record.armorSkill or record.skillId or ""))
    if armorSkill == "mediumarmor" or armorSkill == "medium armor" or armorSkill == "medium" then
        return true
    elseif armorSkill == "lightarmor" or armorSkill == "light armor" or armorSkill == "heavyarmor" or armorSkill == "heavy armor" then
        return false
    end
    local text = recordText(record)
    for _, hint in ipairs({ "adamantium", "bonemold", "chain", "ice armor", "imperial chain", "orcish", "royal guard", "scale", "snow bear", "snow wolf" }) do
        if text:find(hint, 1, true) ~= nil then
            return true
        end
    end
    for _, hint in ipairs({ "chitin", "daedric", "dreugh", "dwemer", "ebony", "glass", "her hand", "imperial steel", "iron", "leather", "netch", "nordic fur", "nordic mail", "steel", "wolv" }) do
        if text:find(hint, 1, true) ~= nil then
            return false
        end
    end
    local weight = tonumber(record.weight) or 0
    return weight > 10 and weight <= 30
end

local function isEquippedMedium(slot, armorType)
    local equipped = getEquipped(slot)
    if equipped == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return false
    end
    local record = armorRecord(equipped)
    return record ~= nil and Armor.TYPE ~= nil and record.type == armorType and isMedium(record)
end

local function hasCuirass()
    return Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil and Armor ~= nil and Armor.TYPE ~= nil
        and isEquippedMedium(Actor.EQUIPMENT_SLOT.Cuirass, Armor.TYPE.Cuirass)
end

local function hasGreaves()
    return Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil and Armor ~= nil and Armor.TYPE ~= nil
        and isEquippedMedium(Actor.EQUIPMENT_SLOT.Greaves, Armor.TYPE.Greaves)
end

local function mediumPieceCount()
    if Actor == nil or type(Actor.getEquipment) ~= "function" or Armor == nil or type(Armor.objectIsInstance) ~= "function" then
        return 0
    end
    local ok, equipment = pcall(Actor.getEquipment, pself)
    if not ok or type(equipment) ~= "table" then
        return 0
    end
    local count = 0
    for _, equipped in pairs(equipment) do
        if equipped ~= nil and Armor.objectIsInstance(equipped) and isMedium(armorRecord(equipped)) then
            count = count + 1
        end
    end
    return count
end

__basepack_shared.getMediumArmorArmorBonus = function()
    if not enabled(C.LAYERED_PADDING) then
        return 0
    end
    return mediumPieceCount() * C.LAYERED_PADDING_ARMOR_PER_PIECE
end

local function skillStat(skillId)
    local skills = NPC ~= nil and NPC.stats ~= nil and NPC.stats.skills ~= nil and NPC.stats.skills or nil
    local accessor = skills ~= nil and (skills[skillId] or (skillId == "mediumarmor" and skills.mediumArmor)) or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

local function attributeStat(attributeId)
    local accessor = Actor ~= nil and Actor.stats ~= nil and Actor.stats.attributes ~= nil and Actor.stats.attributes[attributeId]
    return type(accessor) == "function" and accessor(pself) or nil
end

local function setModifier(stat, current, desired)
    desired = math.max(0, math.floor(tonumber(desired) or 0))
    current = math.max(0, math.floor(tonumber(current) or 0))
    if desired == current then
        return current
    end
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end
    stat.modifier = stat.modifier - current + desired
    return desired
end

local function fatiguePercent()
    local accessor = Actor ~= nil and Actor.stats ~= nil and Actor.stats.dynamic ~= nil and Actor.stats.dynamic.fatigue
    if type(accessor) ~= "function" then
        return 0
    end
    local fatigue = accessor(pself)
    if fatigue == nil then
        return 0
    end
    local maxFatigue = math.max(0, (tonumber(fatigue.base) or 0) + (tonumber(fatigue.modifier) or 0))
    return maxFatigue > 0 and ((tonumber(fatigue.current) or 0) / maxFatigue) or 0
end

local function spellRecord(id)
    local ok, records = pcall(function() return core.magic.spells.records end)
    return ok and type(records) == "table" and records[id] or nil
end

local function hasSpell(spells, id)
    if spells == nil then
        return false
    end
    if type(spells.has) == "function" then
        local okById, byId = pcall(function() return spells:has(id) end)
        if okById and byId == true then return true end
        local record = spellRecord(id)
        if record ~= nil then
            local okByRecord, byRecord = pcall(function() return spells:has(record) end)
            if okByRecord and byRecord == true then return true end
        end
    end
    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == id then
            return true
        end
    end
    return false
end

local function setAbility(id, shouldHave)
    if Actor == nil or type(Actor.spells) ~= "function" then
        return state.ability
    end
    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells or spells == nil then
        return state.ability
    end
    local already = hasSpell(spells, id)
    if shouldHave and not already and type(spells.add) == "function" then
        local ok = pcall(function() spells:add(id) end)
        if not ok then
            local record = spellRecord(id)
            if record ~= nil then ok = pcall(function() spells:add(record) end) end
        end
        return ok or state.ability
    elseif not shouldHave and (already or state.ability) and type(spells.remove) == "function" then
        local ok = pcall(function() spells:remove(id) end)
        if not ok then
            local record = spellRecord(id)
            if record ~= nil then ok = pcall(function() spells:remove(record) end) end
        end
        return not ok and state.ability or false
    end
    return shouldHave and already
end

local function pruneStacks()
    local kept = {}
    for _, expiresAt in ipairs(state.stacks) do
        if expiresAt > state.runtimeTime then kept[#kept + 1] = expiresAt end
    end
    state.stacks = kept
end

local function refresh()
    local hasBoth = hasCuirass() and hasGreaves()
    local balanced = enabled(C.BALANCED_FIT) and hasBoth and C.BALANCED_FIT_BONUS or 0
    state.athletics = setModifier(skillStat("athletics"), state.athletics, balanced)
    state.speed = setModifier(attributeStat("speed"), state.speed, balanced)
    if not enabled(C.STEADY_GUARD) then state.stacks = {} end
    pruneStacks()
    state.steady = setModifier(skillStat("mediumarmor"), state.steady, #state.stacks * C.STEADY_GUARD_SKILL_PER_STACK)
    state.battle = setModifier(skillStat("mediumarmor"), state.battle,
        enabled(C.BATTLE_READY) and hasBoth and fatiguePercent() > C.BATTLE_READY_MIN_FATIGUE and C.BATTLE_READY_BONUS or 0)
    state.ability = setAbility(C.ARMORED_POISE_ABILITY, enabled(C.ARMORED_POISE) and hasCuirass())
end

local function onHit(attack)
    if type(attack) ~= "table" or attack.attacker == nil or attack.successful == false or not enabled(C.STEADY_GUARD) then
        return
    end
    local damage = type(attack.damage) == "table" and attack.damage or {}
    if ((tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)) <= 0 then
        return
    end
    pruneStacks()
    local expiresAt = state.runtimeTime + C.STEADY_GUARD_DURATION
    for i = 1, #state.stacks do state.stacks[i] = expiresAt end
    if #state.stacks < C.STEADY_GUARD_MAX_STACKS then state.stacks[#state.stacks + 1] = expiresAt end
    refresh()
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function(dt)
            state.runtimeTime = state.runtimeTime + (tonumber(dt) or 0)
            state.refreshTimer = state.refreshTimer + (tonumber(dt) or 0)
            if #state.stacks > 0 or state.refreshTimer >= C.UPDATE_INTERVAL then
                state.refreshTimer = 0
                refresh()
            end
        end,
        shouldUpdate = function(dt)
            if #state.stacks > 0 or state.athletics ~= 0 or state.speed ~= 0 or state.steady ~= 0 or state.battle ~= 0 or state.ability then
                return true
            end
            state.refreshTimer = state.refreshTimer + (tonumber(dt) or 0)
            if state.refreshTimer < C.UPDATE_INTERVAL then
                return false
            end
            return enabled(C.BALANCED_FIT) or enabled(C.STEADY_GUARD) or enabled(C.ARMORED_POISE) or enabled(C.BATTLE_READY)
        end,
        onLoad = function(data)
            state.runtimeTime = 0
            state.refreshTimer = C.UPDATE_INTERVAL
            state.athletics = math.max(0, math.floor(tonumber(type(data) == "table" and data.mediumarmorBalancedFitAthletics) or 0))
            state.speed = math.max(0, math.floor(tonumber(type(data) == "table" and data.mediumarmorBalancedFitSpeed) or 0))
            state.steady = math.max(0, math.floor(tonumber(type(data) == "table" and data.mediumarmorSteadyGuardSkill) or 0))
            state.battle = math.max(0, math.floor(tonumber(type(data) == "table" and data.mediumarmorBattleReadySkill) or 0))
            state.ability = type(data) == "table" and data.mediumarmorArmoredPoiseApplied == true
            state.stacks = {}
            local savedStacks = type(data) == "table" and data.mediumarmorSteadyGuardStacks or nil
            if type(savedStacks) == "table" then
                for _, remaining in ipairs(savedStacks) do
                    local duration = tonumber(remaining) or 0
                    if duration > 0 then
                        state.stacks[#state.stacks + 1] = math.min(duration, C.STEADY_GUARD_DURATION)
                        if #state.stacks >= C.STEADY_GUARD_MAX_STACKS then break end
                    end
                end
            end
            refresh()
        end,
        onSave = function()
            refresh()
            local savedStacks = {}
            for _, expiresAt in ipairs(state.stacks) do
                local remaining = math.max(0, (tonumber(expiresAt) or 0) - state.runtimeTime)
                if remaining > 0 then savedStacks[#savedStacks + 1] = math.min(remaining, C.STEADY_GUARD_DURATION) end
            end
            return {
                mediumarmorBalancedFitAthletics = state.athletics,
                mediumarmorBalancedFitSpeed = state.speed,
                mediumarmorSteadyGuardSkill = state.steady,
                mediumarmorSteadyGuardStacks = savedStacks,
                mediumarmorArmoredPoiseApplied = state.ability,
                mediumarmorBattleReadySkill = state.battle,
            }
        end,
    },
}


return __basepack_subsystem_result
