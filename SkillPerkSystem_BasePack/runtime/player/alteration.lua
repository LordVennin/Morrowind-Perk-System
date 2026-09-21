-- Alteration player runtime for SkillPerkSystem_BasePack.
--
-- Three things happen here. The support perks: a cost refund on successful
-- casts, and the reserve ability requested through the shared skill-base
-- section. The self riders: a Jump, Swift Swim or Water Walking cast is read
-- off the selected spell and the matching fortify asked of the global side.
-- The ward riders: the combat on-hit handler reports who struck the player,
-- and the global side answers with whatever the shields on the player call
-- for. The Burden riders resolve on the target; see the alteration section of
-- basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Alteration][Player]"

-- Assigned below; declared here so the poll can reach them. Interfaces fill
-- in as scripts come up, so both registrations are retried from the poll.
local ensureSkillUsedHandler
local ensureHitHandler

local C = {
    PRACTICED_SHAPER = "alteration_practiced_shaper",
    SHAPERS_RESERVE = "alteration_shapers_reserve",
    CRUSHING_BURDEN = "alteration_crushing_burden",
    GRINDING_WEIGHT = "alteration_grinding_weight",
    RETALIATING_WARD = "alteration_retaliating_ward",
    BASTION = "alteration_bastion",
    ELEMENTAL_AEGIS = "alteration_elemental_aegis",
    LONG_STRIDE = "alteration_long_stride",
    TIDAL_STRIDE = "alteration_tidal_stride",

    POLL_INTERVAL = 0.5,
    RESERVOIR_EVENT = "SkillPerkSystem_BasePack_SkillBase_SetReservoir",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Alteration_SetRiders",

    -- A share of the CAST SPELL'S OWN COST, never of the magicka pool.
    REFUND_FRACTION = 0.25,

    -- Self riders scale with the spell's own magnitude and are capped: a
    -- scroll of Icarian Flight is Jump 1000, and Swift Swim scrolls run into
    -- the hundreds, so an uncapped share would be game-breaking.
    LONG_STRIDE_FRACTION = 0.5,
    LONG_STRIDE_CAP = 50,
    TIDAL_SWIM_FRACTION = 0.25,
    TIDAL_WALK_SPEED = 10,
    TIDAL_SPEED_CAP = 25,
}

-- Self-range Alteration effects that carry a rider, and what each asks for.
local SELF_RIDER_EFFECTS = {
    jump = "acrobatics",
    swiftswim = "speedBySwim",
    waterwalking = "speedByWalk",
}

local SHIELD_EFFECTS = { "fireshield", "frostshield", "lightningshield", "shield" }

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastReservoirKey = nil,
    lastRidersKey = nil,
    skillHandlerRegistered = false,
    hitHandlerRegistered = false,
    handlerReported = false,
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

local function normalizedId(value)
    if type(value) ~= "string" then
        return nil
    end
    local id = value:lower():gsub("%s+", "")
    return id
end

-- Spell record effect entries differ by build: some hand the effect id
-- directly, some wrap it in a MagicEffectWithParams whose .effect carries it.
local function effectIdOf(entry)
    local ok, id = pcall(function()
        local inner = entry.effect
        if inner ~= nil and inner.id ~= nil then return inner.id end
        return entry.id
    end)
    return ok and normalizedId(id) or nil
end

local function effectIsSelfRange(entry)
    local okRange, range = pcall(function() return entry.range end)
    if not okRange or range == nil then
        return true
    end
    local okSelf, selfRange = pcall(function() return core.magic.RANGE.Self end)
    if not okSelf or selfRange == nil then
        return true
    end
    return range == selfRange
end

local function anyBurdenPerkEnabled()
    return enabled(C.CRUSHING_BURDEN) or enabled(C.GRINDING_WEIGHT)
end

