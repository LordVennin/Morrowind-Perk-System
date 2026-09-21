-- Illusion player runtime for SkillPerkSystem_BasePack.
--
-- The support perks are here (cast refund, reserve through the shared
-- skill-base section) along with the self riders read off the spell just
-- cast: Light asks the global side to dim the Agility of everyone nearby,
-- Invisibility and Chameleon ask for Sanctuary on the caster. Blind, Sound,
-- Demoralize and the paralysis damage bonus resolve on the target; see the
-- illusion section of basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Illusion][Player]"

local ensureSkillUsedHandler

local C = {
    PRACTICED_ILLUSIONIST = "illusion_practiced_illusionist",
    ILLUSIONISTS_RESERVE = "illusion_illusionists_reserve",
    BLINDING_LIGHT = "illusion_blinding_light",
    COLD_FEAR = "illusion_cold_fear",
    HARSH_LIGHT = "illusion_harsh_light",
    DEAFENING_ROAR = "illusion_deafening_roar",
    HELPLESS = "illusion_helpless",
    FADING_STEP = "illusion_fading_step",

    POLL_INTERVAL = 0.5,
    RESERVOIR_EVENT = "SkillPerkSystem_BasePack_SkillBase_SetReservoir",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Illusion_SetRiders",

    REFUND_FRACTION = 0.25,
    -- Fading Step: Invisibility has no magnitude, so it gets the cap
    -- outright; Chameleon earns half its magnitude up to the same cap, so a
    -- one-point Chameleon cannot buy the full ward for nothing.
    FADING_SANCTUARY_CAP = 20,
    FADING_CHAMELEON_FRACTION = 0.5,
}

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastReservoirKey = nil,
    lastRidersKey = nil,
    skillHandlerRegistered = false,
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

local function anyTargetPerkEnabled()
    return enabled(C.BLINDING_LIGHT) or enabled(C.DEAFENING_ROAR) or enabled(C.COLD_FEAR)
end

-- Reads the self-range riders off the spell just cast.
local function requestSelfRiders(selected)
    if not enabled(C.HARSH_LIGHT) and not enabled(C.FADING_STEP) then
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
            if id ~= nil and effectIsSelfRange(entry) then
                local magnitude = math.max(tonumber(entry.magnitudeMin) or 0, tonumber(entry.magnitudeMax) or 0)
                local seconds = math.floor(tonumber(entry.duration) or 0)
                if seconds >= 1 then
                    if id == "light" and enabled(C.HARSH_LIGHT) and magnitude > 0 then
                        request.lightMagnitude = math.max(request.lightMagnitude or 0, magnitude)
                        request.lightSeconds = math.max(request.lightSeconds or 0, seconds)
                        wanted = true
                    elseif id == "invisibility" and enabled(C.FADING_STEP) then
                        request.sanctuary = C.FADING_SANCTUARY_CAP
                        request.sanctuarySeconds = math.max(request.sanctuarySeconds or 0, seconds)
                        wanted = true
                    elseif id == "chameleon" and enabled(C.FADING_STEP) and magnitude > 0 then
                        local ward = math.min(C.FADING_SANCTUARY_CAP,
                            math.floor(magnitude * C.FADING_CHAMELEON_FRACTION))
                        if ward >= 1 then
                            request.sanctuary = math.max(request.sanctuary or 0, ward)
                            request.sanctuarySeconds = math.max(request.sanctuarySeconds or 0, seconds)
                            wanted = true
                        end
                    end
                end
            end
        end
    end)
    if wanted then
        if debugLogging then
            print(LOG_TAG .. string.format(" self rider: light=%s/%ss sanctuary=%s/%ss",
                tostring(request.lightMagnitude), tostring(request.lightSeconds),
                tostring(request.sanctuary), tostring(request.sanctuarySeconds)))
        end
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Illusion_SelfRider", request)
    end
end

local function onSkillUsed(skillId, params)
    if skillId ~= "illusion" then
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

    if anyTargetPerkEnabled() and type(selected.id) == "string" then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Illusion_CastNotice", {
            player = pself,
            spellId = selected.id,
        })
    end
    requestSelfRiders(selected)

    if not enabled(C.PRACTICED_ILLUSIONIST) then
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

local function publishReservoir()
    local wanted = enabled(C.ILLUSIONISTS_RESERVE)
    local key = tostring(wanted)
    if key == state.lastReservoirKey then
        return
    end
    state.lastReservoirKey = key
    core.sendGlobalEvent(C.RESERVOIR_EVENT, {
        player = pself,
        school = "illusion",
        tag = "Illusion",
        wanted = wanted,
    })
end

local function publishRiders()
    local riders = {
        playerId = pself.id,
        blind = enabled(C.BLINDING_LIGHT),
        sound = enabled(C.DEAFENING_ROAR),
        fear = enabled(C.COLD_FEAR),
        helpless = enabled(C.HELPLESS),
    }
    local key = table.concat({
        tostring(riders.blind), tostring(riders.sound), tostring(riders.fear), tostring(riders.helpless),
    }, ":")
    if key == state.lastRidersKey then
        return
    end
    state.lastRidersKey = key
    core.sendGlobalEvent(C.RIDERS_EVENT, riders)
end

local function refresh()
    ensureSkillUsedHandler()
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
    if text == "spsillusiondebug" or text == "luaspsillusiondebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Illusion_SetDebug", {
            player = pself,
            enabled = debugLogging,
        })
        return
    end
    if text ~= "spsillusion" and text ~= "luaspsillusion" then
        return
    end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " verbose=" .. tostring(debugLogging) .. " (toggle with spsillusiondebug)")
    for label, perkId in pairs({
        practicedIllusionist = C.PRACTICED_ILLUSIONIST, illusionistsReserve = C.ILLUSIONISTS_RESERVE,
        blindingLight = C.BLINDING_LIGHT, coldFear = C.COLD_FEAR, harshLight = C.HARSH_LIGHT,
        deafeningRoar = C.DEAFENING_ROAR, helpless = C.HELPLESS, fadingStep = C.FADING_STEP,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    refresh()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Illusion_Diagnose", { player = pself })
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
