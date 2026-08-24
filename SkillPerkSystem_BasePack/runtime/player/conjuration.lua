-- Conjuration player runtime for SkillPerkSystem_BasePack.
--
-- The tree's spells, powers, and the Sanctuary ward are dynamic records owned
-- by the global script; this side reports the desired grant tiers whenever
-- perk state or bound equipment changes (dirty-key, on the 0.5s poll) and
-- keeps the Spectral Edge weapon-skill modifier applied locally. Grand
-- Conjurer's magicka refund rides the SkillProgression use handler, so it is
-- event-driven and adds no polling of its own.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local C = {
    ANCESTRAL_PACT = "conjuration_ancestral_pact",
    DAEDRIC_PACT = "conjuration_daedric_pact",
    DEEPENED_PACT = "conjuration_deepened_pact",
    GREATER_PACT = "conjuration_greater_pact",
    SPECTRAL_EDGE = "conjuration_spectral_edge",
    SPECTRAL_WARD = "conjuration_spectral_ward",
    VOICE_OF_DOMINION = "conjuration_voice_of_dominion",
    REBUKE_THE_DEAD = "conjuration_rebuke_the_dead",
    GRAND_CONJURER = "conjuration_grand_conjurer",

    POLL_INTERVAL = 0.5,
    GRANTS_EVENT = "SkillPerkSystem_BasePack_Conjuration_SetGrants",

    SPECTRAL_EDGE_SKILL_BONUS = 15,
    -- Fraction of maximum magicka restored per Conjuration cast.
    GRAND_CONJURER_RESTORE_FRACTION = 0.10,
}

-- Vanilla bound weapon record ids map onto weapon skills by name.
local BOUND_WEAPON_SKILLS = {
    dagger = "shortblade",
    longsword = "longblade",
    mace = "bluntweapon",
    battle_axe = "axe",
    spear = "spear",
    longbow = "marksman",
}

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastGrantsKey = nil,
    appliedSkillId = nil,
    appliedSkillBonus = 0,
}

local function isBoundRecordId(recordId)
    return type(recordId) == "string" and recordId:sub(1, 6) == "bound_"
end

local function boundWeaponSkill()
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end
    local ok, weapon = pcall(Actor.getEquipment, pself, slots.CarriedRight)
    if not ok or weapon == nil or not isBoundRecordId(weapon.recordId) then
        return nil
    end
    if Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(weapon) then
        return nil
    end
    for fragment, skillId in pairs(BOUND_WEAPON_SKILLS) do
        if weapon.recordId:find(fragment, 7, true) ~= nil then
            return skillId
        end
    end
    return nil
end

local function wearingBoundArmor()
    if Actor == nil or type(Actor.getEquipment) ~= "function"
            or Armor == nil or type(Armor.objectIsInstance) ~= "function" then
        return false
    end
    local ok, equipment = pcall(Actor.getEquipment, pself)
    if not ok or type(equipment) ~= "table" then
        return false
    end
    for _, item in pairs(equipment) do
        if item ~= nil and isBoundRecordId(item.recordId) and Armor.objectIsInstance(item) then
            return true
        end
    end
    return false
end

-- Pact tier per branch: the upgrade perks raise whichever pacts are owned.
local function pactTier(pactPerkId)
    if not enabled(pactPerkId) then
        return 0
    end
    if enabled(C.GREATER_PACT) then
        return 3
    end
    if enabled(C.DEEPENED_PACT) then
        return 2
    end
    return 1
end

local function publishGrants()
    local undeadTier = pactTier(C.ANCESTRAL_PACT)
    local daedraTier = pactTier(C.DAEDRIC_PACT)
    local dominionTier = 0
    if enabled(C.VOICE_OF_DOMINION) then
        dominionTier = enabled(C.REBUKE_THE_DEAD) and 2 or 1
    end
    local rebukeTier = enabled(C.REBUKE_THE_DEAD) and 1 or 0
    local wardTier = (enabled(C.SPECTRAL_WARD) and wearingBoundArmor()) and 1 or 0

    local grantsKey = table.concat({ undeadTier, daedraTier, dominionTier, rebukeTier, wardTier }, ":")
    if grantsKey == state.lastGrantsKey then
        return
    end
    state.lastGrantsKey = grantsKey
    core.sendGlobalEvent(C.GRANTS_EVENT, {
        player = pself,
        undeadTier = undeadTier,
        daedraTier = daedraTier,
        dominionTier = dominionTier,
        rebukeTier = rebukeTier,
        wardTier = wardTier,
    })
end

local function refresh()
    publishGrants()

    local skillId = enabled(C.SPECTRAL_EDGE) and boundWeaponSkill() or nil

    -- The bonus can move between skills when the player swaps bound weapons,
    -- so fully revert the old skill before applying to the new one.
    if state.appliedSkillId ~= nil and state.appliedSkillId ~= skillId then
        state.appliedSkillBonus = setModifier(stats.skillStat(state.appliedSkillId), state.appliedSkillBonus, 0)
        state.appliedSkillId = nil
    end
    if skillId ~= nil then
        state.appliedSkillId = skillId
        state.appliedSkillBonus = setModifier(stats.skillStat(skillId), state.appliedSkillBonus, C.SPECTRAL_EDGE_SKILL_BONUS)
    end
end

local function restoreMagicka()
    local magicka = stats.dynamicStat("magicka")
    if magicka == nil then
        return
    end
    local maximum = math.max(0, (tonumber(magicka.base) or 0) + (tonumber(magicka.modifier) or 0))
    if maximum <= 0 then
        return
    end
    local current = tonumber(magicka.current) or 0
    pcall(function()
        magicka.current = math.min(maximum, current + maximum * C.GRAND_CONJURER_RESTORE_FRACTION)
    end)
end

local function onConjurationSkillUsed()
    if enabled(C.GRAND_CONJURER) then
        restoreMagicka()
    end
end

do
    local progression = interfaces.SkillProgression
    if progression ~= nil and type(progression.addSkillUseHandler) == "function" then
        progression.addSkillUseHandler("conjuration", onConjurationSkillUsed)
    end
end

__basepack_subsystem_result = {
    engineHandlers = {
        shouldUpdate = function(dt)
            state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
            return state.pollTimer >= C.POLL_INTERVAL
        end,
        onUpdate = function()
            state.pollTimer = 0
            refresh()
        end,
        onLoad = function(data)
            data = type(data) == "table" and data or {}
            state.pollTimer = C.POLL_INTERVAL
            state.lastGrantsKey = nil
            state.appliedSkillId = type(data.conjurationAppliedSkillId) == "string"
                and data.conjurationAppliedSkillId or nil
            state.appliedSkillBonus = math.max(0, math.floor(tonumber(data.conjurationAppliedSkillBonus) or 0))
            refresh()
        end,
        onSave = function()
            return {
                conjurationAppliedSkillId = state.appliedSkillId,
                conjurationAppliedSkillBonus = state.appliedSkillBonus,
            }
        end,
    },
}

return __basepack_subsystem_result
