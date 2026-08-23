-- Athletics player runtime for SkillPerkSystem_BasePack.
--
-- Every effect in this tree resolves at a fixed 0.5 second cadence: Stride
-- stacks build every 2 seconds, decay after 3 seconds of standing still, and
-- Second Wind is on a 30-60 second cooldown. None of that needs frame
-- granularity, so this subsystem never asks for a per-frame update -- not even
-- while stacks are active. Idle cost is one poll every 0.5 seconds.

local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Actor = types.Actor
local NPC = types.NPC
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"

local __basepack_subsystem_result = nil

local C = {
    STEADY_PACE = "athletics_steady_pace",
    DEEP_LUNGS = "athletics_deep_lungs",
    MOMENTUM = "athletics_momentum",
    LONG_STRIDER = "athletics_long_strider",
    SECOND_WIND = "athletics_second_wind",
    RELENTLESS = "athletics_relentless",
    PEERLESS_CONDITIONING = "athletics_peerless_conditioning",

    POLL_INTERVAL = 0.5,

    STEADY_PACE_ATHLETICS = 5,
    STEADY_PACE_MAX_LOAD = 0.5,

    DEEP_LUNGS_ENDURANCE = 10,
    DEEP_LUNGS_MIN_FATIGUE = 0.60,

    STRIDE_BUILD_SECONDS = 2.0,
    STRIDE_DECAY_SECONDS = 3.0,
    STRIDE_BASE_MAX = 5,
    STRIDE_LONG_STRIDER_MAX = 10,
    STRIDE_SPEED_EACH = 2,
    STRIDE_ATHLETICS_EACH = 1,
    -- Squared, and generous enough that idle animation jitter does not read as
    -- movement. Morrowind units; a walking step covers far more than this.
    STRIDE_MOVE_EPSILON_SQUARED = 64,
    -- A jump of this size in one poll is a teleport or cell change, not running.
    STRIDE_TELEPORT_EPSILON_SQUARED = 4000000,

    RELENTLESS_MIN_FATIGUE = 0.50,

    SECOND_WIND_TRIGGER_FATIGUE = 0.20,
    SECOND_WIND_RESTORE_FRACTION = 0.25,
    SECOND_WIND_COOLDOWN = 60.0,
    SECOND_WIND_COOLDOWN_IMPROVED = 30.0,

    PEERLESS_FATIGUE_FRACTION = 0.20,
}

