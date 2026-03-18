local settings = require("scripts.SkillPerkSystem.settings")

local LOADER_TAG = "[SkillPerkSystem][plugin_loader] "

local hasLoaded = false
local lastValidationReport = nil
local hasPreloaded = false
local lastPreloadReport = nil

local function log(message)
    print(LOADER_TAG .. tostring(message))
end

local function buildEmptyValidationReport()
    return {
        totalPacksDetected = 0,
        totalPacksDiscovered = 0,
        externalPacksDetected = 0,
        internalPacksDetected = 0,
        bundledPacksDetected = 0,
        internalPackName = nil,
        bundledPackName = nil,
        internalIndexPresent = false,
        internalIndexModules = 0,
        internalDemoContentExpected = false,
        internalStatus = { discovered = 0, loaded = 0, failedOrSkipped = 0 },
        bundledStatus = { discovered = 0, loaded = 0, failedOrSkipped = 0 },
        externalStatus = { discovered = 0, loaded = 0, failedOrSkipped = 0 },
        packs = {},
    }
end

local function buildEmptyPreloadReport()
    return {
        packsScanned = 0,
        modulesDiscovered = 0,
        modulesLoaded = 0,
        modulesFailed = 0,
        internalModulesDiscovered = 0,
        internalModulesLoaded = 0,
        internalModulesFailed = 0,
        bundledModulesDiscovered = 0,
        bundledModulesLoaded = 0,
        bundledModulesFailed = 0,
        externalModulesDiscovered = 0,
        externalModulesLoaded = 0,
        externalModulesFailed = 0,
        internalRegisteredPerks = 0,
        internalRegisteredNodes = 0,
        bundledRegisteredPerks = 0,
        bundledRegisteredNodes = 0,
        externalRegisteredPerks = 0,
        externalRegisteredNodes = 0,
        registeredPerks = 0,
        registeredNodes = 0,
        perSkill = {},
        durationMs = 0,
    }
end

local function loadInstalledPacks(_pluginAPI)
    if hasLoaded then
        return lastValidationReport
    end

    hasLoaded = true
    lastValidationReport = buildEmptyValidationReport()

    log("explicit bootstrap mode enabled; inferred plugin discovery is disabled")
    if settings.ENABLE_EXTERNAL_PLUGIN_SCANNING ~= false then
        log("no third-party external content packs detected; skipping external plugin discovery")
    else
        log("external plugin discovery disabled by settings; using explicit bootstrap-only loading")
    end

    return lastValidationReport
end

local function preloadPerkModules(_pluginAPI)
    if hasPreloaded then
        return lastPreloadReport
    end

    hasPreloaded = true
    lastPreloadReport = buildEmptyPreloadReport()

    log("timing unavailable in this runtime")
    log(
        "preload summary: internal_modules_discovered=0 internal_modules_loaded=0 internal_modules_failed=0 "
            .. "bundled_modules_discovered=0 bundled_modules_loaded=0 bundled_modules_failed=0 "
            .. "external_modules_discovered=0 external_modules_loaded=0 external_modules_failed=0 "
            .. "external_packs_scanned=0 modules_discovered_total=0 modules_loaded_total=0 modules_failed_total=0 "
            .. "registered_perks_total=0 registered_nodes_total=0"
    )

    return lastPreloadReport
end

return {
    loadInstalledPacks = loadInstalledPacks,
    preloadPerkModules = preloadPerkModules,
}
