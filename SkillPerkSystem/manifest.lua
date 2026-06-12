local settings = require("scripts.SkillPerkSystem.settings")
local treeRegistry = require("scripts.SkillPerkSystem.tree_registry")
local pluginAPI = require("scripts.SkillPerkSystem.plugin_api")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local packRegistry = require("scripts.SkillPerkSystem.plugin_loader")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")

local SOURCE_MANIFEST = "scripts.SkillPerkSystem.manifest"
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

print("[" .. settings.MOD_NAME .. "] framework .omwscripts PLAYER manifest loaded")
settings.init()

packRegistry.beginFramework()

local function registerPerk(data, source)
    return pluginAPI.registerPerk(data, source or SOURCE_MANIFEST)
end

local function registerTreeNode(data, source)
    return pluginAPI.registerTreeNode(data, source or SOURCE_MANIFEST)
end

local function registerPerkModule(data, expectedTab, source)
    return pluginAPI.registerPerkModule(data, source or SOURCE_MANIFEST, expectedTab)
end

local function registerEffect(data, source)
    return pluginAPI.registerEffect(data, source or SOURCE_MANIFEST)
end

local function registerPointSource(sourceId, handlers, source)
    return pluginAPI.registerPointSource(sourceId, handlers, source or SOURCE_MANIFEST)
end

local function applyEffectOnAcquire(effectID, context)
    return effectsRegistry.onAcquire(effectID, context)
end

local function applyEffectOnRemove(effectID, context)
    return effectsRegistry.onRemove(effectID, context)
end

local function validationError(message)
    error(VALIDATION_ERROR_TAG .. ": " .. tostring(message), 2)
end

local function formatCycleChain(chain)
    local labels = {}
    for _, entry in ipairs(chain) do
        local source = registryState.getTreeNodeSource(entry) or "unknown"
        table.insert(labels, tostring(entry) .. "(" .. tostring(source) .. ")")
    end
    return table.concat(labels, " -> ")
end

local function validateMergedTreeGraph()
    local nodeByID = registryState.getTreeNodes()

    local missingParents = {}
    for nodeID, node in pairs(nodeByID) do
        local source = registryState.getTreeNodeSource(nodeID) or "unknown"
        for _, parentID in ipairs(node.requires or {}) do
            if nodeByID[parentID] == nil then
                table.insert(
                    missingParents,
                    "node='"
                        .. tostring(nodeID)
                        .. "' source='"
                        .. tostring(source)
                        .. "' missing_parent='"
                        .. tostring(parentID)
                        .. "'"
                )
            end
        end
        for _, parentID in ipairs(node.requiresAny or {}) do
            if nodeByID[parentID] == nil then
                table.insert(
                    missingParents,
                    "node='"
                        .. tostring(nodeID)
                        .. "' source='"
                        .. tostring(source)
                        .. "' missing_parent='"
                        .. tostring(parentID)
                        .. "'"
                )
            end
        end
    end

    table.sort(missingParents)
    if #missingParents > 0 then
        validationError("missing node prerequisites detected: " .. table.concat(missingParents, "; "))
    end

    local visitState = {}
    local stack = {}

    local function detect(nodeID)
        local state = visitState[nodeID]
        if state == "visiting" then
            local startIndex = 1
            for i, stackID in ipairs(stack) do
                if stackID == nodeID then
                    startIndex = i
                    break
                end
            end
            local chain = {}
            for i = startIndex, #stack do
                table.insert(chain, stack[i])
            end
            table.insert(chain, nodeID)
            return chain
        end

        if state == "done" then
            return nil
        end

        visitState[nodeID] = "visiting"
        table.insert(stack, nodeID)

        local node = nodeByID[nodeID]
        for _, parentID in ipairs(node.requires or {}) do
            local cycle = detect(parentID)
            if cycle ~= nil then
                return cycle
            end
        end
        for _, parentID in ipairs(node.requiresAny or {}) do
            local cycle = detect(parentID)
            if cycle ~= nil then
                return cycle
            end
        end

        table.remove(stack)
        visitState[nodeID] = "done"
        return nil
    end

    local sortedNodeIDs = {}
    for nodeID in pairs(nodeByID) do
        table.insert(sortedNodeIDs, nodeID)
    end
    table.sort(sortedNodeIDs)

    for _, nodeID in ipairs(sortedNodeIDs) do
        local cycle = detect(nodeID)
        if cycle ~= nil then
            validationError("node prerequisite cycle detected: " .. formatCycleChain(cycle))
        end
    end
end

local function getPerks()
    return registryState.getPerks()
end

local function getPerkIDs()
    return registryState.getPerkIDs()
end

local function getPerkIDsForTab(tabID)
    local out = {}
    for _, id in ipairs(registryState.getPerkIDs()) do
        if registryState.getPerks()[id].tab == tabID then
            table.insert(out, id)
        end
    end
    return out
end

local function getTabIDs()
    local out = {}
    for _, tabID in ipairs(registryState.getTabIDs()) do
        table.insert(out, tabID)
    end
    return out
