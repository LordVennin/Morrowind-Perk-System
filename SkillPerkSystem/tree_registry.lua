local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")

local function registerTreeNode(node, source)
    pluginAPI.registerTreeNode(node, source)
end

local function registerTreeNodes(nodes, source)
    if type(nodes) ~= "table" then
        error("registerTreeNodes() expects a list", 2)
    end
    for _, node in ipairs(nodes) do
        registerTreeNode(node, source)
    end
end

local function loadTabTree(tabID)
    return registryState.getTreeNodesForTab(tabID)
end

local function getTreeNode(nodeID)
    return registryState.getTreeNode(nodeID)
end

local function getTreeNodesForTab(tabID)
    local nodes = registryState.getTreeNodesForTab(tabID)
    local out = {}
    for _, node in ipairs(nodes) do
        table.insert(out, node)
    end
    table.sort(out, function(a, b)
        if a.y ~= b.y then
            return a.y < b.y
        end
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.id < b.id
    end)
    return out
end

return {
    registerTreeNode = registerTreeNode,
    registerTreeNodes = registerTreeNodes,
    getTreeNode = getTreeNode,
    getTreeNodesForTab = getTreeNodesForTab,
    getTreeNodesForSkill = getTreeNodesForTab,
    loadTabTree = loadTabTree,
    loadSkillTree = loadTabTree,
}
