-- Destruction player runtime for SkillPerkSystem_BasePack.
--
-- Two jobs. The support line is handled here: a Fortify Magicka ability
-- granted through the global reconciler, and a cost refund driven by the
-- skill-used handler. The rider perks (elemental, Disintegrate, Drain) are
-- resolved on the target, so this side only publishes which of them are
-- active; see the destruction section of basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Destruction][Player]"

-- Assigned below, once onSkillUsed exists; declared here so the poll can
-- reach it. Interfaces fill in as scripts come up, so registration is done
-- lazily rather than at module load.
local skillHandlerRegistered
local skillHandlerReported
local ensureSkillUsedHandler

local C = {
    ELEMENTAL_FOCUS = "destruction_elemental_focus",
    ARCANE_RESERVOIR = "destruction_arcane_reservoir",
    SEARING_HEAT = "destruction_searing_heat",
    BITING_COLD = "destruction_biting_cold",
    STORM_CHANNEL = "destruction_storm_channel",
    SUNDERING_RUIN = "destruction_sundering_ruin",
    WITHERING_CURSE = "destruction_withering_curse",
    EFFICIENT_RUIN = "destruction_efficient_ruin",
    ANNIHILATION_MASTERY = "destruction_annihilation_mastery",

    POLL_INTERVAL = 0.5,
    GRANTS_EVENT = "SkillPerkSystem_BasePack_Destruction_SetGrants",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Destruction_SetRiders",

    ELEMENTAL_FOCUS_SKILL_BONUS = 10,
    -- A share of the CAST SPELL'S OWN COST, never of the magicka pool: paying
    -- out against the pool lets the cheapest possible spell refund more than
    -- it costs. Below 1, so a cast can never turn a profit.
    EFFICIENT_RUIN_REFUND_FRACTION = 0.25,
}

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastGrantsKey = nil,
    lastRidersKey = nil,
    appliedDestruction = 0,
}

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

local function onSkillUsed(skillId, params)
    if skillId ~= "destruction" or not enabled(C.EFFICIENT_RUIN) then
        return
    end
    local useTypes = interfaces.SkillProgression ~= nil
        and interfaces.SkillProgression.SKILL_USE_TYPES or nil
    local castSuccess = useTypes ~= nil and useTypes.Spellcast_Success or nil
    if castSuccess ~= nil and type(params) == "table" and params.useType ~= nil
            and params.useType ~= castSuccess then
        return
    end

    -- The spell being cast is the selected one. A cast from an enchanted item
    -- selects no spell and spends no magicka, so it refunds nothing.
    local okSpell, selected = pcall(Actor.getSelectedSpell, pself)
    if not okSpell or selected == nil then
        return
    end
    local cost = tonumber(selected.cost)
    if cost == nil and type(selected.id) == "string" then
        local okRecord, record = pcall(function() return core.magic.spells.records[selected.id] end)
        if okRecord and record ~= nil then cost = tonumber(record.cost) end
    end
    if cost == nil or cost <= 0 then
        return
    end
    restoreMagicka(cost * C.EFFICIENT_RUIN_REFUND_FRACTION)
end

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

-- The reservoir is an Ability carrying Fortify Magicka. Writing the dynamic
-- stat's modifier directly does not work for health, magicka or fatigue: the
-- engine drives those from active effects.
local function publishGrants()
    local reservoirTier = enabled(C.ARCANE_RESERVOIR) and 1 or 0
    local grantsKey = tostring(reservoirTier)
    if grantsKey == state.lastGrantsKey then
        return
    end
    state.lastGrantsKey = grantsKey
    core.sendGlobalEvent(C.GRANTS_EVENT, {
        player = pself,
        reservoirTier = reservoirTier,
    })
end

