-- Heavy Armor player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_shared_state = require("scripts.SkillPerkSystem_BasePack.runtime.shared")
local __basepack_shared = __basepack_shared_state.shared
local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
local registerBasepackAnimationHandler = __basepack_animation.registerHandler
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local AI = interfaces.AI
local NPC = types.NPC
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local C = {
    HEAVY_SKIN = "heavyarmor_locked_frame",
    IRON_TREAD = "heavyarmor_iron_tread",
    SHOCK_PADDING = "heavyarmor_shock_padding",
    ANVIL_STANCE = "heavyarmor_anvil_stance",
    DREADNOUGHT = "heavyarmor_dreadnought",
    JUGGERNAUT = "heavyarmor_juggernaut_charge",
    UPDATE_INTERVAL = 0.5,
    SHOCK_DURATION = 3.0,
    SHOCK_SKILL = 5,
    DREADNOUGHT_SKILL = 10,
    DREADNOUGHT_FATIGUE = 20,
    ANVIL_DURATION = 10.0,
    ANVIL_MAX_STACKS = 5,
    ANVIL_PER_STACK = 3,
    JUGGERNAUT_STRENGTH = 10,
    JUGGERNAUT_FATIGUE_PER_SECOND = 2,
    COMBAT_ACTIVITY_DURATION = 5.0,
}
local state = {
    runtimeTime = 0,
    refreshTimer = C.UPDATE_INTERVAL,
    ironTreadNextCheck = 0,
    ironFeather = 0,
    ironSpeed = 0,
    shockSkill = 0,
    shockRemaining = 0,
    shockFatigueRemaining = 0,
    recentCombatSignalUntil = 0,
    anvilStacks = {},
    anvilEndurance = 0,
    anvilSkill = 0,
    juggernautStrength = 0,
}

