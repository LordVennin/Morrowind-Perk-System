local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
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
    if type(data.skill) ~= "string" then
        validationError("registerPerk(" .. tostring(data.id) .. ") missing string field 'skill'", 2)
    end
    if not hasSkillRecord(data.skill) then
        validationError(
            "registerPerk(" .. tostring(data.id) .. ") has invalid skill id '" .. tostring(data.skill) .. "'",
            2
        )
    end
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
end

local function registerTreeNode(data, source)
    if type(data) ~= "table" then
        validationError("registerTreeNode() expects a table", 2)
    end
    if type(data.id) ~= "string" or data.id == "" then
        validationError("registerTreeNode() missing string field 'id'", 2)
    end
    if type(data.skill) ~= "string" or not hasSkillRecord(data.skill) then
        validationError("registerTreeNode(" .. tostring(data.id) .. ") has invalid field 'skill'", 2)
    end
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
        skill = perk.skill,
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
        skill = nodeData.skill or perk.skill,
        x = nodeData.x,
        y = nodeData.y,
        requires = nodeData.requires,
        title = nodeData.title,
        description = nodeData.description,
    }, nodeData.perkId or nodeData.perkID or perk.perkId or perk.perkID or perk.id
end

local function registerPerkModule(data, source, expectedSkill)
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

    local perkIds = {}
    local hasPerkEntries = false
    local registeredPerks = 0
    local registeredNodes = 0

    if type(perks) == "table" then
        for i, perk in ipairs(perks) do
            if type(perk) ~= "table" then
                validationError("registerPerkModule() perks[" .. tostring(i) .. "] must be a table", 2)
            end
            if type(expectedSkill) == "string" and expectedSkill ~= "" and type(perk.skill) == "string" and perk.skill ~= "" and perk.skill ~= expectedSkill then
                validationError(
                    "registerPerkModule() perk '"
                        .. tostring(perk.id)
                        .. "' declares skill '"
                        .. tostring(perk.skill)
                        .. "' but expected '"
                        .. tostring(expectedSkill)
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
            if type(expectedSkill) == "string" and expectedSkill ~= "" and type(node.skill) == "string" and node.skill ~= "" and node.skill ~= expectedSkill then
                validationError(
                    "registerPerkModule() node '"
                        .. tostring(node.id)
                        .. "' declares skill '"
                        .. tostring(node.skill)
                        .. "' but expected '"
                        .. tostring(expectedSkill)
                        .. "'",
                    2
                )
            end
            local mappedPerkID = node.perkId or node.perkID or node.id
            if hasPerkEntries and mappedPerkID ~= nil and mappedPerkID ~= "" and not perkIds[mappedPerkID] then
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

    return { perks = registeredPerks, nodes = registeredNodes, skipped = false }
end

local function registerEffect(data, source)
    if type(data) ~= "table" or type(data.id) ~= "string" or data.id == "" then
        validationError("registerEffect() requires a table with non-empty string field 'id'", 2)
    end
    local sourceName = normalizeSource(source)
    effectsRegistry.registerEffect(data.id, data, sourceName)
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
