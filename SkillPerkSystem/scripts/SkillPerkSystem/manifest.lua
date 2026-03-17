local settings = require("scripts.SkillPerkSystem.settings")
local treeRegistry = require("scripts.SkillPerkSystem.tree_registry")
local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local demoPerks = require("scripts.SkillPerkSystem.test_perks")

demoPerks.registerDemoPerks(pluginAPI.registerPerk)

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

return {
    interfaceName = settings.MOD_NAME,
    interface = {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = pluginAPI.registerPerk,
        registerTreeNode = pluginAPI.registerTreeNode,
        registerEffect = pluginAPI.registerEffect,
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
