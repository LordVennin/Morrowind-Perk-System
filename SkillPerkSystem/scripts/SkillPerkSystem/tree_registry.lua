local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")

local loadedSkills = {}

local function registerTreeNode(node)
    pluginAPI.registerTreeNode(node)
end

local function registerTreeNodes(nodes)
    if type(nodes) ~= "table" then
        error("registerTreeNodes() expects a list", 2)
    end
    for _, node in ipairs(nodes) do
        registerTreeNode(node)
    end
end

local function loadSkillTree(skillID)
    if loadedSkills[skillID] then
        return
    end
    loadedSkills[skillID] = true

    local skillString = tostring(skillID)
    local normalized = skillString:lower()
    local candidates = {
        normalized,
        normalized:gsub("%s+", ""),
        normalized:gsub("%s+", "_"),
        normalized:gsub("%s+", "-"),
    }

    local tried = {}
    for _, candidate in ipairs(candidates) do
        if candidate ~= "" and not tried[candidate] then
            tried[candidate] = true
            local moduleName = "scripts.SkillPerkSystem.trees." .. candidate
            local ok, result = pcall(require, moduleName)
            if ok then
                if type(result) == "table" then
                    registerTreeNodes(result)
                end
                return
            end
        end
    end

    print("[SkillPerkSystem] No tree file loaded for skill id '" .. skillString .. "' (checked normalized filename variants)")
end

local function getTreeNode(nodeID)
    return registryState.getTreeNode(nodeID)
end

local function getTreeNodesForSkill(skillID)
    loadSkillTree(skillID)
    local nodes = registryState.getTreeNodesForSkill(skillID)
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
    getTreeNodesForSkill = getTreeNodesForSkill,
    loadSkillTree = loadSkillTree,
}
