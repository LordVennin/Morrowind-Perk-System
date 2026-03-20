local interfaces = require("openmw.interfaces")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local packRegistry = require("scripts.SkillPerkSystem.plugin_loader")
local settings = require("scripts.SkillPerkSystem.settings")

local PLUGIN_API_VERSION = 1
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"
local REQUIRED_PERK_MODULE_SCHEMA = "skillperks.vNext"

local function validationError(message, level)
    error(VALIDATION_ERROR_TAG .. ": " .. tostring(message), level or 2)
end

local function normalizeSource(source)
    if type(source) ~= "string" or source == "" then
        return "unknown"
    end
    return source
end

local function duplicatePolicyLabel()
    if settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE then
        return "override(last-write-wins)"
    end
    return "strict(error)"
end

local function normalizeTabName(tabName)
    local text = tostring(tabName or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("%s+", " ")
    return text
end

local function canonicalTabId(tabName)
    return normalizeTabName(tabName):lower()
end

local function resolveTab(data, context)
    local rawTab = data.tab
    if rawTab == nil then
        rawTab = data.skill
    end
    if type(rawTab) ~= "string" then
        validationError(context .. " missing string field 'tab'", 2)
    end

    local normalizedTab = normalizeTabName(rawTab)
    if normalizedTab == "" then
        validationError(context .. " field 'tab' cannot be empty", 2)
    end

    data.tab = canonicalTabId(normalizedTab)
    data.tabName = normalizedTab
    if data.tabDescription ~= nil then
        if type(data.tabDescription) ~= "string" then
            validationError(context .. " field 'tabDescription' must be a string", 2)
        end
        data.tabDescription = data.tabDescription:gsub("^%s+", ""):gsub("%s+$", "")
        if data.tabDescription == "" then
            data.tabDescription = nil
        end
    end
    data.skill = nil
end

local function assertCompatibleApiVersion(expectedVersion)
    if expectedVersion == nil then
        return true
    end
    if type(expectedVersion) ~= "number" or expectedVersion ~= math.floor(expectedVersion) then
        validationError("Plugin API compatibility check requires an integer version", 2)
    end
    if expectedVersion ~= PLUGIN_API_VERSION then
        validationError(
            "Incompatible SkillPerkSystem plugin API version: plugin expects v"
                .. tostring(expectedVersion)
                .. ", engine provides v"
                .. tostring(PLUGIN_API_VERSION),
            2
        )
    end
    return true
end

local function registerPerk(data, source)
    if type(data) ~= "table" then
        validationError("registerPerk() expects a table", 2)
    end
    if type(data.id) ~= "string" then
        validationError("registerPerk() missing string field 'id'", 2)
    end
    resolveTab(data, "registerPerk(" .. tostring(data.id) .. ")")
    if type(data.effectId) ~= "string" or data.effectId == "" then
        validationError("registerPerk(" .. tostring(data.id) .. ") missing non-empty string field 'effectId'", 2)
    end

    if data.requirements == nil then
        data.requirements = {}
    end
    if type(data.requirements) ~= "table" then
        validationError("registerPerk(" .. tostring(data.id) .. ") field 'requirements' must be a table", 2)
    end

    if data.cost == nil then
        data.cost = 1
    end
    if type(data.cost) ~= "number" or data.cost < 1 or data.cost ~= math.floor(data.cost) then
        validationError("registerPerk(" .. tostring(data.id) .. ") field 'cost' must be a positive integer", 2)
    end

    local sourceName = normalizeSource(source)
    local ok, previousSource = registryState.registerPerk(data, sourceName, settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE)
    if not ok then
        validationError(
            "registerPerk() duplicate perk id '"
                .. tostring(data.id)
                .. "' from source='"
                .. tostring(sourceName)
                .. "' conflicts with source='"
                .. tostring(previousSource)
                .. "' policy="
                .. duplicatePolicyLabel(),
            2
        )
    end
    packRegistry.noteRegistration("perks", sourceName, 1)
end

local function registerTreeNode(data, source)
    if type(data) ~= "table" then
        validationError("registerTreeNode() expects a table", 2)
    end
    if type(data.id) ~= "string" or data.id == "" then
        validationError("registerTreeNode() missing string field 'id'", 2)
    end
    resolveTab(data, "registerTreeNode(" .. tostring(data.id) .. ")")
    if type(data.x) ~= "number" or type(data.y) ~= "number" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") requires numeric fields 'x' and 'y'", 2)
    end

    if data.requires == nil then
        data.requires = {}
    end
    if type(data.requires) ~= "table" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'requires' must be a list", 2)
    end
    for i, req in ipairs(data.requires) do
        if type(req) ~= "string" then
            validationError(
                "registerTreeNode(" .. tostring(data.id) .. ") requires[" .. tostring(i) .. "] must be a string",
                2
            )
        end
    end

    if data.title == nil then
        data.title = data.id
    end
    if type(data.title) ~= "string" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'title' must be a string", 2)
    end

    if data.description ~= nil and type(data.description) ~= "string" then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") field 'description' must be a string", 2)
    end

    local sourceName = normalizeSource(source)
    local ok, previousSource = registryState.registerTreeNode(data, sourceName, settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE)
    if not ok then
        validationError(
            "registerTreeNode() duplicate node id '"
                .. tostring(data.id)
                .. "' from source='"
                .. tostring(sourceName)
                .. "' conflicts with source='"
                .. tostring(previousSource)
                .. "' policy="
                .. duplicatePolicyLabel(),
            2
        )
    end
    packRegistry.noteRegistration("nodes", sourceName, 1)
