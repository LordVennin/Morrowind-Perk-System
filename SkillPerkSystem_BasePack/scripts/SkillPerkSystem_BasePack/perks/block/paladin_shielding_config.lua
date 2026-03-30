local storage = require("openmw.storage")

local CONFIG_SECTION_ID = "SkillPerkSystem_BasePack_BlockPaladin"

local KEYS = {
    debugLogging = "block.paladin.debug",
    passiveMagicResist = "block.paladin.passive_magic_resist",
    wardDurationSeconds = "block.paladin.ward_duration_seconds",
    wardAbsorbPercent = "block.paladin.ward_absorb_percent",
    reflectionChance = "block.paladin.reflection_chance",
    reflectionPercent = "block.paladin.reflection_percent",
    supportPulseHeal = "block.paladin.support_pulse_heal",
    supportPulseCooldownSeconds = "block.paladin.support_pulse_cooldown_seconds",
}

local DEFAULTS = {
    debugLogging = false,
    passiveMagicResist = 0.10,
    wardDurationSeconds = 2.0,
    wardAbsorbPercent = 0.08,
    reflectionChance = 0.12,
    reflectionPercent = 0.20,
    supportPulseHeal = 4.0,
    supportPulseCooldownSeconds = 8.0,
}

local function section()
    return storage.playerSection(CONFIG_SECTION_ID)
end

local function initializeDefaults()
    local config = section()
    for key, _ in pairs(DEFAULTS) do
        local valueKey = KEYS[key]
        if valueKey ~= nil and config:get(valueKey) == nil then
            config:set(valueKey, DEFAULTS[key])
        end
    end
end

return {
    CONFIG_SECTION_ID = CONFIG_SECTION_ID,
    KEYS = KEYS,
    DEFAULTS = DEFAULTS,
    section = section,
    initializeDefaults = initializeDefaults,
}