end

local function getTabLabel(tabID)
    return registryState.getTabLabel(tabID) or tostring(tabID)
end

local function getTabDescription(tabID)
    return registryState.getTabDescription(tabID)
end


local function sortedInterfaceKeys(interfacesTable)
    local keys = {}
    for key, _ in pairs(interfacesTable or {}) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    return keys
end

local function logInterfaceExposureDiagnostics()
    local interfaces = require("openmw.interfaces")
    local expectedKey = settings.MOD_NAME
    local exposed = type(interfaces[expectedKey]) == "table"
    print("[" .. settings.MOD_NAME .. "] interface exposure check expected='" .. expectedKey .. "' visible=" .. tostring(exposed))

    local keys = sortedInterfaceKeys(interfaces)
    if #keys == 0 then
        print("[" .. settings.MOD_NAME .. "] visible interfaces snapshot: <none>")
    else
        print("[" .. settings.MOD_NAME .. "] visible interfaces snapshot: " .. table.concat(keys, ", "))
    end
end

local function getEffectCount()
    local effectCount = 0
    for _ in pairs(effectsRegistry.getEffects()) do
        effectCount = effectCount + 1
    end
    return effectCount
end

local function buildStartupSummary()
    local totalPerks = #registryState.getPerkIDs()
    local totalNodes = 0
    for _ in pairs(registryState.getTreeNodes()) do
        totalNodes = totalNodes + 1
    end

    local registration = packRegistry.getSummary()
    print(
        "["
            .. settings.MOD_NAME
            .. "] startup registry summary: packs_registered="
            .. tostring(registration.totals.packs)
            .. " modules="
            .. tostring(registration.totals.modules)
            .. " perks="
            .. tostring(totalPerks)
            .. " nodes="
            .. tostring(totalNodes)
            .. " effects="
            .. tostring(getEffectCount())
    )

    if settings.REQUIRE_EXTERNAL_PERK_PACKS == true and totalPerks == 0 then
        error(
            "["
                .. settings.MOD_NAME
                .. "] external pack requirement failed. Enable a pack content file after SkillPerkSystem.omwscripts.",
            2
        )
    end
end

validateMergedTreeGraph()
buildStartupSummary()

logInterfaceExposureDiagnostics()

local loggedRuntimeRegistrySummary = false
local validatedRuntimeRegistryGraph = false
local function onUpdate()
    if loggedRuntimeRegistrySummary and validatedRuntimeRegistryGraph then
        return
    end

    local totalPerks = #registryState.getPerkIDs()
    local totalNodes = 0
    for _ in pairs(registryState.getTreeNodes()) do
        totalNodes = totalNodes + 1
    end

    if totalPerks == 0 and totalNodes == 0 then
        return
    end

    if not validatedRuntimeRegistryGraph then
        validateMergedTreeGraph()
        validatedRuntimeRegistryGraph = true
    end

    if loggedRuntimeRegistrySummary then
        return
    end

    loggedRuntimeRegistrySummary = true

    local registration = packRegistry.getSummary()
    print(
        "["
            .. settings.MOD_NAME
            .. "] runtime registry summary: packs_registered="
            .. tostring(registration.totals.packs)
            .. " modules="
            .. tostring(registration.totals.modules)
            .. " perks="
            .. tostring(totalPerks)
            .. " nodes="
            .. tostring(totalNodes)
            .. " effects="
            .. tostring(getEffectCount())
    )
end

return {
    interfaceName = settings.MOD_NAME,
    interface = {
        PLUGIN_API_VERSION = pluginAPI.PLUGIN_API_VERSION,
        assertCompatibleApiVersion = pluginAPI.assertCompatibleApiVersion,
        registerPerk = registerPerk,
        registerTreeNode = registerTreeNode,
        registerPerkModule = registerPerkModule,
        registerEffect = registerEffect,
        applyEffectOnAcquire = applyEffectOnAcquire,
        applyEffectOnRemove = applyEffectOnRemove,
        registerPointSource = registerPointSource,
        beginPackRegistration = packRegistry.beginPackRegistration,
        completePackRegistration = packRegistry.completePackRegistration,
        getRegistrationSummary = packRegistry.getSummary,
        getPerks = getPerks,
        getPerkIDs = getPerkIDs,
        getPerkIDsForTab = getPerkIDsForTab,
        getPerkIDsForSkill = getPerkIDsForTab,
        getTabIDs = getTabIDs,
        getTabLabel = getTabLabel,
        getTabDescription = getTabDescription,
        registerTreeNodes = treeRegistry.registerTreeNodes,
        getTreeNode = treeRegistry.getTreeNode,
        getTreeNodesForTab = treeRegistry.getTreeNodesForTab,
        getTreeNodesForSkill = treeRegistry.getTreeNodesForTab,
        loadTabTree = treeRegistry.loadTabTree,
        loadSkillTree = treeRegistry.loadTabTree,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
