local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")

local loadedSkills = {}

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

local function isModuleNotFound(err, moduleName)
    if type(err) ~= "string" then
        return false
    end
    return err:find("module '" .. moduleName .. "' not found", 1, true) ~= nil
end

local function requireOptional(moduleName)
    local ok, result = pcall(require, moduleName)
    if ok then
        return true, result
    end
    if isModuleNotFound(result, moduleName) then
        return false, nil
    end
    error(result, 0)
end

local function loadFolderTreeModules(baseModuleName)
    local moduleCount = 0
    local nodeCount = 0

    local listModule = baseModuleName .. ".modules"
    local listFound, list = requireOptional(listModule)
    if not listFound then
        return moduleCount, nodeCount
    end

    if type(list) ~= "table" then
        error("Tree module list must return a table: " .. listModule, 2)
    end

    for _, moduleSuffix in ipairs(list) do
        local moduleName = baseModuleName .. "." .. moduleSuffix
        local found, nodes = requireOptional(moduleName)
        if found then
            moduleCount = moduleCount + 1
            if type(nodes) == "table" then
                registerTreeNodes(nodes, moduleName)
                nodeCount = nodeCount + #nodes
            end
        end
    end

    return moduleCount, nodeCount
end

local function loadLegacyTreeModule(baseModuleName)
    local found, nodes = requireOptional(baseModuleName)
    if not found then
        return 0, 0
    end

    if type(nodes) == "table" then
        registerTreeNodes(nodes, baseModuleName)
        return 1, #nodes
    end

    return 1, 0
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
            local baseModule = "scripts.SkillPerkSystem.trees." .. candidate

            local folderModulesLoaded, folderNodesLoaded = loadFolderTreeModules(baseModule)
            local modulesLoaded = folderModulesLoaded
            local nodesLoaded = folderNodesLoaded

            if modulesLoaded == 0 then
                local legacyModulesLoaded, legacyNodesLoaded = loadLegacyTreeModule(baseModule)
                modulesLoaded = modulesLoaded + legacyModulesLoaded
                nodesLoaded = nodesLoaded + legacyNodesLoaded
            end

            if modulesLoaded > 0 then
                print(
                    "[SkillPerkSystem] Loaded tree skill '"
                        .. skillString
                        .. "' via "
                        .. modulesLoaded
                        .. " module(s), registered "
                        .. nodesLoaded
                        .. " node(s)."
                )
                return
            end
        end
    end

    print("[SkillPerkSystem] No tree file loaded for skill id '" .. skillString .. "' (checked folder and legacy module variants)")
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
