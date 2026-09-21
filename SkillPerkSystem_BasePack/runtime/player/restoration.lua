-- Restoration player runtime for SkillPerkSystem_BasePack.
--
-- The support perks (refund, reserve through the shared skill-base section)
-- and the self riders read off the spell just cast: a doubled heal when low,
-- a Resist to match a Cure. Overflow keeps its own overheal pool here -- a
-- Fortify would raise the maximum and then take it away, which can kill --
-- absorbing weapon hits before they land and refunding any other loss the
-- frame it happens, with a dark bar drawn over the health bar. Bulwark of
-- Faith polls the shield/damage pairs, and Righteous Strike publishes to
-- targets whether Fortify Attack is up; see basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")
local storage = require("openmw.storage")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Restoration][Player]"

local ensureSkillUsedHandler
local ensureHitHandler

local C = {
    PRACTICED_HEALER = "restoration_practiced_healer",
    HEALERS_RESERVE = "restoration_healers_reserve",
    OVERFLOW = "restoration_overflow",
    PURIFYING_TOUCH = "restoration_purifying_touch",
    DESPERATE_PRAYER = "restoration_desperate_prayer",
    BULWARK_OF_FAITH = "restoration_bulwark_of_faith",
    RIGHTEOUS_STRIKE = "restoration_righteous_strike",

    POLL_INTERVAL = 0.5,
    RESERVOIR_EVENT = "SkillPerkSystem_BasePack_SkillBase_SetReservoir",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Restoration_SetRiders",
    REFUND_FRACTION = 0.25,

    -- Overflow: a heal cast at (near) full health is banked instead of lost.
    OVERFLOW_MIN_HEALTH_FRACTION = 0.9,
    OVERFLOW_CAP_FRACTION = 0.5,
    OVERFLOW_SECONDS = 30,
    -- The bar is drawn at an offset from the bottom-left of the screen. Lua
    -- cannot anchor to the vanilla health widget, so the offset is a pair of
    -- settings the player adjusts in the mod's settings page; these are the
    -- defaults for the stock HUD.
    OVERFLOW_BAR_OFFSET_X = 13,
    OVERFLOW_BAR_OFFSET_Y = -63,
    OVERFLOW_BAR_WIDTH = 65,
    OVERFLOW_BAR_HEIGHT = 12,
    HUD_SETTINGS_PAGE = "SkillPerkSystem",
    HUD_SETTINGS_GROUP = "SettingsSkillPerkSystemBasePackHud",

    DESPERATE_MAX_HEALTH_FRACTION = 0.25,
    PURIFY_RESIST = 50,
    PURIFY_SECONDS = 120,
    -- Bulwark of Faith: a Resist against an element while that element's
    -- damage is on you. Per second, refreshed each poll while the pair holds.
    BULWARK_FIRE_HEALTH = 2,
    BULWARK_FROST_FATIGUE = 5,
    BULWARK_SHOCK_HEALTH = 2,
    BULWARK_SHOCK_FATIGUE = 2,
}

local CURE_TO_RESIST = {
    curepoison = "resistPoison",
    curecommondisease = "resistCommonDisease",
    cureblightdisease = "resistBlightDisease",
}

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastReservoirKey = nil,
    lastRidersKey = nil,
    skillHandlerRegistered = false,
    hitHandlerRegistered = false,
    handlerReported = false,
    overheal = 0,
    overhealTimer = 0,
    lastHealth = nil,
    bar = nil,
    barTexture = nil,
    barUnlocked = false,
    barDragging = false,
    barDragOffset = nil,
    hudSettingsRegistered = false,
}

local hudSettings = storage.playerSection(C.HUD_SETTINGS_GROUP)

