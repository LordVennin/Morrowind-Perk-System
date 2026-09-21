-- Mysticism player runtime for SkillPerkSystem_BasePack.
--
-- The support perks live here: a cost refund on successful Mysticism casts
-- (full for the travel spells under Paths Between), a Fortify Magicka ability
-- and the two daily powers granted through the global reconciler. Spell-Drinker
-- and Soul Siphon resolve on whichever actor the spell lands on, so this side
-- only publishes which of them are active; see the mysticism section of
-- basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Mysticism][Player]"

-- Assigned below, once onSkillUsed exists; declared here so the poll can
-- reach it. Interfaces fill in as scripts come up, so registration is done
-- lazily rather than at module load.
local skillHandlerRegistered
local skillHandlerReported
local ensureSkillUsedHandler

local C = {
    OLD_WAYS_INITIATE = "mysticism_old_ways_initiate",
    DEEP_WELLSPRING = "mysticism_deep_wellspring",
    SPELL_DRINKER = "mysticism_spell_drinker",
    PATHS_BETWEEN = "mysticism_paths_between",
    SOUL_SIPHON = "mysticism_soul_siphon",
    OMNISCIENCE = "mysticism_omniscience",
    DEVOUR_MAGIC = "mysticism_devour_magic",

    POLL_INTERVAL = 0.5,
    GRANTS_EVENT = "SkillPerkSystem_BasePack_Mysticism_SetGrants",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Mysticism_SetRiders",

    -- A share of the CAST SPELL'S OWN COST, never of the magicka pool: paying
    -- out against the pool lets the cheapest possible spell refund more than
    -- it costs. Below 1, so a cast can never turn a profit.
    OLD_WAYS_REFUND_FRACTION = 0.25,
    -- Soul Siphon pays out against the skill, not against anything the kill
    -- itself produced, so it is a fixed share of Mysticism per soul taken.
    SOUL_SIPHON_SKILL_FRACTION = 0.5,
    -- In-game seconds in a day, for the once-per-day power checks.
    SECONDS_PER_DAY = 86400,
}

-- Paths Between: a Mysticism spell whose effects all sit in this set costs
-- nothing. Requiring every effect stops a Recall folded into a combat spell
-- from making the whole thing free.
local TRAVEL_EFFECT_IDS = {
    mark = true,
    recall = true,
    almsiviintervention = true,
    divineintervention = true,
}

-- Verbose tracing, off by default and toggled at runtime with
-- "spsmysticismdebug" in the console.
local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastGrantsKey = nil,
    lastRidersKey = nil,
    -- Record ids the global side says we currently hold, per daily power, and
    -- the game day each power was last seen actually taking effect.
    grantedPowerIds = {},
    powerUsedDay = { devour = -1, omniscience = -1 },
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

local function currentGameDay()
    local ok, gameTime = pcall(core.getGameTime)
    if not ok or type(gameTime) ~= "number" then
        return 0
    end
    return math.floor(gameTime / C.SECONDS_PER_DAY)
end

-- Spell record effect entries differ by build: some hand the effect id
-- directly, some wrap it in a MagicEffectWithParams whose .effect carries it.
local function effectIdOf(entry)
    if type(entry) ~= "table" and type(entry) ~= "userdata" then
        return nil
    end
    local ok, id = pcall(function()
        local inner = entry.effect
        if inner ~= nil and inner.id ~= nil then return inner.id end
        return entry.id
    end)
    if not ok or type(id) ~= "string" then
        return nil
    end
    local normalized = id:lower():gsub("%s+", "")
    return normalized
end

-- True when the spell's effects are all travel effects (and there is at
-- least one). An unreadable effect list answers false, never free.
local function isTravelSpell(selected)
    local okEffects, effects = pcall(function() return selected.effects end)
    if not okEffects or effects == nil then
        return false
    end
    local seen = 0
    local allTravel = true
    pcall(function()
        for _, entry in pairs(effects) do
            local id = effectIdOf(entry)
            if id ~= nil then
                seen = seen + 1
                if not TRAVEL_EFFECT_IDS[id] then allTravel = false end
            end
        end
    end)
    return seen > 0 and allTravel
end

local function anyRiderPerkEnabled()
    return enabled(C.SPELL_DRINKER) or enabled(C.SOUL_SIPHON)
end

local function onSkillUsed(skillId, params)
    if skillId ~= "mysticism" then
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

    -- Nearby targets briefly scan their own active spells for this cast
    -- landing; that is how Spell-Drinker and Soul Siphon see an Absorb or
    -- Soultrap arrive on builds without the SpellCasting interface.
    if anyRiderPerkEnabled() and type(selected.id) == "string" then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Mysticism_CastNotice", {
            player = pself,
            spellId = selected.id,
        })
    end

    local cost = tonumber(selected.cost)
    if cost == nil and type(selected.id) == "string" then
        local okRecord, record = pcall(function() return core.magic.spells.records[selected.id] end)
        if okRecord and record ~= nil then cost = tonumber(record.cost) end
    end
    if cost == nil or cost <= 0 then
        return
    end

    if enabled(C.PATHS_BETWEEN) and isTravelSpell(selected) then
        restoreMagicka(cost)
        return
    end
    if enabled(C.OLD_WAYS_INITIATE) then
        restoreMagicka(cost * C.OLD_WAYS_REFUND_FRACTION)
    end
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
        if debugLogging then
            print(LOG_TAG .. " skill-used handler registered")
        end
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

