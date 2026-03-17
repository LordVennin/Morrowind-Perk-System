local state = {
    perksByID = {},
    perkIDs = {},
    perkSourceByID = {},
    treeNodesBySkill = {},
    treeNodeByID = {},
    treeNodeSourceByID = {},
    pointSourcesByID = {},
}

local function registerPerk(perk, source, allowOverwrite)
    local previousSource = state.perkSourceByID[perk.id]
    if previousSource ~= nil and not allowOverwrite then
        return false, previousSource
    end

    if state.perksByID[perk.id] == nil then
        table.insert(state.perkIDs, perk.id)
    end

    state.perksByID[perk.id] = perk
    state.perkSourceByID[perk.id] = source
    return true, previousSource
end

local function registerTreeNode(node, source, allowOverwrite)
    local previousSource = state.treeNodeSourceByID[node.id]
    local previousNode = state.treeNodeByID[node.id]
    if previousNode ~= nil and not allowOverwrite then
        return false, previousSource
    end

    if previousNode ~= nil then
        local previousSkillNodes = state.treeNodesBySkill[previousNode.skill] or {}
        for i, existingNode in ipairs(previousSkillNodes) do
            if existingNode.id == node.id then
                table.remove(previousSkillNodes, i)
                break
            end
        end
    end

    state.treeNodeByID[node.id] = node
    state.treeNodeSourceByID[node.id] = source
    state.treeNodesBySkill[node.skill] = state.treeNodesBySkill[node.skill] or {}
    table.insert(state.treeNodesBySkill[node.skill], node)
    return true, previousSource
end

local function getTreeNodesForSkill(skillID)
    return state.treeNodesBySkill[skillID] or {}
end

local function registerPointSource(source)
    state.pointSourcesByID[source.id] = source
end

return {
    registerPerk = registerPerk,
    getPerks = function()
        return state.perksByID
    end,
    getPerkIDs = function()
        return state.perkIDs
    end,
    getPerkSource = function(perkID)
        return state.perkSourceByID[perkID]
    end,
    registerTreeNode = registerTreeNode,
    getTreeNode = function(nodeID)
        return state.treeNodeByID[nodeID]
    end,
    getTreeNodeSource = function(nodeID)
        return state.treeNodeSourceByID[nodeID]
    end,
    getTreeNodesForSkill = getTreeNodesForSkill,
    registerPointSource = registerPointSource,
    getPointSources = function()
        return state.pointSourcesByID
    end,
}