-- The bar's offsets live in the mod's settings page, next to the framework's
-- own group, so they can be adjusted in game rather than in a file.
local function ensureHudSettings()
    if state.hudSettingsRegistered then
        return
    end
    local settings = interfaces.Settings
    if settings == nil or type(settings.registerGroup) ~= "function" then
        return
    end
    local ok, err = pcall(settings.registerGroup, {
        key = C.HUD_SETTINGS_GROUP,
        page = C.HUD_SETTINGS_PAGE,
        l10n = "SkillPerkSystem",
        name = "basePackHud",
        permanentStorage = true,
        settings = {
            {
                key = "overhealBarX",
                name = "overhealBarXName",
                description = "overhealBarXDescription",
                default = C.OVERFLOW_BAR_OFFSET_X,
                renderer = "number",
                argument = { integer = true, min = -4000, max = 4000 },
            },
            {
                key = "overhealBarY",
                name = "overhealBarYName",
                description = "overhealBarYDescription",
                default = C.OVERFLOW_BAR_OFFSET_Y,
                renderer = "number",
                argument = { integer = true, min = -4000, max = 4000 },
            },
            {
                key = "overhealBarScale",
                name = "overhealBarScaleName",
                description = "overhealBarScaleDescription",
                default = 1,
                renderer = "number",
                argument = { min = 0.25, max = 10 },
            },
            {
                key = "overhealBarUnlocked",
                name = "overhealBarUnlockName",
                description = "overhealBarUnlockDescription",
                default = false,
                renderer = "checkbox",
            },
        },
    })
    if ok then
        state.hudSettingsRegistered = true
    else
        print(LOG_TAG .. " could not register HUD settings: " .. tostring(err))
    end
end

local function barOffset()
    local x = tonumber(hudSettings:get("overhealBarX")) or C.OVERFLOW_BAR_OFFSET_X
    local y = tonumber(hudSettings:get("overhealBarY")) or C.OVERFLOW_BAR_OFFSET_Y
    return util.vector2(x, y)
end

local function saveBarOffset(offset)
    pcall(function()
        hudSettings:set("overhealBarX", math.floor(offset.x))
        hudSettings:set("overhealBarY", math.floor(offset.y))
    end)
end

local function barUnlocked()
    return hudSettings:get("overhealBarUnlocked") == true
end

-- Full length of the bar in pixels, after the scale setting.
local function barFullWidth()
    local scale = tonumber(hudSettings:get("overhealBarScale")) or 1
    return math.max(4, math.floor(C.OVERFLOW_BAR_WIDTH * scale))
end

local function debugPrint(message)
    if debugLogging then
        print(LOG_TAG .. " " .. message)
    end
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

local function healthNumbers()
    local health = stats.dynamicStat("health")
    if health == nil then
        return nil, 0, 0
    end
    local maximum = math.max(0, (tonumber(health.base) or 0) + (tonumber(health.modifier) or 0))
    return health, tonumber(health.current) or 0, maximum
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

local function effectMagnitude(effectId)
    local ok, magnitude = pcall(function()
        local active = Actor.activeEffects(pself)
        local effect = active:getEffect(effectId)
        return effect ~= nil and effect.magnitude or 0
    end)
    return ok and (tonumber(magnitude) or 0) or 0
end

-- ---- Overflow ----------------------------------------------------------------
local function destroyBar()
    if state.bar ~= nil then
        pcall(function() state.bar:destroy() end)
        state.bar = nil
    end
end

-- While the bar is unlocked in settings it is drawn full width on the
-- window layer -- where the cursor exists -- and can be dragged into place
-- with any menu open; where it is dropped is written back to the offset
-- settings. Locked, it is the HUD bar sized to the pool.
local function barDragEvents()
    return {
        mousePress = async:callback(function(mouseEvent)
            if mouseEvent.button ~= 1 then return end
            local screen = ui.screenSize()
            local offset = barOffset()
            local absolute = util.vector2(offset.x, screen.y + offset.y)
            state.barDragging = true
            state.barDragOffset = mouseEvent.position - absolute
        end),
        mouseMove = async:callback(function(mouseEvent)
            if not state.barDragging or state.barDragOffset == nil or state.bar == nil then return end
            local screen = ui.screenSize()
            local absolute = mouseEvent.position - state.barDragOffset
            local offset = util.vector2(absolute.x, absolute.y - screen.y)
            saveBarOffset(offset)
            pcall(function()
                state.bar.layout.props.position = offset
                state.bar:update()
            end)
        end),
        mouseRelease = async:callback(function(mouseEvent)
            if mouseEvent.button ~= 1 then return end
            state.barDragging = false
            state.barDragOffset = nil
        end),
    }