-- Rider perks resolve on whichever actor the spell lands on, so the target
-- side needs to know which are active. Published only when the set changes.
local function publishRiders()
    local riders = {
        playerId = pself.id,
        searingHeat = enabled(C.SEARING_HEAT),
        bitingCold = enabled(C.BITING_COLD),
        stormChannel = enabled(C.STORM_CHANNEL),
        sunderingRuin = enabled(C.SUNDERING_RUIN),
        witheringCurse = enabled(C.WITHERING_CURSE),
        annihilationMastery = enabled(C.ANNIHILATION_MASTERY),
    }
    local ridersKey = table.concat({
        tostring(riders.searingHeat), tostring(riders.bitingCold),
        tostring(riders.stormChannel), tostring(riders.sunderingRuin),
        tostring(riders.witheringCurse), tostring(riders.annihilationMastery),
    }, ":")
    if ridersKey == state.lastRidersKey then
        return
    end
    state.lastRidersKey = ridersKey
    print(LOG_TAG .. string.format(
        " publishing riders: caster=%s fire=%s frost=%s shock=%s sunder=%s wither=%s weakness=%s",
        tostring(riders.playerId), tostring(riders.searingHeat), tostring(riders.bitingCold),
        tostring(riders.stormChannel), tostring(riders.sunderingRuin),
        tostring(riders.witheringCurse), tostring(riders.annihilationMastery)))
    core.sendGlobalEvent(C.RIDERS_EVENT, riders)
end

local function refresh()
    ensureSkillUsedHandler()
    publishGrants()
    publishRiders()

    state.appliedDestruction = setModifier(stats.skillStat("destruction"), state.appliedDestruction,
        enabled(C.ELEMENTAL_FOCUS) and C.ELEMENTAL_FOCUS_SKILL_BONUS or 0)
end

local function onPerkStateChanged()
    state.lastGrantsKey = nil
    state.lastRidersKey = nil
    refresh()
end

-- Withering Curse pays the player what their Drain spells took; the target
-- side works out the amount and the global side forwards it here.
local function onWitheringReturn(data)
    if type(data) ~= "table" or not enabled(C.WITHERING_CURSE) then
        return
    end
    local health = tonumber(data.health) or 0
    local fatigue = tonumber(data.fatigue) or 0
    local magicka = tonumber(data.magicka) or 0

    if magicka > 0 then restoreMagicka(magicka) end
    for name, amount in pairs({ health = health, fatigue = fatigue }) do
        if amount > 0 then
            local stat = stats.dynamicStat(name)
            if stat ~= nil then
                local maximum = math.max(0, (tonumber(stat.base) or 0) + (tonumber(stat.modifier) or 0))
                local current = tonumber(stat.current) or 0
                pcall(function()
                    stat.current = math.min(maximum, current + amount)
                end)
            end
        end
    end
end

-- Typing "spsdestruction" in the console dumps the whole rider pipeline and
-- forces a republish. The state lines are printed once when they change, which
-- makes them easy to miss in a running log; this puts the same information a
-- keystroke away instead.
local function onConsoleCommand(_, command)
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text ~= "spsdestruction" then
        return
    end

    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " player id=" .. tostring(pself.id))
    print(LOG_TAG .. " skill-used handler registered=" .. tostring(skillHandlerRegistered == true))
    for label, perkId in pairs({
        elementalFocus = C.ELEMENTAL_FOCUS, arcaneReservoir = C.ARCANE_RESERVOIR,
        searingHeat = C.SEARING_HEAT, bitingCold = C.BITING_COLD,
        stormChannel = C.STORM_CHANNEL, sunderingRuin = C.SUNDERING_RUIN,
        witheringCurse = C.WITHERING_CURSE, annihilationMastery = C.ANNIHILATION_MASTERY,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end

    -- Force both publishes through, ignoring the change-detection keys.
    state.lastGrantsKey = nil
    state.lastRidersKey = nil
    refresh()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Destruction_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        SkillPerkSystem_BasePack_Destruction_WitheringReturn = onWitheringReturn,
    },
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
            state.lastRidersKey = nil
            state.appliedDestruction = math.max(0, math.floor(tonumber(data.destructionAppliedSkill) or 0))
            refresh()
        end,
        onConsoleCommand = onConsoleCommand,
        onSave = function()
            return { destructionAppliedSkill = state.appliedDestruction }
        end,
    },
}

return __basepack_subsystem_result
