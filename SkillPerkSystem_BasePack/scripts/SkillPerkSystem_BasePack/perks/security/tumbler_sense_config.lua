local interfaces = require("openmw.interfaces")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TUMBLER_SENSE_PERK_ID = "security_tumbler_sense"
local PERFECT_PRESSURE_PERK_ID = "security_perfect_pressure"

local BASE_BONUS_PER_FAILED_ATTEMPT = 1
local BASE_MAX_STACKS = 5
local BOOSTED_BONUS_PER_FAILED_ATTEMPT = 2
local BOOSTED_MAX_STACKS = 10
local SHARED_DECAY_SECONDS = 10
local INITIAL_STACKS = 1

local function isPerkActive(playerApi, perkID)
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function buildPayload()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    local tumblerSenseActive = isPerkActive(playerApi, TUMBLER_SENSE_PERK_ID)
    local perfectPressureActive = isPerkActive(playerApi, PERFECT_PRESSURE_PERK_ID)
    local boosted = tumblerSenseActive and perfectPressureActive

    return {
        enable = tumblerSenseActive,
        bonusPerFailedAttempt = boosted and BOOSTED_BONUS_PER_FAILED_ATTEMPT or BASE_BONUS_PER_FAILED_ATTEMPT,
        maxStacks = boosted and BOOSTED_MAX_STACKS or BASE_MAX_STACKS,
        initialStacks = INITIAL_STACKS,
        sharedDecaySeconds = SHARED_DECAY_SECONDS,
    }
end

return {
    buildPayload = buildPayload,
}
