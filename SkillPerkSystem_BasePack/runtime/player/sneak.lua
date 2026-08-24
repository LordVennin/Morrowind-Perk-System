-- Sneak player runtime for SkillPerkSystem_BasePack.
--
-- The whole tree is conditional rather than stacking: bonuses depend on whether
-- the player is sneaking, holding still, carrying a light, and how loaded they
-- are. All four are cheap reads, so this subsystem is a plain 0.5 second poll
-- with no per-frame path.

local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local C = {
    SOFT_BOOTS = "sneak_soft_boots",
    PATIENT_SHADOW = "sneak_patient_shadow",
    MOONLESS_NIGHT = "sneak_moonless_night",
    CUTPURSE_POISE = "sneak_cutpurse_poise",
    FEATHER_TREAD = "sneak_feather_tread",
    ONE_WITH_SHADOW = "sneak_one_with_shadow",
    KILLERS_INSTINCT = "sneak_killers_instinct",
    KNIFE_IN_THE_DARK = "sneak_knife_in_the_dark",
    LIGHT_FINGERS = "sneak_light_fingers",

    CRIT_STATE_EVENT = "SkillPerkSystem_SneakCritState",
    PICKPOCKET_CLOSE_EVENT = "SkillPerkSystem_BasePack_LightFingers_Close",
    SHADOW_SET_EVENT = "SkillPerkSystem_BasePack_OneWithShadow_Set",

    POLL_INTERVAL = 0.5,

    SOFT_BOOTS_SNEAK = 10,
    LIGHT_LOAD_MAX = 1 / 3,

    PATIENT_SHADOW_SNEAK = 10,
    -- Squared; large enough that idle animation does not read as movement.
    STILL_EPSILON_SQUARED = 64,
    -- A jump this large in one poll is a teleport, which should not count as
    -- holding still either.
    TELEPORT_EPSILON_SQUARED = 4000000,

    MOONLESS_SNEAK = 10,

    CUTPURSE_SECURITY = 10,
    CUTPURSE_AGILITY = 10,

    FEATHER_TREAD_SPEED = 15,

}

local state = {
    pollTimer = C.POLL_INTERVAL,
    lastPosition = nil,
    appliedSneak = 0,
    appliedAgility = 0,
    appliedSpeed = 0,
    appliedSecurity = 0,
    lastCritStateKey = nil,
    lastShadowActive = nil,
}

-- A lit torch or lamp in hand defeats sneaking, thematically and mechanically.
local function holdingLight()
    return stats.equippedInSlot("CarriedLeft", function(item)
        return types.Light ~= nil and type(types.Light.objectIsInstance) == "function"
            and types.Light.objectIsInstance(item)
    end)
end

local function holdingStill()
    local position = stats.position()
    if position == nil then
        return false
    end
    local distanceSquared = stats.distanceSquared(position, state.lastPosition)
    state.lastPosition = position
    if distanceSquared == nil or distanceSquared >= C.TELEPORT_EPSILON_SQUARED then
        return false
    end
    return distanceSquared <= C.STILL_EPSILON_SQUARED
end

-- The sneak-attack damage bonus is applied target-side (the target script owns
-- the hit's damage table), so the crit perks and current sneak state are
-- published to the global script whenever they change. The 0.5s poll bounds the
-- staleness of the sneaking flag at hit time.
local function publishCritState(sneaking)
    local killers = enabled(C.KILLERS_INSTINCT)
    local knife = enabled(C.KNIFE_IN_THE_DARK)
    local lightFingers = enabled(C.LIGHT_FINGERS)
    local stateKey = tostring(killers) .. ":" .. tostring(knife) .. ":"
        .. tostring(lightFingers) .. ":" .. tostring(sneaking)
    if stateKey == state.lastCritStateKey then
        return
    end
    state.lastCritStateKey = stateKey
    core.sendGlobalEvent(C.CRIT_STATE_EVENT, {
        playerId = pself.id,
        killersInstinctEnabled = killers,
        knifeInTheDarkEnabled = knife,
        lightFingersEnabled = lightFingers,
        sneaking = sneaking,
    })
end

-- One With Shadow: the Chameleon ability record is dynamic, so the global
-- script owns creating it and adding/removing it from the player; this side
-- only reports whether the capstone's conditions hold.
local function publishShadowState(active)
    if active == state.lastShadowActive then
        return
    end
    state.lastShadowActive = active
    core.sendGlobalEvent(C.SHADOW_SET_EVENT, { player = pself, active = active })
end

local function refresh()
    local sneaking = stats.isSneaking()
    local still = holdingStill()
    local lightLoad = stats.encumbranceRatio() < C.LIGHT_LOAD_MAX
    local dark = sneaking and not holdingLight()

    local sneak = 0
    local agility = 0
    local speed = 0
    local security = 0

    if enabled(C.SOFT_BOOTS) and lightLoad then
        sneak = sneak + C.SOFT_BOOTS_SNEAK
    end
    if enabled(C.PATIENT_SHADOW) and sneaking and still then
        sneak = sneak + C.PATIENT_SHADOW_SNEAK
    end
    if enabled(C.MOONLESS_NIGHT) and dark then
        sneak = sneak + C.MOONLESS_SNEAK
    end
    if enabled(C.CUTPURSE_POISE) and sneaking then
        security = security + C.CUTPURSE_SECURITY
        agility = agility + C.CUTPURSE_AGILITY
    end
    if enabled(C.FEATHER_TREAD) and sneaking then
        speed = speed + C.FEATHER_TREAD_SPEED
    end
    publishCritState(sneaking)
    publishShadowState(enabled(C.ONE_WITH_SHADOW) and dark and lightLoad)

    state.appliedSneak = setModifier(stats.skillStat("sneak"), state.appliedSneak, sneak)
    state.appliedSecurity = setModifier(stats.skillStat("security"), state.appliedSecurity, security)
    state.appliedAgility = setModifier(stats.attributeStat("agility"), state.appliedAgility, agility)
    state.appliedSpeed = setModifier(stats.attributeStat("speed"), state.appliedSpeed, speed)
end

-- The pickpocket window is a paused Container UI mode. Its drain is applied
-- by the global script when the sneaking player activates the NPC (before the
-- pause); leaving Container mode -- or landing in Dialogue instead, when the
-- mark noticed the approach -- is when the drain should lift.
local function onUiModeChanged(data)
    if type(data) ~= "table" then
        return
    end
    if data.oldMode == "Container" or data.newMode == "Dialogue" then
        core.sendGlobalEvent(C.PICKPOCKET_CLOSE_EVENT, { player = pself })
    end
end

__basepack_subsystem_result = {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
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
            state.lastPosition = nil
            state.lastCritStateKey = nil
            state.lastShadowActive = nil
            state.appliedSneak = math.max(0, math.floor(tonumber(data.sneakAppliedSneak) or 0))
            state.appliedSecurity = math.max(0, math.floor(tonumber(data.sneakAppliedSecurity) or 0))
            state.appliedAgility = math.max(0, math.floor(tonumber(data.sneakAppliedAgility) or 0))
            state.appliedSpeed = math.max(0, math.floor(tonumber(data.sneakAppliedSpeed) or 0))
            refresh()
        end,
        onSave = function()
            return {
                sneakAppliedSneak = state.appliedSneak,
                sneakAppliedSecurity = state.appliedSecurity,
                sneakAppliedAgility = state.appliedAgility,
                sneakAppliedSpeed = state.appliedSpeed,
            }
        end,
    },
}

return __basepack_subsystem_result
