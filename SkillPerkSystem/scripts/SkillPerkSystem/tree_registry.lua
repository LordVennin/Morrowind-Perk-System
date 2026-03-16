local core = require("openmw.core")

local loadedSkills = {}
local treeNodesBySkill = {}
local treeNodeByID = {}

local function hasSkillRecord(skillID)
    if core.stats.Skill.records[skillID] ~= nil then
        return true
    end
    for _, record in ipairs(core.stats.Skill.records) do
        if record.id == skillID then
            return true
        end
    end
    return false
end


local function validateNode(data)
    if type(data) ~= "table" then
        error("registerTreeNode() expects a table", 3)
    end
    if type(data.id) ~= "string" or data.id == "" then
        error("registerTreeNode() missing string field 'id'", 3)
    end
    if type(data.skill) ~= "string" or not hasSkillRecord(data.skill) then
        error("registerTreeNode(" .. tostring(data.id) .. ") has invalid field 'skill'", 3)
    end
    if type(data.x) ~= "number" or type(data.y) ~= "number" then
        error("registerTreeNode(" .. tostring(data.id) .. ") requires numeric fields 'x' and 'y'", 3)
    end

    if data.requires == nil then
        data.requires = {}
    end
    if type(data.requires) ~= "table" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'requires' must be a list", 3)
    end
    for i, req in ipairs(data.requires) do
        if type(req) ~= "string" then
            error("registerTreeNode(" .. tostring(data.id) .. ") requires[" .. tostring(i) .. "] must be a string", 3)
        end
    end

    if data.title == nil then
        data.title = data.id
    end
    if type(data.title) ~= "string" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'title' must be a string", 3)
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        error("registerTreeNode(" .. tostring(data.id) .. ") field 'description' must be a string", 3)
    end

    return data
end

local function registerTreeNode(node)
    node = validateNode(node)

    if treeNodeByID[node.id] ~= nil then
        error("registerTreeNode() duplicate node id: " .. tostring(node.id), 2)
    end

    treeNodeByID[node.id] = node
    treeNodesBySkill[node.skill] = treeNodesBySkill[node.skill] or {}
    table.insert(treeNodesBySkill[node.skill], node)
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

    -- Optional tree files are expected; only log once per skill for easier debugging.
    print("[SkillPerkSystem] No tree file loaded for skill id '" .. skillString .. "' (checked normalized filename variants)")
end

local function getTreeNode(nodeID)
    return treeNodeByID[nodeID]
end

local function getTreeNodesForSkill(skillID)
    loadSkillTree(skillID)
    local nodes = treeNodesBySkill[skillID] or {}
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
