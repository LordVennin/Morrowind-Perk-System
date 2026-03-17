local core = require("openmw.core")
local settings = require("scripts.SkillPerkSystem.settings")
local treeRegistry = require("scripts.SkillPerkSystem.tree_registry")
local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local pluginLoader = require("scripts.SkillPerkSystem.plugin_loader")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local demoPerks = require("scripts.SkillPerkSystem.test_perks")

local SOURCE_MANIFEST = "scripts.SkillPerkSystem.manifest"
local SOURCE_DEMO = "scripts.SkillPerkSystem.test_perks"

local function registerPerk(data)
    return pluginAPI.registerPerk(data, SOURCE_MANIFEST)
end

local function registerTreeNode(data)
    return pluginAPI.registerTreeNode(data, SOURCE_MANIFEST)
end

local function registerEffect(data)
    return pluginAPI.registerEffect(data, SOURCE_MANIFEST)
end

demoPerks.registerDemoPerks(registerPerk, SOURCE_DEMO)
pluginLoader.loadInstalledPacks(pluginAPI)

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