-- Reads the self-range riders off the spell just cast and asks the global
-- side for the fortifies. Magnitudes are capped here, where the numbers are
-- decided, not on the global side that merely mints records.
local function requestSelfRiders(selected)
    if not enabled(C.LONG_STRIDE) and not enabled(C.TIDAL_STRIDE) then
        return
    end
    local okEffects, effects = pcall(function() return selected.effects end)
    if not okEffects or effects == nil then
        return
    end
    local request = { player = pself }
    local wanted = false
    pcall(function()
        for _, entry in pairs(effects) do
            local id = effectIdOf(entry)
            local kind = id ~= nil and SELF_RIDER_EFFECTS[id] or nil
            if kind ~= nil and effectIsSelfRange(entry) then
                local magnitude = math.max(tonumber(entry.magnitudeMin) or 0, tonumber(entry.magnitudeMax) or 0)
                local seconds = math.floor(tonumber(entry.duration) or 0)
                if seconds >= 1 then
                    if kind == "acrobatics" and enabled(C.LONG_STRIDE) and magnitude > 0 then
                        request.acrobatics = math.max(request.acrobatics or 0,
                            math.min(C.LONG_STRIDE_CAP, math.floor(magnitude * C.LONG_STRIDE_FRACTION)))
                        request.acrobaticsSeconds = math.max(request.acrobaticsSeconds or 0, seconds)
                        wanted = request.acrobatics > 0
                    elseif kind == "speedBySwim" and enabled(C.TIDAL_STRIDE) and magnitude > 0 then
                        request.speed = math.max(request.speed or 0,
                            math.min(C.TIDAL_SPEED_CAP, math.max(1, math.floor(magnitude * C.TIDAL_SWIM_FRACTION))))
                        request.speedSeconds = math.max(request.speedSeconds or 0, seconds)
                        wanted = true
                    elseif kind == "speedByWalk" and enabled(C.TIDAL_STRIDE) then
                        request.speed = math.max(request.speed or 0, C.TIDAL_WALK_SPEED)
                        request.speedSeconds = math.max(request.speedSeconds or 0, seconds)
                        wanted = true
                    end
                end
            end
        end
    end)
    if wanted then
        if debugLogging then
            print(LOG_TAG .. string.format(" self rider: acrobatics=%s/%ss speed=%s/%ss",
                tostring(request.acrobatics), tostring(request.acrobaticsSeconds),
                tostring(request.speed), tostring(request.speedSeconds)))
        end
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Alteration_SelfRider", request)
    end
end

local function onSkillUsed(skillId, params)
    if skillId ~= "alteration" then
        return
    end
    local useTypes = interfaces.SkillProgression ~= nil
        and interfaces.SkillProgression.SKILL_USE_TYPES or nil
    local castSuccess = useTypes ~= nil and useTypes.Spellcast_Success or nil
    if castSuccess ~= nil and type(params) == "table" and params.useType ~= nil
            and params.useType ~= castSuccess then
        return
    end
    local okSpell, selected = pcall(Actor.getSelectedSpell, pself)
    if not okSpell or selected == nil then
        return
    end

    -- Nearby targets briefly scan their own active spells for this cast
    -- landing; that is how the Burden riders see a burden arrive.
    if anyBurdenPerkEnabled() and type(selected.id) == "string" then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Alteration_CastNotice", {
            player = pself,
            spellId = selected.id,
        })
    end
    requestSelfRiders(selected)

    if not enabled(C.PRACTICED_SHAPER) then
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
    restoreMagicka(cost * C.REFUND_FRACTION)
end

-- Strength of each shield effect currently on the player, by effect id.
local function shieldMagnitudes()
    local out = {}
    local okEffects, active = pcall(Actor.activeEffects, pself)
    if not okEffects or active == nil or type(active.getEffect) ~= "function" then
        return out
    end
    for _, effectId in ipairs(SHIELD_EFFECTS) do
        local ok, effect = pcall(active.getEffect, active, effectId)
        local magnitude = ok and effect ~= nil and tonumber(effect.magnitude) or 0
        if magnitude > 0 then
            out[effectId] = magnitude
        end
    end
    return out
end

-- Someone struck the player. If a shield the ward perks care about is up,
-- tell the global side who did it and how strong each shield is; it decides
-- the riders from there.
local function onHit(attack)
    if type(attack) ~= "table" or attack.successful == false then
        return
    end
    local attacker = attack.attacker
    if attacker == nil or attacker == pself then
        return
    end
    local source = normalizedId(tostring(attack.sourceType or attack.attackType or ""))
    if source ~= nil and (source:find("ranged", 1, true) or source:find("magic", 1, true)
            or source:find("spell", 1, true)) then
        return
    end
    local wantElemental = enabled(C.RETALIATING_WARD) or enabled(C.ELEMENTAL_AEGIS)
    local wantBastion = enabled(C.BASTION)
    if not wantElemental and not wantBastion then
        return
    end
    local shields = shieldMagnitudes()
    local payload = {
        player = pself,
        attacker = attacker,
        fire = wantElemental and shields.fireshield or nil,
        frost = wantElemental and shields.frostshield or nil,
        shock = wantElemental and shields.lightningshield or nil,
        shield = wantBastion and shields.shield or nil,
        retaliate = enabled(C.RETALIATING_WARD),
        aegis = enabled(C.ELEMENTAL_AEGIS),
        bastion = wantBastion,
    }
    if payload.fire == nil and payload.frost == nil and payload.shock == nil and payload.shield == nil then
        return
    end
    if debugLogging then
        print(LOG_TAG .. string.format(" struck by %s with fire=%s frost=%s shock=%s shield=%s",
            tostring(attacker.recordId), tostring(payload.fire), tostring(payload.frost),
            tostring(payload.shock), tostring(payload.shield)))
    end
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Alteration_Retaliate", payload)
end

