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

local function hasRegisteredPerksForSkill(skillID)
    local perksById = registryState.getPerks()
    for _, perkID in ipairs(registryState.getPerkIDs()) do
        local perk = perksById[perkID]
        if type(perk) == "table" and perk.skill == skillID then
            return true
        end
    end
    return false
end

local function loadSkillTree(skillID)
    if loadedSkills[skillID] then
        return
    end

    local alreadyRegisteredNodes = registryState.getTreeNodesForSkill(skillID)
    if type(alreadyRegisteredNodes) == "table" and #alreadyRegisteredNodes > 0 then
        loadedSkills[skillID] = true
        return
    end

    if hasRegisteredPerksForSkill(skillID) then
        loadedSkills[skillID] = true
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
            local moduleName = "scripts.SkillPerkSystem.perks." .. candidate
            local found, perkModule = requireOptional(moduleName)
            if found then
                local result = pluginAPI.registerPerkModule(perkModule, moduleName, skillString)
                print(
                    "[SkillPerkSystem] Loaded perk skill module '"
                        .. skillString
                        .. "' via "
                        .. moduleName
                        .. " perks="
                        .. tostring(result and result.perks or 0)
                        .. " nodes="
                        .. tostring(result and result.nodes or 0)
                )
                return
            end
        end
    end

    print("[SkillPerkSystem] No perks module loaded for skill id '" .. skillString .. "'")
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
