local state = {
    perksByID = {},
    perkIDs = {},
    treeNodesBySkill = {},
    treeNodeByID = {},
    effectsByID = {},
    pointSourcesByID = {},
}

local function upsertPerk(perk)
    if state.perksByID[perk.id] == nil then
        table.insert(state.perkIDs, perk.id)
    end
    state.perksByID[perk.id] = perk
end

local function addTreeNode(node)
    if state.treeNodeByID[node.id] ~= nil then
        return false
    end
    state.treeNodeByID[node.id] = node
    state.treeNodesBySkill[node.skill] = state.treeNodesBySkill[node.skill] or {}
    table.insert(state.treeNodesBySkill[node.skill], node)
    return true
end

local function getTreeNodesForSkill(skillID)
    return state.treeNodesBySkill[skillID] or {}
end

local function registerEffect(effect)
    state.effectsByID[effect.id] = effect
end

local function registerPointSource(source)
    state.pointSourcesByID[source.id] = source
end

return {
    upsertPerk = upsertPerk,
    getPerks = function()
        return state.perksByID
    end,
    getPerkIDs = function()
        return state.perkIDs
    end,
    addTreeNode = addTreeNode,
    getTreeNode = function(nodeID)
        return state.treeNodeByID[nodeID]
    end,
    getTreeNodesForSkill = getTreeNodesForSkill,
    registerEffect = registerEffect,
    getEffects = function()
        return state.effectsByID
    end,
    registerPointSource = registerPointSource,
    getPointSources = function()
        return state.pointSourcesByID
    end,
}