end

local function updateBar()
    local unlocked = barUnlocked()
    local _, _, maximum = healthNumbers()
    if unlocked ~= state.barUnlocked then
        -- The layer changes with the mode, so the element is rebuilt.
        destroyBar()
        state.barUnlocked = unlocked
    end
    if not unlocked and (state.overheal <= 0 or maximum <= 0) then
        destroyBar()
        return
    end
    local width = barFullWidth()
    if not unlocked then
        width = math.max(1, math.floor(width * math.min(1, state.overheal / maximum)))
    end
    if state.bar == nil then
        if state.barTexture == nil then
            local ok, texture = pcall(ui.texture, { path = "white" })
            if not ok then
                return
            end
            state.barTexture = texture
        end
        local ok, element = pcall(ui.create, {
            layer = unlocked and "Windows" or "HUD",
            type = ui.TYPE.Image,
            props = {
                resource = state.barTexture,
                color = unlocked and util.color.rgb(0.8, 0.15, 0.15) or util.color.rgb(0.45, 0.05, 0.05),
                anchor = util.vector2(0, 1),
                relativePosition = util.vector2(0, 1),
                position = barOffset(),
                size = util.vector2(width, C.OVERFLOW_BAR_HEIGHT),
            },
            events = unlocked and barDragEvents() or nil,
        })
        if not ok then
            print(LOG_TAG .. " could not draw the overheal bar: " .. tostring(element))
            return
        end
        state.bar = element
        return
    end
    if state.barDragging then
        return
    end
    pcall(function()
        state.bar.layout.props.size = util.vector2(width, C.OVERFLOW_BAR_HEIGHT)
        state.bar.layout.props.position = barOffset()
        state.bar:update()
    end)
end

local function setOverheal(amount)
    state.overheal = math.max(0, math.floor(amount))
    if state.overheal > 0 then
        state.overhealTimer = C.OVERFLOW_SECONDS
        local _, current = healthNumbers()
        state.lastHealth = current
    else
        state.overhealTimer = 0
        state.lastHealth = nil
    end
    updateBar()
end

-- A Restore Health landed at (near) full health: the healing that would
-- have been wasted goes into the pool.
local function bankOverflow(magnitude, seconds)
    local _, current, maximum = healthNumbers()
    if maximum <= 0 or current < maximum * C.OVERFLOW_MIN_HEALTH_FRACTION then
        return
    end
    local wasted = magnitude * seconds - (maximum - current)
    if wasted <= 0 then
        return
    end
    local cap = math.floor(maximum * C.OVERFLOW_CAP_FRACTION)
    setOverheal(math.min(cap, state.overheal + wasted))
    debugPrint("overflow banked; pool now " .. state.overheal)
end

-- Runs per frame only while the pool holds anything. Damage a weapon hit
-- did not report (spells, falls, drowning) shows as a drop in health and is
-- refunded from the pool the same frame.
local function tickOverheal(dt)
    if state.overheal <= 0 then
        return
    end
    state.overhealTimer = state.overhealTimer - dt
    if state.overhealTimer <= 0 then
        setOverheal(0)
        debugPrint("overflow faded")
        return
    end
    local health, current, maximum = healthNumbers()
    if health == nil then
        return
    end
    if state.lastHealth ~= nil and current < state.lastHealth then
        local loss = state.lastHealth - current
        local refund = math.min(loss, state.overheal)
        if refund > 0 then
            pcall(function() health.current = math.min(maximum, current + refund) end)
            current = math.min(maximum, current + refund)
            state.overheal = state.overheal - refund
            debugPrint("overflow absorbed " .. refund)
            if state.overheal <= 0 then
                setOverheal(0)
                return
            end
            updateBar()
        end
    end
    state.lastHealth = current