-- Watches for a granted daily power taking effect. Matching the granted
-- record id rather than the effect means an ordinary Spell Absorption or
-- Detect spell the player also knows never spends the daily use.
local function notePowerUse(day)
    local ok, active = pcall(function() return Actor.activeSpells(pself) end)
    if not ok or active == nil then
        return
    end
    for family, recordId in pairs(state.grantedPowerIds) do
        if recordId ~= nil and state.powerUsedDay[family] ~= day then
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
                state.powerUsedDay[family] = day
            end
        end
    end
end

local function publishGrants()
    local day = currentGameDay()
    notePowerUse(day)

    local wellspringTier = enabled(C.DEEP_WELLSPRING) and 1 or 0
    local devourTier = enabled(C.DEVOUR_MAGIC) and 1 or 0
    local omniscienceTier = enabled(C.OMNISCIENCE) and 1 or 0

    local grantsKey = table.concat({
        wellspringTier, devourTier, omniscienceTier, day,
        state.powerUsedDay.devour, state.powerUsedDay.omniscience,
    }, ":")
    if grantsKey == state.lastGrantsKey then
        return
    end
    state.lastGrantsKey = grantsKey
    core.sendGlobalEvent(C.GRANTS_EVENT, {
        player = pself,
        wellspringTier = wellspringTier,
        devourTier = devourTier,
        omniscienceTier = omniscienceTier,
        currentDay = day,
        devourUsedDay = state.powerUsedDay.devour,
        omniscienceUsedDay = state.powerUsedDay.omniscience,
    })
end

local function onGranted(data)
    state.grantedPowerIds = {
        devour = type(data) == "table" and data.devour or nil,
        omniscience = type(data) == "table" and data.omniscience or nil,
    }
end

-- Spell-Drinker and Soul Siphon resolve on the target, so it needs to know
-- which are active. Published only when the set changes.
local function publishRiders()
    local riders = {
        playerId = pself.id,
        spellDrinker = enabled(C.SPELL_DRINKER),
        soulSiphon = enabled(C.SOUL_SIPHON),
    }
    local ridersKey = tostring(riders.spellDrinker) .. ":" .. tostring(riders.soulSiphon)
    if ridersKey == state.lastRidersKey then
        return
    end
    state.lastRidersKey = ridersKey
    if debugLogging then
        print(LOG_TAG .. string.format(" publishing riders: caster=%s drink=%s siphon=%s",
            tostring(riders.playerId), tostring(riders.spellDrinker), tostring(riders.soulSiphon)))
    end
    core.sendGlobalEvent(C.RIDERS_EVENT, riders)
end

local function refresh()
    ensureSkillUsedHandler()
    publishGrants()
    publishRiders()
end

local function onPerkStateChanged()
    state.lastGrantsKey = nil
    state.lastRidersKey = nil
    refresh()
end

-- A trapped soul was taken: the global side verified the kill and the trap,
-- this side pays out against the player's own Mysticism.
local function onSoulSiphon(data)
    if not enabled(C.SOUL_SIPHON) then
        return
    end
    local skill = stats.skillStat("mysticism")
    local level = skill ~= nil and (tonumber(skill.modified) or tonumber(skill.base)) or 0
    local amount = math.floor((level or 0) * C.SOUL_SIPHON_SKILL_FRACTION)
    if amount <= 0 then
        return
    end
    restoreMagicka(amount)
    if debugLogging then
        print(LOG_TAG .. " soul siphon: restored " .. amount .. " magicka")
    end
end

local function onConsoleCommand(_, command)
    -- Console input may arrive bare or with a "lua" prefix depending on how
    -- the console routes unknown commands, so accept both spellings.
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text == "spsmysticismdebug" or text == "luaspsmysticismdebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Mysticism_SetDebug", {
            player = pself,
            enabled = debugLogging,
        })
        return
    end
    if text ~= "spsmysticism" and text ~= "luaspsmysticism" then
        return
    end

    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " player id=" .. tostring(pself.id))
    print(LOG_TAG .. " skill-used handler registered=" .. tostring(skillHandlerRegistered == true))
    print(LOG_TAG .. " verbose logging=" .. tostring(debugLogging)
        .. " (toggle with spsmysticismdebug)")
    for label, perkId in pairs({
        oldWaysInitiate = C.OLD_WAYS_INITIATE, deepWellspring = C.DEEP_WELLSPRING,
        spellDrinker = C.SPELL_DRINKER, pathsBetween = C.PATHS_BETWEEN,
        soulSiphon = C.SOUL_SIPHON, omniscience = C.OMNISCIENCE,
        devourMagic = C.DEVOUR_MAGIC,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    print(LOG_TAG .. string.format(" day=%d devourUsed=%d omniscienceUsed=%d",
        currentGameDay(), state.powerUsedDay.devour, state.powerUsedDay.omniscience))

    -- Force both publishes through, ignoring the change-detection keys.
    state.lastGrantsKey = nil
    state.lastRidersKey = nil
    refresh()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Mysticism_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        SkillPerkSystem_BasePack_Mysticism_Granted = onGranted,
        SkillPerkSystem_BasePack_Mysticism_SoulSiphon = onSoulSiphon,
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
            state.grantedPowerIds = {}
            state.powerUsedDay = {
                devour = math.floor(tonumber(data.mysticismDevourUsedDay) or -1),
                omniscience = math.floor(tonumber(data.mysticismOmniscienceUsedDay) or -1),
            }
            refresh()
        end,
        onConsoleCommand = onConsoleCommand,
        onSave = function()
            return {
                mysticismDevourUsedDay = state.powerUsedDay.devour,
                mysticismOmniscienceUsedDay = state.powerUsedDay.omniscience,
            }
        end,
    },
}

return __basepack_subsystem_result