end

local function buildRequirement(parentID)
    return {
        check = function()
            local playerInterface = interfaces[settings.MOD_NAME .. "Player"]
            return playerInterface ~= nil and playerInterface.hasPerk(parentID)
        end,
    }
end

local function normalizePerkDefinition(perk)
    local normalized = {
        id = perk.id,
        tab = perk.tab,
        tabName = perk.tabName,
        effectId = perk.effectId,
        cost = perk.cost,
        requirements = perk.requirements,
    }

    if normalized.requirements == nil then
        normalized.requirements = {}
        for _, parentID in ipairs(perk.requires or {}) do
            table.insert(normalized.requirements, buildRequirement(parentID))
        end
    end

    return normalized
end

local function deriveNodeFromPerk(perk, sourceName)
    local hasEmbeddedNode = type(perk.node) == "table"
    local hasInlineNodeFields = type(perk.x) == "number" or type(perk.y) == "number" or perk.title ~= nil or perk.description ~= nil

    if not hasEmbeddedNode and not hasInlineNodeFields then
        return nil
    end

    if hasEmbeddedNode and hasInlineNodeFields then
        validationError(
            "module '"
                .. tostring(sourceName)
                .. "' perk '"
                .. tostring(perk.id)
                .. "' cannot define both node table and inline node fields",
            2
        )
    end

    local nodeData = hasEmbeddedNode and perk.node or perk
    local nodeID = nodeData.id or nodeData.nodeId or nodeData.nodeID or perk.nodeId or perk.nodeID or perk.id
    return {
        id = nodeID,
        tab = nodeData.tab or nodeData.skill or perk.tab or perk.skill,
        tabName = nodeData.tabName or nodeData.tab or nodeData.skill or perk.tabName or perk.tab or perk.skill,
        x = nodeData.x,
        y = nodeData.y,
        requires = nodeData.requires,
        title = nodeData.title,
        description = nodeData.description,
    }, nodeData.perkId or nodeData.perkID or perk.perkId or perk.perkID or perk.id
end