ensureSkillUsedHandler = function()
    if state.skillHandlerRegistered then
        return
    end
    local progression = interfaces.SkillProgression
    if progression == nil then
        return
    end
    if type(progression.addSkillUsedHandler) == "function" then
        progression.addSkillUsedHandler(onSkillUsed)
        state.skillHandlerRegistered = true
        return
    end
    if not state.handlerReported then
        state.handlerReported = true
        print(LOG_TAG .. " SkillProgression has no addSkillUsedHandler")
    end
end

ensureHitHandler = function()
    if state.hitHandlerRegistered then
        return
    end
    local combat = interfaces.Combat
    if combat ~= nil and type(combat.addOnHitHandler) == "function" then
        combat.addOnHitHandler(onHit)
        state.hitHandlerRegistered = true
    end
end

local function publishReservoir()
    local wanted = enabled(C.SHAPERS_RESERVE)
    local key = tostring(wanted)
    if key == state.lastReservoirKey then
        return
    end
    state.lastReservoirKey = key
    core.sendGlobalEvent(C.RESERVOIR_EVENT, {
        player = pself,
        school = "alteration",
        tag = "Alteration",
        wanted = wanted,
    })
end

-- The Burden riders resolve on the target, so it needs to know which are
-- active. Published only when the set changes.
local function publishRiders()
    local riders = {
        playerId = pself.id,
        crushingBurden = enabled(C.CRUSHING_BURDEN),
        grindingWeight = enabled(C.GRINDING_WEIGHT),
    }
    local key = tostring(riders.crushingBurden) .. ":" .. tostring(riders.grindingWeight)
    if key == state.lastRidersKey then
        return
    end
    state.lastRidersKey = key
    core.sendGlobalEvent(C.RIDERS_EVENT, riders)
end

local function refresh()
    ensureSkillUsedHandler()
    ensureHitHandler()
    publishReservoir()
    publishRiders()
end

local function onPerkStateChanged()
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    refresh()
end

local function onConsoleCommand(_, command)
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text == "spsalterationdebug" or text == "luaspsalterationdebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Alteration_SetDebug", {
            player = pself,
            enabled = debugLogging,
        })
        return
    end
    if text ~= "spsalteration" and text ~= "luaspsalteration" then
        return
    end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " hit handler=" .. tostring(state.hitHandlerRegistered)
        .. " verbose=" .. tostring(debugLogging) .. " (toggle with spsalterationdebug)")
    for label, perkId in pairs({
        practicedShaper = C.PRACTICED_SHAPER, shapersReserve = C.SHAPERS_RESERVE,
        crushingBurden = C.CRUSHING_BURDEN, grindingWeight = C.GRINDING_WEIGHT,
        retaliatingWard = C.RETALIATING_WARD, bastion = C.BASTION,
        elementalAegis = C.ELEMENTAL_AEGIS, longStride = C.LONG_STRIDE,
        tidalStride = C.TIDAL_STRIDE,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    local shields = shieldMagnitudes()
    print(LOG_TAG .. string.format(" shields up: fire=%s frost=%s shock=%s shield=%s",
        tostring(shields.fireshield), tostring(shields.frostshield),
        tostring(shields.lightningshield), tostring(shields.shield)))
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    refresh()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Alteration_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
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
        onLoad = function()
            state.pollTimer = C.POLL_INTERVAL
            state.lastReservoirKey = nil
            state.lastRidersKey = nil
            refresh()
        end,
        onConsoleCommand = onConsoleCommand,
    },
}

return __basepack_subsystem_result
