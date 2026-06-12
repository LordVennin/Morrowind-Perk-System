local state = {
    perksByID = {},
    perkIDs = {},
    perkSourceByID = {},
    treeNodesByTab = {},
    treeNodeByID = {},
    treeNodeSourceByID = {},
    tabDisplayNames = {},
    tabDescriptions = {},
    tabIDs = {},
    pointSourcesByID = {},
}

local function ensureTab(tabID, tabName, tabDescription)
    if state.tabDisplayNames[tabID] == nil then
        state.tabDisplayNames[tabID] = tabName or tabID
        table.insert(state.tabIDs, tabID)
        table.sort(state.tabIDs)
    end
    if state.tabDescriptions[tabID] == nil and type(tabDescription) == "string" and tabDescription ~= "" then
        state.tabDescriptions[tabID] = tabDescription
    end
end

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
    ensureTab(perk.tab, perk.tabName, perk.tabDescription)
    return true, previousSource
end

local function registerTreeNode(node, source, allowOverwrite)
    local previousSource = state.treeNodeSourceByID[node.id]
    local previousNode = state.treeNodeByID[node.id]
    if previousNode ~= nil and not allowOverwrite then
        return false, previousSource
    end

    if previousNode ~= nil then
        local previousTabNodes = state.treeNodesByTab[previousNode.tab] or {}
        for i, existingNode in ipairs(previousTabNodes) do
            if existingNode.id == node.id then
                table.remove(previousTabNodes, i)
                break
            end
        end
    end

    state.treeNodeByID[node.id] = node
    state.treeNodeSourceByID[node.id] = source
    ensureTab(node.tab, node.tabName, node.tabDescription)
    state.treeNodesByTab[node.tab] = state.treeNodesByTab[node.tab] or {}
    table.insert(state.treeNodesByTab[node.tab], node)
    return true, previousSource
end

local function getTreeNodesForTab(tabID)
    return state.treeNodesByTab[tabID] or {}
end

local function registerPointSource(sourceId, handlers, source)
    state.pointSourcesByID[sourceId] = {
        id = sourceId,
        handlers = handlers,
        source = source,
    }
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
    getTreeNodes = function()
        return state.treeNodeByID
    end,
    getTreeNode = function(nodeID)
        return state.treeNodeByID[nodeID]
    end,
    getTreeNodeSource = function(nodeID)
        return state.treeNodeSourceByID[nodeID]
    end,
    getTreeNodesForTab = getTreeNodesForTab,
    getTreeNodesForSkill = getTreeNodesForTab,
    getTabIDs = function()
        return state.tabIDs
    end,
    getTabLabel = function(tabID)
        return state.tabDisplayNames[tabID]
    end,
    getTabDescription = function(tabID)
        return state.tabDescriptions[tabID]
    end,
    registerPointSource = registerPointSource,
    getPointSources = function()
        return state.pointSourcesByID
    end,
}