local state = {
    pollTimer = C.POLL_INTERVAL,
    strides = 0,
    strideProgress = 0,
    strideIdleSeconds = 0,
    lastPosition = nil,
    secondWindCooldown = 0,
    -- Applied modifier amounts, tracked so they can be reverted exactly.
    appliedAthletics = 0,
    appliedEndurance = 0,
    appliedSpeed = 0,
    appliedMaxFatigue = 0,
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

local function skillStat(skillId)
    local skills = NPC ~= nil and NPC.stats ~= nil and NPC.stats.skills or nil
    local accessor = skills ~= nil and skills[skillId] or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

local function attributeStat(attributeId)
    local attributes = Actor ~= nil and Actor.stats ~= nil and Actor.stats.attributes or nil
    local accessor = attributes ~= nil and attributes[attributeId] or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

local function fatigueStat()
    local dynamic = Actor ~= nil and Actor.stats ~= nil and Actor.stats.dynamic or nil
    local accessor = dynamic ~= nil and dynamic.fatigue or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

-- Applies a delta to stat.modifier so that exactly `desired` of this
-- subsystem's contribution is present, leaving other contributors untouched.
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

-- Max fatigue counts this subsystem's own modifier, so subtract it before
-- deriving the percentage. Otherwise Peerless Conditioning would shift every
-- fatigue threshold in the tree.
local function fatigueRatio(fatigue)
    if fatigue == nil then
        return 0, 0
    end
    local base = tonumber(fatigue.base) or 0
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    local naturalMax = math.max(0, maxFatigue - state.appliedMaxFatigue)
    if naturalMax <= 0 then
        return 0, maxFatigue
    end
    return (tonumber(fatigue.current) or 0) / naturalMax, maxFatigue
end

local function encumbranceRatio()
    if Actor == nil or type(Actor.getEncumbrance) ~= "function" or type(Actor.getCapacity) ~= "function" then
        return 0
    end
    local okLoad, load = pcall(Actor.getEncumbrance, pself)
    local okCapacity, capacity = pcall(Actor.getCapacity, pself)
    if not okLoad or not okCapacity then
        return 0
    end
    capacity = tonumber(capacity) or 0
    if capacity <= 0 then
        return 0
    end
    return (tonumber(load) or 0) / capacity
end

-- Movement is sampled rather than hooked: there is no player-side "started
-- moving" event, and one position read per poll is cheaper than any watcher.
local function movedSinceLastPoll()
    local ok, position = pcall(function() return pself.position end)
    if not ok or position == nil then
        return false
    end
    local previous = state.lastPosition
    state.lastPosition = position
    if previous == nil then
        return false
    end
    local dx = (tonumber(position.x) or 0) - (tonumber(previous.x) or 0)
    local dy = (tonumber(position.y) or 0) - (tonumber(previous.y) or 0)
    local dz = (tonumber(position.z) or 0) - (tonumber(previous.z) or 0)
    local distanceSquared = dx * dx + dy * dy + dz * dz
    if distanceSquared >= C.STRIDE_TELEPORT_EPSILON_SQUARED then
        return false
    end
    return distanceSquared > C.STRIDE_MOVE_EPSILON_SQUARED
end

local function strideMaximum()
    if enabled(C.LONG_STRIDER) then
        return C.STRIDE_LONG_STRIDER_MAX
    end
    return C.STRIDE_BASE_MAX
end

local function clearStrides()
    state.strides = 0
    state.strideProgress = 0
    state.strideIdleSeconds = 0
end

local function updateStrides(elapsed, fatiguePercent)
    if not enabled(C.MOMENTUM) then
        clearStrides()
        return
    end

    local maximum = strideMaximum()
    if state.strides > maximum then
        state.strides = maximum
    end

    if movedSinceLastPoll() then
        state.strideIdleSeconds = 0
        if state.strides < maximum then
            state.strideProgress = state.strideProgress + elapsed
            while state.strideProgress >= C.STRIDE_BUILD_SECONDS and state.strides < maximum do
                state.strideProgress = state.strideProgress - C.STRIDE_BUILD_SECONDS
                state.strides = state.strides + 1
            end
        else
            state.strideProgress = 0
        end
        return
    end

    state.strideProgress = 0
    -- Relentless: strides hold through a stop while you still have the wind.
    if enabled(C.RELENTLESS) and fatiguePercent > C.RELENTLESS_MIN_FATIGUE then
        state.strideIdleSeconds = 0
        return
    end

    state.strideIdleSeconds = state.strideIdleSeconds + elapsed
    if state.strideIdleSeconds >= C.STRIDE_DECAY_SECONDS then
        clearStrides()
    end
end

local function updateSecondWind(elapsed, fatigue, fatiguePercent, maxFatigue)
    if state.secondWindCooldown > 0 then
        state.secondWindCooldown = math.max(0, state.secondWindCooldown - elapsed)
    end

    if not enabled(C.SECOND_WIND) or state.secondWindCooldown > 0 then
        return
    end
    if fatigue == nil or maxFatigue <= 0 or fatiguePercent >= C.SECOND_WIND_TRIGGER_FATIGUE then
        return
    end

    local restored = maxFatigue * C.SECOND_WIND_RESTORE_FRACTION
    local current = tonumber(fatigue.current) or 0
    local ok = pcall(function()
        fatigue.current = math.min(maxFatigue, current + restored)
    end)
    if not ok then
        return
    end

    state.secondWindCooldown = enabled(C.PEERLESS_CONDITIONING)
        and C.SECOND_WIND_COOLDOWN_IMPROVED
        or C.SECOND_WIND_COOLDOWN
end

local function refresh(elapsed)
    elapsed = math.max(0, tonumber(elapsed) or 0)

    local fatigue = fatigueStat()
    local fatiguePercent, maxFatigue = fatigueRatio(fatigue)

    updateStrides(elapsed, fatiguePercent)
    updateSecondWind(elapsed, fatigue, fatiguePercent, maxFatigue)

    local athletics = 0
    if enabled(C.STEADY_PACE) and encumbranceRatio() < C.STEADY_PACE_MAX_LOAD then
        athletics = athletics + C.STEADY_PACE_ATHLETICS
    end
    if enabled(C.LONG_STRIDER) then
        athletics = athletics + state.strides * C.STRIDE_ATHLETICS_EACH
    end

    local endurance = 0
    if enabled(C.DEEP_LUNGS) and fatiguePercent > C.DEEP_LUNGS_MIN_FATIGUE then
        endurance = C.DEEP_LUNGS_ENDURANCE
    end

    local speed = state.strides * C.STRIDE_SPEED_EACH

    local extraFatigue = 0
    if enabled(C.PEERLESS_CONDITIONING) then
        local base = fatigue ~= nil and (tonumber(fatigue.base) or 0) or 0
        extraFatigue = math.floor(base * C.PEERLESS_FATIGUE_FRACTION)
    end

    state.appliedAthletics = setModifier(skillStat("athletics"), state.appliedAthletics, athletics)
    state.appliedEndurance = setModifier(attributeStat("endurance"), state.appliedEndurance, endurance)
    state.appliedSpeed = setModifier(attributeStat("speed"), state.appliedSpeed, speed)
    state.appliedMaxFatigue = setModifier(fatigue, state.appliedMaxFatigue, extraFatigue)
end

__basepack_subsystem_result = {
    engineHandlers = {
        -- Deliberately no per-frame path: every effect here has a granularity of
        -- seconds, so a nonzero applied bonus is not a reason to keep updating.
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
            state.lastPosition = nil
            clearStrides()
            state.secondWindCooldown = math.max(0, tonumber(data.athleticsSecondWindCooldown) or 0)
            -- Reapply what was applied at save time so the reconcile below
            -- removes exactly this subsystem's contribution and no more.
            state.appliedAthletics = math.max(0, math.floor(tonumber(data.athleticsAppliedAthletics) or 0))
            state.appliedEndurance = math.max(0, math.floor(tonumber(data.athleticsAppliedEndurance) or 0))
            state.appliedSpeed = math.max(0, math.floor(tonumber(data.athleticsAppliedSpeed) or 0))
            state.appliedMaxFatigue = math.max(0, math.floor(tonumber(data.athleticsAppliedMaxFatigue) or 0))
            refresh(0)
        end,
        onSave = function()
            return {
                athleticsSecondWindCooldown = state.secondWindCooldown,
                athleticsAppliedAthletics = state.appliedAthletics,
                athleticsAppliedEndurance = state.appliedEndurance,
                athleticsAppliedSpeed = state.appliedSpeed,
                athleticsAppliedMaxFatigue = state.appliedMaxFatigue,
            }
        end,
    },
}

return __basepack_subsystem_result