end

-- Weapon hits are seen before they land, so the pool takes them first. One
-- point is always let through: a hit reduced to nothing is a miss to the
-- engine (no hit sound, no flash), while a single point still plays as a
-- hit, and the per-frame refund below hands that point straight back from
-- the pool, so the pool pays for the whole blow either way.
local function onHit(attack)
    if state.overheal <= 0 or type(attack) ~= "table" or attack.successful == false then
        return
    end
    if type(attack.damage) ~= "table" then
        return
    end
    local damage = tonumber(attack.damage.health) or 0
    if damage <= 1 then
        return
    end
    local absorbed = math.min(damage - 1, state.overheal)
    attack.damage.health = damage - absorbed
    state.overheal = state.overheal - absorbed
    debugPrint("overflow took " .. absorbed .. " of a hit")
    if state.overheal <= 0 then
        setOverheal(0)
    else
        updateBar()
    end
end

-- ---- Cast riders ---------------------------------------------------------------
local function requestCastRiders(selected)
    local okEffects, effects = pcall(function() return selected.effects end)
    if not okEffects or effects == nil then
        return
    end
    local request = { player = pself }
    local wanted = false
    local _, current, maximum = healthNumbers()
    pcall(function()
        for _, entry in pairs(effects) do
            local id = effectIdOf(entry)
            if id ~= nil and effectIsSelfRange(entry) then
                local magnitude = math.max(tonumber(entry.magnitudeMin) or 0, tonumber(entry.magnitudeMax) or 0)
                local seconds = math.floor(tonumber(entry.duration) or 0)
                if id == "restorehealth" and magnitude > 0 and seconds >= 1 then
                    if enabled(C.OVERFLOW) then
                        bankOverflow(magnitude, seconds)
                    end
                    if enabled(C.DESPERATE_PRAYER) and maximum > 0
                            and current < maximum * C.DESPERATE_MAX_HEALTH_FRACTION then
                        request.restoreHealth = math.max(request.restoreHealth or 0, magnitude)
                        request.restoreSeconds = math.max(request.restoreSeconds or 0, seconds)
                        wanted = true
                    end
                elseif CURE_TO_RESIST[id] ~= nil and enabled(C.PURIFYING_TOUCH) then
                    request[CURE_TO_RESIST[id]] = C.PURIFY_RESIST
                    request.resistSeconds = C.PURIFY_SECONDS
                    wanted = true
                end
            end
        end
    end)
    if wanted then
        debugPrint("cast riders requested")
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Restoration_SelfRider", request)
    end
end

local function onSkillUsed(skillId, params)
    if skillId ~= "restoration" then
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
    requestCastRiders(selected)

    if not enabled(C.PRACTICED_HEALER) then
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

-- ---- Bulwark of Faith --------------------------------------------------------
-- Each poll, whichever shield/damage pairs hold get a two-second restore that
-- the next poll refreshes; when a pair breaks, its restore simply runs out.
local function tickBulwark()
    if not enabled(C.BULWARK_OF_FAITH) then
        return
    end
    local health, fatigue = 0, 0
    if effectMagnitude("resistfire") > 0 and effectMagnitude("firedamage") > 0 then
        health = health + C.BULWARK_FIRE_HEALTH
    end
    if effectMagnitude("resistfrost") > 0 and effectMagnitude("frostdamage") > 0 then
        fatigue = fatigue + C.BULWARK_FROST_FATIGUE
    end
    if effectMagnitude("resistshock") > 0 and effectMagnitude("shockdamage") > 0 then
        health = health + C.BULWARK_SHOCK_HEALTH
        fatigue = fatigue + C.BULWARK_SHOCK_FATIGUE
    end
    if health > 0 or fatigue > 0 then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Restoration_SelfRider", {
            player = pself,
            bulwarkHealth = health,
            bulwarkFatigue = fatigue,
        })
    end