local function registerPerkModule(data, source, expectedTab)
    if type(data) ~= "table" then
        validationError("registerPerkModule() expects a table", 2)
    end

    if data.schema ~= REQUIRED_PERK_MODULE_SCHEMA then
        validationError(
            "registerPerkModule() requires schema='"
                .. REQUIRED_PERK_MODULE_SCHEMA
                .. "' (source='"
                .. tostring(source)
                .. "')",
            2
        )
    end

    local enabled = data.enabled
    if type(enabled) == "function" then
        enabled = enabled()
    end
    if enabled == false then
        return { perks = 0, nodes = 0, skipped = true }
    end

    local perks = data.perks
    local nodes = data.nodes

    if type(perks) ~= "table" and type(nodes) ~= "table" then
        validationError("registerPerkModule() requires a module with perks and/or nodes", 2)
    end

    local sourceName = normalizeSource(source)
    local function validatePerkModuleEntry(perk, index)
        local context = "registerPerkModule() source='" .. tostring(sourceName) .. "' perks[" .. tostring(index) .. "]"
        if type(perk.id) ~= "string" or perk.id == "" then
            validationError(context .. " missing non-empty string field 'id'", 2)
        end
        local moduleTab = perk.tab or perk.skill
        if type(moduleTab) ~= "string" or normalizeTabName(moduleTab) == "" then
            validationError(context .. " missing non-empty string field 'tab'", 2)
        end
        if type(perk.effectId) ~= "string" or perk.effectId == "" then
            validationError(context .. " missing non-empty string field 'effectId'", 2)
        end
    end

    local function validateNodeModuleEntry(node, index, nodeSource)
        local context = "registerPerkModule() source='"
            .. tostring(sourceName)
            .. "' "
            .. tostring(nodeSource)
            .. "["
            .. tostring(index)
            .. "]"
        if type(node.id) ~= "string" or node.id == "" then
            validationError(context .. " missing non-empty string field 'id'", 2)
        end
        local moduleTab = node.tab or node.skill
        if type(moduleTab) ~= "string" or normalizeTabName(moduleTab) == "" then
            validationError(context .. " missing non-empty string field 'tab'", 2)
        end
        if type(node.x) ~= "number" then
            validationError(context .. " missing numeric field 'x'", 2)
        end
        if type(node.y) ~= "number" then
            validationError(context .. " missing numeric field 'y'", 2)
        end
    end

    local perkIds = {}
    local hasPerkEntries = false
    local registeredPerks = 0
    local registeredNodes = 0

    if type(perks) == "table" then
        for i, perk in ipairs(perks) do
            if type(perk) ~= "table" then
                validationError("registerPerkModule() perks[" .. tostring(i) .. "] must be a table", 2)
            end
            validatePerkModuleEntry(perk, i)
            local perkTab = normalizeTabName(perk.tab or perk.skill)
            local expectedTabNormalized = normalizeTabName(expectedTab)
            if type(expectedTab) == "string" and expectedTabNormalized ~= "" and perkTab ~= expectedTabNormalized then
                validationError(
                    "registerPerkModule() perk '"
                        .. tostring(perk.id)
                        .. "' declares tab '"
                        .. tostring(perkTab)
                        .. "' but expected '"
                        .. tostring(expectedTabNormalized)
                        .. "'",
                    2
                )
            end

            registerPerk(normalizePerkDefinition(perk), source)
            perkIds[perk.id] = true
            hasPerkEntries = true
            registeredPerks = registeredPerks + 1

            local derivedNode, mappedPerkID = deriveNodeFromPerk(perk, source)
            if derivedNode ~= nil then
                validateNodeModuleEntry(derivedNode, i, "derived_nodes")
                if mappedPerkID ~= nil and mappedPerkID ~= "" and mappedPerkID ~= perk.id then
                    validationError(
                        "registerPerkModule() perk '"
                            .. tostring(perk.id)
                            .. "' derived node mapped to unexpected perk id '"
                            .. tostring(mappedPerkID)
                            .. "'",
                        2
                    )
                end
                registerTreeNode(derivedNode, source)
                registeredNodes = registeredNodes + 1
            end
        end
    end

    if type(nodes) == "table" then
        for i, node in ipairs(nodes) do
            if type(node) ~= "table" then
                validationError("registerPerkModule() nodes[" .. tostring(i) .. "] must be a table", 2)
            end
            validateNodeModuleEntry(node, i, "nodes")
            local nodeTab = normalizeTabName(node.tab or node.skill)
            local expectedTabNormalized = normalizeTabName(expectedTab)
            if type(expectedTab) == "string" and expectedTabNormalized ~= "" and nodeTab ~= expectedTabNormalized then
                validationError(
                    "registerPerkModule() node '"
                        .. tostring(node.id)
                        .. "' declares tab '"
                        .. tostring(nodeTab)
                        .. "' but expected '"
                        .. tostring(expectedTabNormalized)
                        .. "'",
                    2
                )
            end
            local mappedPerkID = node.perkId or node.perkID or node.id
            local registeredPerksByID = registryState.getPerks()
            local hasMappedPerk = mappedPerkID ~= nil and mappedPerkID ~= "" and (perkIds[mappedPerkID] or registeredPerksByID[mappedPerkID] ~= nil)
            if hasPerkEntries and mappedPerkID ~= nil and mappedPerkID ~= "" and not hasMappedPerk then
                validationError(
                    "registerPerkModule() node '"
                        .. tostring(node.id)
                        .. "' maps to missing perk id '"
                        .. tostring(mappedPerkID)
                        .. "'",
                    2
                )
            end

            registerTreeNode(node, source)
            registeredNodes = registeredNodes + 1
        end
    end

    packRegistry.noteRegistration("modules", sourceName, 1)
    return { perks = registeredPerks, nodes = registeredNodes, skipped = false }
end

local function registerEffect(data, source)
    if type(data) ~= "table" or type(data.id) ~= "string" or data.id == "" then
        validationError("registerEffect() requires a table with non-empty string field 'id'", 2)
    end
    local sourceName = normalizeSource(source)
    effectsRegistry.registerEffect(data.id, data, sourceName)
    packRegistry.noteRegistration("effects", sourceName, 1)
end

local function registerPointSource(sourceId, handlers, source)
    if type(sourceId) ~= "string" or sourceId == "" then
        validationError("registerPointSource() requires non-empty string sourceId", 2)
    end
    if type(handlers) ~= "table" then
        validationError("registerPointSource(" .. tostring(sourceId) .. ") requires handlers table", 2)
    end

    local sourceName = normalizeSource(source)
    registryState.registerPointSource(sourceId, handlers, sourceName)
    packRegistry.noteRegistration("pointSources", sourceName, 1)
end

return {
    PLUGIN_API_VERSION = PLUGIN_API_VERSION,
    assertCompatibleApiVersion = assertCompatibleApiVersion,
    registerPerk = registerPerk,
    registerTreeNode = registerTreeNode,
    registerPerkModule = registerPerkModule,
    registerEffect = registerEffect,
    registerPointSource = registerPointSource,
}
