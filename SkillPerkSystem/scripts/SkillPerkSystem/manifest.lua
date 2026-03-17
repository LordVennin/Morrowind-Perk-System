local core = require("openmw.core")
local settings = require("scripts.SkillPerkSystem.settings")
local treeRegistry = require("scripts.SkillPerkSystem.tree_registry")
local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local pluginLoader = require("scripts.SkillPerkSystem.plugin_loader")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local builtinManifest = require("scripts.SkillPerkSystemBuiltin.skillperk_manifest")

local SOURCE_MANIFEST = "scripts.SkillPerkSystem.manifest"

local function registerPerk(data)
    return pluginAPI.registerPerk(data, SOURCE_MANIFEST)
end

local function registerTreeNode(data)
    return pluginAPI.registerTreeNode(data, SOURCE_MANIFEST)
end

local function registerEffect(data)
    return pluginAPI.registerEffect(data, SOURCE_MANIFEST)
end

local function registerBuiltinContent()
    if type(builtinManifest) ~= "table" or type(builtinManifest.register) ~= "function" then
        return
    end

    local sourceAwareAPI = {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = function(data)
            return pluginAPI.registerPerk(data, "scripts.SkillPerkSystemBuiltin.skillperk_manifest")
        end,
        registerTreeNode = function(data)
            return pluginAPI.registerTreeNode(data, "scripts.SkillPerkSystemBuiltin.skillperk_manifest")
        end,
        registerEffect = function(data)
            return pluginAPI.registerEffect(data, "scripts.SkillPerkSystemBuiltin.skillperk_manifest")
        end,
        registerPointSource = function(sourceId, handlers)
            return pluginAPI.registerPointSource(sourceId, handlers, "scripts.SkillPerkSystemBuiltin.skillperk_manifest")
        end,
    }

    builtinManifest.register(sourceAwareAPI)
end

registerBuiltinContent()
local pluginValidationReport = pluginLoader.loadInstalledPacks(pluginAPI)

local function buildPluginValidationSummary(report)
    local packs = (type(report) == "table" and type(report.packs) == "table") and report.packs or {}
    local totalPacksDetected = (type(report) == "table" and type(report.totalPacksDetected) == "number") and report.totalPacksDetected
        or #packs

    local loadedSuccessfully = 0
    local failedOrSkipped = 0

    for _, packReport in ipairs(packs) do
        if packReport.status == "loaded" then
            loadedSuccessfully = loadedSuccessfully + 1
        else
            failedOrSkipped = failedOrSkipped + 1
        end
    end

    print(
        "["
            .. settings.MOD_NAME
            .. "] plugin validation summary: packs="
            .. tostring(totalPacksDetected)
            .. " loaded="
            .. tostring(loadedSuccessfully)
            .. " failed_or_skipped="
            .. tostring(failedOrSkipped)
    )

    for _, packReport in ipairs(packs) do
        if packReport.status ~= "loaded" then
            print(
                "["
                    .. settings.MOD_NAME
                    .. "] plugin validation issue: pack='"
                    .. tostring(packReport.packName)
                    .. "' status='"
                    .. tostring(packReport.status)
                    .. "' reason='"
                    .. tostring(packReport.reason)
                    .. "'"
            )
        end
    end

    if settings.PLUGIN_VALIDATION_VERBOSE then
        for _, packReport in ipairs(packs) do
            print(
                "["
                    .. settings.MOD_NAME
                    .. "] plugin report: pack='"
                    .. tostring(packReport.packName)
                    .. "' status='"
                    .. tostring(packReport.status)
                    .. "' manifest_found="
                    .. tostring(packReport.manifest and packReport.manifest.found)
                    .. " register_success="
                    .. tostring(packReport.manifest and packReport.manifest.registerSuccess)
                    .. " modules_attempted="
                    .. tostring(packReport.modulesAttemptedCount)
                    .. " modules_loaded="
                    .. tostring(packReport.modulesLoadedCount)
                    .. " failures="
                    .. tostring(#packReport.moduleFailures)
            )

            for _, failure in ipairs(packReport.moduleFailures) do
                print(
                    "["
                        .. settings.MOD_NAME
                        .. "] plugin report detail: pack='"
                        .. tostring(packReport.packName)
                        .. "' class='"
                        .. tostring(failure.class)
                        .. "' module='"
                        .. tostring(failure.module)
                        .. "' reason='"
                        .. tostring(failure.reason)
                        .. "'"
                )
            end
        end
    end
end

local function getPerks()
    return registryState.getPerks()
end

local function getPerkIDs()
    return registryState.getPerkIDs()
end

local function getPerkIDsForSkill(skillID)
    local out = {}
    for _, id in ipairs(registryState.getPerkIDs()) do
        if registryState.getPerks()[id].skill == skillID then
            table.insert(out, id)
        end
    end
    return out
end

local function buildStartupSummary()
    local skillSummaries = {}
    local allSkills = core.stats and core.stats.Skill and core.stats.Skill.records

    if type(allSkills) == "table" then
        for _, skillRecord in pairs(allSkills) do
            local skillID = type(skillRecord) == "table" and skillRecord.id or skillRecord
            if type(skillID) == "string" and skillID ~= "" then
                local perkCount = 0
                for _, perkID in ipairs(registryState.getPerkIDs()) do
                    local perk = registryState.getPerks()[perkID]
                    if perk and perk.skill == skillID then
                        perkCount = perkCount + 1
                    end
                end

                local nodes = treeRegistry.getTreeNodesForSkill(skillID)
                local nodeCount = #nodes

                if perkCount > 0 or nodeCount > 0 then
                    table.insert(
                        skillSummaries,
                        skillID .. "{perks=" .. tostring(perkCount) .. ",nodes=" .. tostring(nodeCount) .. "}"
                    )
                end
            end
        end
    end

    table.sort(skillSummaries)
    local effectCount = 0
    for _ in pairs(effectsRegistry.getEffects()) do
        effectCount = effectCount + 1
    end

    print(
        "["
            .. settings.MOD_NAME
            .. "] startup registry summary: skills="
            .. tostring(#skillSummaries)
            .. " effects="
            .. tostring(effectCount)
            .. " details=["
            .. table.concat(skillSummaries, ", ")
            .. "]"
    )
end

buildStartupSummary()
buildPluginValidationSummary(pluginValidationReport)

return {
    interfaceName = settings.MOD_NAME,
    interface = {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = registerPerk,
        registerTreeNode = registerTreeNode,
        registerEffect = registerEffect,
        registerPointSource = pluginAPI.registerPointSource,
        getPerks = getPerks,
        getPerkIDs = getPerkIDs,
        getPerkIDsForSkill = getPerkIDsForSkill,
        registerTreeNodes = treeRegistry.registerTreeNodes,
        getTreeNode = treeRegistry.getTreeNode,
        getTreeNodesForSkill = treeRegistry.getTreeNodesForSkill,
        loadSkillTree = treeRegistry.loadSkillTree,
    }
}
