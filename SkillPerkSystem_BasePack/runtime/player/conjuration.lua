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
local nearby = require("openmw.nearby")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon

local LOG_TAG = "[SkillPerkSystem_BasePack][Conjuration][Player]"

-- Assigned further down, once onSkillUsed exists; declared here so the poll
-- can reach it.
local skillHandlerRegistered
local skillHandlerReported
local ensureSkillUsedHandler

local C = {
    ANCESTRAL_PACT = "conjuration_ancestral_pact",
    DAEDRIC_PACT = "conjuration_daedric_pact",
    DEEPENED_PACT = "conjuration_deepened_pact",
    GREATER_PACT = "conjuration_greater_pact",
    SPECTRAL_EDGE = "conjuration_spectral_edge",
    SPECTRAL_WARD = "conjuration_spectral_ward",
    SOUL_TETHER = "conjuration_soul_tether",
    SOUL_RECLAMATION = "conjuration_soul_reclamation",
    GRAND_CONJURER = "conjuration_grand_conjurer",

    POLL_INTERVAL = 0.5,
    GRANTS_EVENT = "SkillPerkSystem_BasePack_Conjuration_SetGrants",
    GRANTED_EVENT = "SkillPerkSystem_BasePack_Conjuration_Granted",

    SPECTRAL_EDGE_SKILL_BONUS = 15,
    -- Communion with a summoned servant: stay near one while your own reserves
    -- are low and it feeds power back to you.
    SOUL_RECLAMATION_THRESHOLD = 0.5,
    SOUL_RECLAMATION_PER_SECOND = 0.01,
    SOUL_RECLAMATION_RANGE = 400,
    -- Fraction of maximum magicka restored per Conjuration cast.
    GRAND_CONJURER_RESTORE_FRACTION = 0.10,
    -- In-game seconds in a day, for the once-per-day pact check.
    SECONDS_PER_DAY = 86400,
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
    -- Record ids the global side says we currently hold, per pact family, and
    -- the game day each pact was last seen actually taking effect.
    grantedPactIds = {},
    pactUsedDay = { undead = -1, daedra = -1 },
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

local function currentGameDay()
    local ok, gameTime = pcall(core.getGameTime)
    if not ok or type(gameTime) ~= "number" then
        return 0
    end
    return math.floor(gameTime / C.SECONDS_PER_DAY)
end

local function restoreMagicka(amount)
    local magicka = stats.dynamicStat("magicka")
    if magicka == nil or amount <= 0 then
        return
    end
    local maximum = math.max(0, (tonumber(magicka.base) or 0) + (tonumber(magicka.modifier) or 0))
    if maximum <= 0 then
        return
    end
    local current = tonumber(magicka.current) or 0
    pcall(function()
        magicka.current = math.min(maximum, current + amount)
    end)
end

-- The creature each summon effect spawns is named by a GMST, so the set of
-- summoned-creature record ids is exact rather than guessed from naming.
local SUMMON_CREATURE_GMSTS = {
    "sMagicAncestralGhostID", "sMagicBonelordID", "sMagicLeastBonewalkerID",
    "sMagicCenturionSphereID", "sMagicClannfearID", "sMagicDaedrothID",
    "sMagicDremoraID", "sMagicFabricantID", "sMagicFlameAtronachID",
    "sMagicFrostAtronachID", "sMagicGoldenSaintID", "sMagicGreaterBonewalkerID",
    "sMagicHungerID", "sMagicScampID", "sMagicSkeletalMinionID",
    "sMagicStormAtronachID", "sMagicWingedTwilightID", "sMagicCreature01ID",
    "sMagicCreature02ID", "sMagicCreature03ID", "sMagicCreature04ID",
    "sMagicCreature05ID",
}

local summonRecordIds = nil

local function summonedRecordIds()
    if summonRecordIds ~= nil then
        return summonRecordIds
    end
    summonRecordIds = {}
    for _, gmst in ipairs(SUMMON_CREATURE_GMSTS) do
        local ok, value = pcall(core.getGMST, gmst)
        if ok and type(value) == "string" and value ~= "" then
            summonRecordIds[value:lower()] = true
        end
    end
    return summonRecordIds
end

local function nearSummonedServant()
    local actors = nearby ~= nil and nearby.actors or nil
    if actors == nil then
        return false
    end
    local origin = stats.position()
    if origin == nil then
        return false
    end
    local ids = summonedRecordIds()
    local rangeSquared = C.SOUL_RECLAMATION_RANGE * C.SOUL_RECLAMATION_RANGE
    for _, actor in ipairs(actors) do
        local recordId = actor ~= nil and actor.recordId or nil
        if type(recordId) == "string" and ids[recordId:lower()] then
            local okDead, dead = pcall(Actor.isDead, actor)
            if not (okDead and dead == true) then
                local distanceSquared = stats.distanceSquared(actor.position, origin)
                if distanceSquared ~= nil and distanceSquared <= rangeSquared then
                    return true
                end
            end
        end
    end
    return false
end

local function applySoulReclamation(elapsed)
    if elapsed <= 0 or not enabled(C.SOUL_RECLAMATION) then
        return
    end
    local magicka = stats.dynamicStat("magicka")
    if magicka == nil then
        return
    end
    local maximum = math.max(0, (tonumber(magicka.base) or 0) + (tonumber(magicka.modifier) or 0))
    if maximum <= 0 then
        return
    end
    local current = tonumber(magicka.current) or 0
    if current >= maximum * C.SOUL_RECLAMATION_THRESHOLD then
        return
    end
    if not nearSummonedServant() then
        return
    end
    restoreMagicka(maximum * C.SOUL_RECLAMATION_PER_SECOND * elapsed)
end

-- Watches for a granted pact power taking effect. Matching the granted record
-- id rather than the summon effect means an ordinary summon spell the player
-- also knows never spends the daily pact.
local function notePactUse(day)
    local ok, active = pcall(function() return Actor.activeSpells(pself) end)
    if not ok or active == nil then
        return
    end
    for family, recordId in pairs(state.grantedPactIds) do
        if recordId ~= nil and state.pactUsedDay[family] ~= day then
            local isActive = false
            if type(active.isSpellActive) == "function" then
                local okActive, result = pcall(function() return active:isSpellActive(recordId) end)
                isActive = okActive and result == true
            end
            if not isActive then
                for _, entry in pairs(active) do
                    local id = type(entry) == "table" and entry.id or entry
                    if id == recordId then isActive = true break end
                end
            end
            if isActive then
                state.pactUsedDay[family] = day
            end
        end
    end
end

local function publishGrants()
    local day = currentGameDay()
    notePactUse(day)

    local undeadTier = pactTier(C.ANCESTRAL_PACT)
    local daedraTier = pactTier(C.DAEDRIC_PACT)
    local wardTier = (enabled(C.SPECTRAL_WARD) and wearingBoundArmor()) and 1 or 0
    local tetherTier = enabled(C.SOUL_TETHER) and 1 or 0

    local grantsKey = table.concat({
        undeadTier, daedraTier, wardTier, tetherTier, day,
        state.pactUsedDay.undead, state.pactUsedDay.daedra,
    }, ":")
    if grantsKey == state.lastGrantsKey then
        return
    end
    state.lastGrantsKey = grantsKey
    core.sendGlobalEvent(C.GRANTS_EVENT, {
        player = pself,
        undeadTier = undeadTier,
        daedraTier = daedraTier,
        wardTier = wardTier,
        tetherTier = tetherTier,
        currentDay = day,
        undeadUsedDay = state.pactUsedDay.undead,
        daedraUsedDay = state.pactUsedDay.daedra,
    })
end

local function onGranted(data)
    state.grantedPactIds = {
        undead = type(data) == "table" and data.undead or nil,
        daedra = type(data) == "table" and data.daedra or nil,
    }
end

local function refresh(elapsed)
    ensureSkillUsedHandler()
    publishGrants()
    applySoulReclamation(elapsed)


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

-- SkillProgression takes ONE handler for every skill, registered with no skill
-- argument, and calls it as handler(skillId, params). Registering per-skill
-- (addSkillUseHandler("conjuration", fn)) matches nothing and silently never
-- fires, which is why this perk did nothing.
local function onSkillUsed(skillId, params)
    if skillId ~= "conjuration" or not enabled(C.GRAND_CONJURER) then
        return
    end
    local useTypes = interfaces.SkillProgression ~= nil
        and interfaces.SkillProgression.SKILL_USE_TYPES or nil
    local castSuccess = useTypes ~= nil and useTypes.Spellcast_Success or nil
    if castSuccess ~= nil and type(params) == "table" and params.useType ~= nil
            and params.useType ~= castSuccess then
        return
    end
    local magicka = stats.dynamicStat("magicka")
    if magicka == nil then
        return
    end
    local maximum = math.max(0, (tonumber(magicka.base) or 0) + (tonumber(magicka.modifier) or 0))
    restoreMagicka(maximum * C.GRAND_CONJURER_RESTORE_FRACTION)
end

-- Registered from the poll rather than at module load. interfaces.* is
-- populated as scripts come up, and this module is required early enough that
-- SkillProgression was still absent, so a load-time registration silently did
-- nothing no matter which function name it used. Retry until it takes, and if
-- the interface appears without the expected function, say what it does have
-- so the mismatch is visible in the log instead of failing quietly.
skillHandlerRegistered = false
skillHandlerReported = false

ensureSkillUsedHandler = function()
    if skillHandlerRegistered then
        return
    end
    local progression = interfaces.SkillProgression
    if progression == nil then
        return
    end
    if type(progression.addSkillUsedHandler) == "function" then
        progression.addSkillUsedHandler(onSkillUsed)
        skillHandlerRegistered = true
        print(LOG_TAG .. " skill-used handler registered")
        return
    end
    if not skillHandlerReported then
        skillHandlerReported = true
        local names = {}
        for key, value in pairs(progression) do
            names[#names + 1] = tostring(key) .. " (" .. type(value) .. ")"
        end
        table.sort(names)
        print(LOG_TAG .. " SkillProgression has no addSkillUsedHandler; it exposes: "
            .. table.concat(names, ", "))
    end
end

-- Buying, refunding or disabling a perk should hand the grants over at once
-- rather than on the next poll tick; the dirty key is cleared so the republish
-- is unconditional.
local function onPerkStateChanged()
    state.lastGrantsKey = nil
    refresh(0)
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        [C.GRANTED_EVENT] = onGranted,
    },
    engineHandlers = {
        shouldUpdate = function(dt)
            state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
            return state.pollTimer >= C.POLL_INTERVAL
        end,
        onUpdate = function()
            local elapsed = state.pollTimer
            state.pollTimer = 0
            refresh(elapsed)
        end,
        onLoad = function(data)
            data = type(data) == "table" and data or {}
            state.pollTimer = C.POLL_INTERVAL
            state.lastGrantsKey = nil
            state.appliedSkillId = type(data.conjurationAppliedSkillId) == "string"
                and data.conjurationAppliedSkillId or nil
            state.appliedSkillBonus = math.max(0, math.floor(tonumber(data.conjurationAppliedSkillBonus) or 0))
            state.grantedPactIds = {}
            state.pactUsedDay = {
                undead = math.floor(tonumber(data.conjurationUndeadUsedDay) or -1),
                daedra = math.floor(tonumber(data.conjurationDaedraUsedDay) or -1),
            }
            refresh(0)
        end,
        onSave = function()
            return {
                conjurationAppliedSkillId = state.appliedSkillId,
                conjurationAppliedSkillBonus = state.appliedSkillBonus,
                conjurationUndeadUsedDay = state.pactUsedDay.undead,
                conjurationDaedraUsedDay = state.pactUsedDay.daedra,
            }
        end,
    },
}

return __basepack_subsystem_result