end

local function publishReservoir()
    local wanted = enabled(C.HEALERS_RESERVE)
    local key = tostring(wanted)
    if key == state.lastReservoirKey then
        return
    end
    state.lastReservoirKey = key
    core.sendGlobalEvent(C.RESERVOIR_EVENT, {
        player = pself,
        school = "restoration",
        tag = "Restoration",
        wanted = wanted,
    })
end

-- Righteous Strike resolves on the target, which needs to know whether
-- Fortify Attack is up; published only when that changes.
local function publishRiders()
    local righteous = enabled(C.RIGHTEOUS_STRIKE) and effectMagnitude("fortifyattack") > 0
    local key = tostring(righteous)
    if key == state.lastRidersKey then
        return
    end
    state.lastRidersKey = key
    core.sendGlobalEvent(C.RIDERS_EVENT, { playerId = pself.id, righteous = righteous })
end

local function refresh()
    ensureSkillUsedHandler()
    ensureHitHandler()
    ensureHudSettings()
    if barUnlocked() or state.barUnlocked then
        updateBar()
    end
    publishReservoir()
    publishRiders()
    tickBulwark()
end

local function onPerkStateChanged()
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    if not enabled(C.OVERFLOW) and state.overheal > 0 then
        setOverheal(0)
    end
    refresh()
end

local function onConsoleCommand(_, command)
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text == "spsrestorationdebug" or text == "luaspsrestorationdebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Restoration_SetDebug", { player = pself, enabled = debugLogging })
        return
    end
    if text ~= "spsrestoration" and text ~= "luaspsrestoration" then
        return
    end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " hit handler=" .. tostring(state.hitHandlerRegistered)
        .. " overheal=" .. state.overheal .. " (" .. string.format("%.1f", state.overhealTimer) .. "s)")
    for label, perkId in pairs({
        practicedHealer = C.PRACTICED_HEALER, healersReserve = C.HEALERS_RESERVE, overflow = C.OVERFLOW,
        purifyingTouch = C.PURIFYING_TOUCH, desperatePrayer = C.DESPERATE_PRAYER,
        bulwarkOfFaith = C.BULWARK_OF_FAITH, righteousStrike = C.RIGHTEOUS_STRIKE,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    print(LOG_TAG .. string.format(" resists fire=%d frost=%d shock=%d; fortify attack=%d",
        effectMagnitude("resistfire"), effectMagnitude("resistfrost"),
        effectMagnitude("resistshock"), effectMagnitude("fortifyattack")))
    local offset = barOffset()
    print(LOG_TAG .. string.format(" overheal bar offset x=%d y=%d", offset.x, offset.y))
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    refresh()
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Restoration_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
    },
    engineHandlers = {
        shouldUpdate = function(dt)
            state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
            -- Per frame only while the overheal pool holds something.
            return state.overheal > 0 or state.pollTimer >= C.POLL_INTERVAL
        end,
        onUpdate = function(dt)
            tickOverheal(tonumber(dt) or 0)
            if state.pollTimer >= C.POLL_INTERVAL then
                state.pollTimer = 0
                refresh()
            end
        end,
        onLoad = function()
            state.pollTimer = C.POLL_INTERVAL
            state.lastReservoirKey = nil
            state.lastRidersKey = nil
            -- The pool is a moment's buffer, not a saved stat.
            setOverheal(0)
            refresh()
        end,
        onConsoleCommand = onConsoleCommand,
    },
}

return __basepack_subsystem_result