local function enabled(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then return false end
    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(perkId) then return false end
    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(perkId) then return false end
    return true
end

local function getEquipped(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" then return nil end
    local ok, equipped = pcall(Actor.getEquipment, pself, slot)
    return ok and equipped or nil
end

local function armorRecord(item)
    if item == nil or Armor == nil or type(Armor.record) ~= "function" then return nil end
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

local function isHeavy(record)
    if record == nil then return false end
    local armorSkill = string.lower(tostring(record.skill or record.armorSkill or record.skillId or ""))
    if armorSkill == "heavyarmor" or armorSkill == "heavy armor" or armorSkill == "heavy" then return true end
    if armorSkill == "lightarmor" or armorSkill == "light armor" or armorSkill == "mediumarmor" or armorSkill == "medium armor" then return false end
    local text = recordText(record)
    for _, hint in ipairs({ "daedric", "dwemer", "ebony", "her hand", "imperial steel", "iron", "nordic mail", "steel" }) do
        if text:find(hint, 1, true) ~= nil then return true end
    end
    for _, hint in ipairs({ "adamantium", "bonemold", "chain", "chitin", "dreugh", "glass", "ice armor", "imperial chain", "leather", "netch", "orcish", "royal guard", "scale", "snow bear", "snow wolf", "wolv" }) do
        if text:find(hint, 1, true) ~= nil then return false end
    end
    return (tonumber(record.weight) or 0) > 30
end

local function isEquippedHeavy(slot, armorType)
    local equipped = getEquipped(slot)
    if equipped == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then return false, nil end
    local record = armorRecord(equipped)
    return record ~= nil and Armor.TYPE ~= nil and record.type == armorType and isHeavy(record), record
end

local function hasHeavyCuirass()
    return Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil and Armor ~= nil and Armor.TYPE ~= nil
        and isEquippedHeavy(Actor.EQUIPMENT_SLOT.Cuirass, Armor.TYPE.Cuirass)
end

local function isBeastRaceWithoutBoots()
    local raceId = ""
    if NPC ~= nil and type(NPC.record) == "function" then
        local ok, record = pcall(NPC.record, pself)
        if ok and record ~= nil then raceId = string.lower(tostring(record.race or record.raceId or record.raceID or "")) end
    end
    if raceId == "" and type(pself.record) == "table" then
        raceId = string.lower(tostring(pself.record.race or pself.record.raceId or pself.record.raceID or ""))
    end
    return raceId:find("argonian", 1, true) ~= nil or raceId:find("khajiit", 1, true) ~= nil
end

local function skillStat(skillId)
    local skills = NPC ~= nil and NPC.stats ~= nil and NPC.stats.skills ~= nil and NPC.stats.skills or nil
    local accessor = skills ~= nil and (skills[skillId] or (skillId == "heavyarmor" and skills.heavyArmor)) or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

local function attributeStat(attributeId)
    local accessor = Actor ~= nil and Actor.stats ~= nil and Actor.stats.attributes ~= nil and Actor.stats.attributes[attributeId]
    return type(accessor) == "function" and accessor(pself) or nil
end

local function setModifier(stat, current, desired)
    desired = math.max(0, math.floor(tonumber(desired) or 0))
    current = math.max(0, math.floor(tonumber(current) or 0))
    if desired == current then return current end
    if stat == nil or type(stat.modifier) ~= "number" then return current end
    stat.modifier = stat.modifier - current + desired
    return desired
end

local function modifyFeather(delta)
    if Actor == nil or type(Actor.activeEffects) ~= "function" then return false end
    local effectType = core.magic and core.magic.EFFECT_TYPE and core.magic.EFFECT_TYPE.Feather
    if effectType == nil then return false end
    local ok, effects = pcall(Actor.activeEffects, pself)
    if not ok or effects == nil or type(effects.modify) ~= "function" then return false end
    return pcall(effects.modify, effects, delta, effectType)
end

local function restoreFatigue(amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    local accessor = Actor ~= nil and Actor.stats ~= nil and Actor.stats.dynamic ~= nil and Actor.stats.dynamic.fatigue
    if type(accessor) ~= "function" then return end
    local fatigue = accessor(pself)
    if fatigue == nil or type(fatigue.current) ~= "number" then return end
    local maxFatigue = math.max(0, (tonumber(fatigue.base) or 0) + (tonumber(fatigue.modifier) or 0))
    fatigue.current = math.min(maxFatigue, fatigue.current + amount)
end

local function simulationTime()
    if type(core.getSimulationTime) == "function" then
        local ok, value = pcall(core.getSimulationTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    return state.runtimeTime
end

local function requestIronTreadRefresh()
    state.ironTreadNextCheck = 0
end

local function markCombatActivity()
    state.recentCombatSignalUntil = math.max(
        state.recentCombatSignalUntil,
        state.runtimeTime + C.COMBAT_ACTIVITY_DURATION
    )
    -- Ensure the next dispatcher pass applies Juggernaut immediately instead of
    -- waiting for the normal half-second equipment refresh.
    state.refreshTimer = C.UPDATE_INTERVAL
end

local function inCombat()
    -- Player scripts do not have useful AI Combat packages to query. Track
    -- recent player combat activity instead: attacks, spell casts, and hits
    -- refresh this window.
    return state.recentCombatSignalUntil > state.runtimeTime
end

local function disableLegacyHeavyArmorTargetWatcher()
    -- Heavy Armor perks are now entirely player-side. Sending an inactive state
    -- lets the global watcher disable and remove actor-target scripts left over
    -- in existing saves.
    core.sendGlobalEvent("SkillPerkSystem_HeavyArmorState", {
        playerId = pself.id,
        shockPaddingEnabled = false,
        juggernautEnabled = false,
    })
end

__basepack_shared.getHeavyArmorArmorBonus = function()
    if not enabled(C.HEAVY_SKIN) or not hasHeavyCuirass() then return 0 end
    local stat = skillStat("heavyarmor")
    local value = stat ~= nil and (tonumber(stat.current) or tonumber(stat.base) or 0) or 0
    return math.floor(value / 10) * 2
end

local function clearShock()
    state.shockRemaining = 0
    state.shockFatigueRemaining = 0
    state.shockSkill = setModifier(skillStat("heavyarmor"), state.shockSkill, 0)
end

local function triggerShockPadding()
    if not enabled(C.SHOCK_PADDING) or not hasHeavyCuirass() then return end
    state.shockRemaining = C.SHOCK_DURATION
    state.shockFatigueRemaining = enabled(C.DREADNOUGHT) and C.DREADNOUGHT_FATIGUE or 0
    state.shockSkill = setModifier(skillStat("heavyarmor"), state.shockSkill, enabled(C.DREADNOUGHT) and C.DREADNOUGHT_SKILL or C.SHOCK_SKILL)
end

local function handleHeavyArmorAnimation(event)
    if type(event) ~= "table" or event.isWeaponAttackWindup ~= true then
        return
    end
    markCombatActivity()
    triggerShockPadding()
end
registerBasepackAnimationHandler(handleHeavyArmorAnimation)

local function pruneAnvil()
    local kept = {}
    for _, expiresAt in ipairs(state.anvilStacks) do if expiresAt > state.runtimeTime then kept[#kept + 1] = expiresAt end end
    state.anvilStacks = kept
end

local function refreshStaticBonuses()
    local beast = isBeastRaceWithoutBoots()
    local desiredFeather = 0
    local desiredSpeed = 0
    if enabled(C.IRON_TREAD) and Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil and Armor ~= nil and Armor.TYPE ~= nil then
        if beast then
            local okGreaves = isEquippedHeavy(Actor.EQUIPMENT_SLOT.Greaves, Armor.TYPE.Greaves)
            desiredSpeed = okGreaves and 10 or 0
        else
            local okBoots, bootRecord = isEquippedHeavy(Actor.EQUIPMENT_SLOT.Boots, Armor.TYPE.Boots)
            desiredFeather = okBoots and math.max(0, (tonumber(bootRecord.weight) or 0) * 0.5) or 0
        end
    end
    if desiredFeather ~= state.ironFeather and modifyFeather(desiredFeather - state.ironFeather) then state.ironFeather = desiredFeather end
    state.ironSpeed = setModifier(attributeStat("speed"), state.ironSpeed, desiredSpeed)

    if not hasHeavyCuirass() or not enabled(C.SHOCK_PADDING) or state.shockRemaining <= 0 then clearShock() end
    if not hasHeavyCuirass() or not enabled(C.ANVIL_STANCE) then state.anvilStacks = {} end
    pruneAnvil()
    local anvilBonus = #state.anvilStacks * C.ANVIL_PER_STACK
    state.anvilEndurance = setModifier(attributeStat("endurance"), state.anvilEndurance, anvilBonus)
    state.anvilSkill = setModifier(skillStat("heavyarmor"), state.anvilSkill, anvilBonus)

    local juggernaut = enabled(C.JUGGERNAUT) and hasHeavyCuirass() and inCombat()
    state.juggernautStrength = setModifier(attributeStat("strength"), state.juggernautStrength, juggernaut and C.JUGGERNAUT_STRENGTH or 0)

    -- Iron Tread only needs equipment polling. Schedule the next check using
    -- simulation time so a persistent Feather/Speed modifier does not keep this
    -- entire subsystem active every frame.
    state.ironTreadNextCheck = simulationTime() + C.UPDATE_INTERVAL
end

local function onHit(attack)
    if type(attack) ~= "table" or attack.successful == false then return end
    local damage = type(attack.damage) == "table" and attack.damage or {}
    local damaged = ((tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)) > 0
    if attack.attacker == pself then
        markCombatActivity()
        triggerShockPadding()
    elseif attack.attacker ~= nil and damaged then
        markCombatActivity()
        if enabled(C.ANVIL_STANCE) and hasHeavyCuirass() then
            pruneAnvil()
            local expiresAt = state.runtimeTime + C.ANVIL_DURATION
            for i = 1, #state.anvilStacks do state.anvilStacks[i] = expiresAt end
            if #state.anvilStacks < C.ANVIL_MAX_STACKS then state.anvilStacks[#state.anvilStacks + 1] = expiresAt end
            refreshStaticBonuses()
        end
    end
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then addOnHitHandler(onHit) end


__basepack_subsystem_result = {
    eventHandlers = {
        UiModeChanged = function()
            state.refreshTimer = C.UPDATE_INTERVAL
            requestIronTreadRefresh()
        end,
        SkillPerkSystem_PerkStateChanged = function()
            state.refreshTimer = C.UPDATE_INTERVAL
            requestIronTreadRefresh()
            disableLegacyHeavyArmorTargetWatcher()
        end,
        -- Compatibility handlers for saves/scripts created by the older
        -- target-watcher implementation.
        SkillPerkSystem_HeavyArmorShockPaddingTriggered = function()
            markCombatActivity()
            triggerShockPadding()
        end,
        SkillPerkSystem_HeavyArmorCombatState = function(data)
            if type(data) == "table" and data.active == true then
                markCombatActivity()
            end
        end,
        MagicCasted = function()
            markCombatActivity()
            triggerShockPadding()
        end,
        SpellCasted = function()
            markCombatActivity()
            triggerShockPadding()
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            local delta = tonumber(dt) or 0
            state.runtimeTime = state.runtimeTime + delta
            state.refreshTimer = state.refreshTimer + delta
            if state.shockRemaining > 0 then
                local before = state.shockRemaining
                state.shockRemaining = math.max(0, state.shockRemaining - delta)
                local used = math.max(0, before - state.shockRemaining)
                local restore = math.min(state.shockFatigueRemaining, C.DREADNOUGHT_FATIGUE * used / C.SHOCK_DURATION)
                state.shockFatigueRemaining = math.max(0, state.shockFatigueRemaining - restore)
                restoreFatigue(restore)
                state.shockSkill = setModifier(skillStat("heavyarmor"), state.shockSkill, enabled(C.DREADNOUGHT) and C.DREADNOUGHT_SKILL or C.SHOCK_SKILL)
            end
            if enabled(C.JUGGERNAUT) and hasHeavyCuirass() and inCombat() then restoreFatigue(C.JUGGERNAUT_FATIGUE_PER_SECOND * delta) end
            if state.refreshTimer >= C.UPDATE_INTERVAL or state.shockRemaining <= 0 or #state.anvilStacks > 0 then
                state.refreshTimer = 0
                refreshStaticBonuses()
            end
        end,
        shouldUpdate = function(dt)
            -- Timed effects still need continuous updates while active.
            if state.shockSkill ~= 0
                or state.shockRemaining > 0
                or #state.anvilStacks > 0
                or state.anvilEndurance ~= 0
                or state.anvilSkill ~= 0
                or state.juggernautStrength ~= 0
                or (enabled(C.JUGGERNAUT) and inCombat())
            then
                return true
            end

            -- Iron Tread is a persistent equipment modifier, not a timed effect.
            -- Poll equipment twice per second instead of treating the active
            -- Feather/Speed bonus as a reason to run every player update.
            if enabled(C.IRON_TREAD) or state.ironFeather ~= 0 or state.ironSpeed ~= 0 then
                return simulationTime() >= state.ironTreadNextCheck
            end

            return false
        end,
        onLoad = function(data)
            state.runtimeTime = 0
            state.refreshTimer = C.UPDATE_INTERVAL
            state.ironTreadNextCheck = 0
            state.ironFeather = math.max(0, tonumber(type(data) == "table" and data.heavyarmorIronTreadFeather) or 0)
            state.ironSpeed = math.max(0, math.floor(tonumber(type(data) == "table" and data.heavyarmorIronTreadSpeed) or 0))
            state.shockSkill = math.max(0, math.floor(tonumber(type(data) == "table" and data.heavyarmorShockPaddingSkill) or 0))
            state.shockRemaining = math.max(0, tonumber(type(data) == "table" and data.heavyarmorShockPaddingRemaining) or 0)
            state.shockFatigueRemaining = math.max(0, tonumber(type(data) == "table" and data.heavyarmorShockPaddingFatigueRemaining) or 0)
            state.anvilEndurance = math.max(0, math.floor(tonumber(type(data) == "table" and data.heavyarmorAnvilEndurance) or 0))
            state.anvilSkill = math.max(0, math.floor(tonumber(type(data) == "table" and data.heavyarmorAnvilSkill) or 0))
            state.juggernautStrength = math.max(0, math.floor(tonumber(type(data) == "table" and data.heavyarmorJuggernautStrength) or 0))
            state.recentCombatSignalUntil = 0
            state.anvilStacks = {}
            local savedStacks = type(data) == "table" and data.heavyarmorAnvilStacks or nil
            if type(savedStacks) == "table" then
                for _, remaining in ipairs(savedStacks) do
                    local duration = tonumber(remaining) or 0
                    if duration > 0 then state.anvilStacks[#state.anvilStacks + 1] = math.min(duration, C.ANVIL_DURATION) end
                    if #state.anvilStacks >= C.ANVIL_MAX_STACKS then break end
                end
            end
            for i = 1, #state.anvilStacks do state.anvilStacks[i] = state.runtimeTime + state.anvilStacks[i] end
            refreshStaticBonuses()
            disableLegacyHeavyArmorTargetWatcher()
        end,
        onSave = function()
            refreshStaticBonuses()
            local savedStacks = {}
            for _, expiresAt in ipairs(state.anvilStacks) do
                local remaining = math.max(0, expiresAt - state.runtimeTime)
                if remaining > 0 then savedStacks[#savedStacks + 1] = math.min(remaining, C.ANVIL_DURATION) end
            end
            return {
                heavyarmorIronTreadFeather = state.ironFeather,
                heavyarmorIronTreadSpeed = state.ironSpeed,
                heavyarmorShockPaddingSkill = state.shockSkill,
                heavyarmorShockPaddingRemaining = state.shockRemaining,
                heavyarmorShockPaddingFatigueRemaining = state.shockFatigueRemaining,
                heavyarmorAnvilStacks = savedStacks,
                heavyarmorAnvilEndurance = state.anvilEndurance,
                heavyarmorAnvilSkill = state.anvilSkill,
                heavyarmorJuggernautStrength = state.juggernautStrength,
            }
        end,
    },
}


return __basepack_subsystem_result
