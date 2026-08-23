-- Acrobatics player runtime for SkillPerkSystem_BasePack.
--
-- Airborne time is short -- a jump lasts on the order of a second -- so this
-- subsystem polls at 0.25s rather than the 0.5s used by the slower trees, which
-- is the faster cadence the repository's update budget allows for state that
-- can only be sampled. There is still no per-frame path.
--
-- Swimming reads as "not on ground" in the engine, so it is excluded explicitly;
-- otherwise swimming would grant the whole airborne half of the tree.

local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local C = {
    SURE_FOOTING = "acrobatics_sure_footing",
    COILED_LEGS = "acrobatics_coiled_legs",
    AIR_CONTROL = "acrobatics_air_control",
    WALL_RUNNER = "acrobatics_wall_runner",
    ROOFTOP_RUNNER = "acrobatics_rooftop_runner",
    FEATHERFALL = "acrobatics_featherfall",
    WEIGHTLESS = "acrobatics_weightless",

    POLL_INTERVAL = 0.25,

    SURE_FOOTING_ACROBATICS = 5,
    SURE_FOOTING_AGILITY = 5,
    SURE_FOOTING_MAX_LOAD = 0.5,

    COILED_LEGS_ACROBATICS = 10,
    COILED_LEGS_MIN_FATIGUE = 0.60,

    AIR_CONTROL_ACROBATICS = 10,
    AIR_CONTROL_AGILITY = 10,
    WALL_RUNNER_ACROBATICS = 20,
    WALL_RUNNER_AGILITY = 15,
    FEATHERFALL_SPEED = 10,

    ROOFTOP_RESTORE_FRACTION = 0.10,
    ROOFTOP_RESTORE_FRACTION_IMPROVED = 0.20,
    ROOFTOP_COOLDOWN = 10.0,

    WEIGHTLESS_ACROBATICS = 15,
    WEIGHTLESS_AIRBORNE_GRACE = 2.0,
}

local state = {
    pollTimer = C.POLL_INTERVAL,
    wasAirborne = false,
    airborneGrace = 0,
    rooftopCooldown = 0,
    appliedAcrobatics = 0,
    appliedAgility = 0,
    appliedSpeed = 0,
}

local function restoreFatigueOnLanding()
    if not enabled(C.ROOFTOP_RUNNER) or state.rooftopCooldown > 0 then
        return
    end

    local fatigue = stats.fatigueStat()
    local _, maxFatigue = stats.fatigueRatio(fatigue, 0)
    if fatigue == nil or maxFatigue <= 0 then
        return
    end

    local fraction = enabled(C.FEATHERFALL)
        and C.ROOFTOP_RESTORE_FRACTION_IMPROVED
        or C.ROOFTOP_RESTORE_FRACTION
    local current = tonumber(fatigue.current) or 0
    local ok = pcall(function()
        fatigue.current = math.min(maxFatigue, current + maxFatigue * fraction)
    end)
    if ok then
        state.rooftopCooldown = C.ROOFTOP_COOLDOWN
    end
end

local function refresh(elapsed)
    elapsed = math.max(0, tonumber(elapsed) or 0)

    if state.rooftopCooldown > 0 then
        state.rooftopCooldown = math.max(0, state.rooftopCooldown - elapsed)
    end

    local grounded = stats.isOnGround()
    local swimming = stats.isSwimming()
    local airborne = not grounded and not swimming

    if airborne then
        state.airborneGrace = C.WEIGHTLESS_AIRBORNE_GRACE
    else
        if state.wasAirborne then
            restoreFatigueOnLanding()
        end
        state.airborneGrace = math.max(0, state.airborneGrace - elapsed)
    end
    state.wasAirborne = airborne

    -- Weightless keeps the airborne bonuses alive briefly after touchdown so
    -- chained jumps do not flicker in and out of the bonus.
    local airborneBonusActive = airborne
        or (enabled(C.WEIGHTLESS) and state.airborneGrace > 0)

    local fatigue = stats.fatigueStat()
    local fatiguePercent = stats.fatigueRatio(fatigue, 0)

    local acrobatics = 0
    local agility = 0
    local speed = 0

    if enabled(C.SURE_FOOTING) and grounded
            and stats.encumbranceRatio() < C.SURE_FOOTING_MAX_LOAD then
        acrobatics = acrobatics + C.SURE_FOOTING_ACROBATICS
        agility = agility + C.SURE_FOOTING_AGILITY
    end
    if enabled(C.COILED_LEGS) and fatiguePercent > C.COILED_LEGS_MIN_FATIGUE then
        acrobatics = acrobatics + C.COILED_LEGS_ACROBATICS
    end
    if enabled(C.AIR_CONTROL) and airborneBonusActive then
        -- Wall Runner replaces Air Control's values rather than adding to them.
        if enabled(C.WALL_RUNNER) then
            acrobatics = acrobatics + C.WALL_RUNNER_ACROBATICS
            agility = agility + C.WALL_RUNNER_AGILITY
        else
            acrobatics = acrobatics + C.AIR_CONTROL_ACROBATICS
            agility = agility + C.AIR_CONTROL_AGILITY
        end
        if enabled(C.FEATHERFALL) then
            speed = speed + C.FEATHERFALL_SPEED
        end
    end
    if enabled(C.WEIGHTLESS) then
        acrobatics = acrobatics + C.WEIGHTLESS_ACROBATICS
    end

    state.appliedAcrobatics = setModifier(stats.skillStat("acrobatics"), state.appliedAcrobatics, acrobatics)
    state.appliedAgility = setModifier(stats.attributeStat("agility"), state.appliedAgility, agility)
    state.appliedSpeed = setModifier(stats.attributeStat("speed"), state.appliedSpeed, speed)
end

__basepack_subsystem_result = {
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
            state.wasAirborne = false
            state.airborneGrace = 0
            state.rooftopCooldown = math.max(0, tonumber(data.acrobaticsRooftopCooldown) or 0)
            state.appliedAcrobatics = math.max(0, math.floor(tonumber(data.acrobaticsAppliedAcrobatics) or 0))
            state.appliedAgility = math.max(0, math.floor(tonumber(data.acrobaticsAppliedAgility) or 0))
            state.appliedSpeed = math.max(0, math.floor(tonumber(data.acrobaticsAppliedSpeed) or 0))
            refresh(0)
        end,
        onSave = function()
            return {
                acrobaticsRooftopCooldown = state.rooftopCooldown,
                acrobaticsAppliedAcrobatics = state.appliedAcrobatics,
                acrobaticsAppliedAgility = state.appliedAgility,
                acrobaticsAppliedSpeed = state.appliedSpeed,
            }
        end,
    },
}

return __basepack_subsystem_result
