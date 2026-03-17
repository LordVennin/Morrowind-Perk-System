local core = require("openmw.core")
local settings = require("scripts.SkillPerkSystem.settings")
local registryState = require("scripts.SkillPerkSystem.registry_state")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local pluginLoader = require("scripts.SkillPerkSystem.plugin_loader")

local function countKeys(map)
    local count = 0
    for _ in pairs(map or {}) do
        count = count + 1
    end
    return count
end

local function listContentPacks()
    local packs = {}
    local files = core.contentFiles
    if type(files) ~= "table" then
        return packs
    end

    for _, contentFile in ipairs(files) do
        if type(contentFile) == "string" then
            local fileName = contentFile:match("([^/\\]+)$") or contentFile
            local packName = fileName:gsub("%.[^%.]+$", "")
            table.insert(packs, {
                file = contentFile,
                packName = packName,
            })
        end
    end

    table.sort(packs, function(a, b)
        return a.packName < b.packName
    end)

    return packs
end

local function appendIssue(list, kind, id, message)
    table.insert(list, {
        kind = kind,
        id = id,
        message = message,
    })
end

local function validatePerkDefinitions()
    local issues = {}

    for perkID, perk in pairs(registryState.getPerks()) do
        if type(perk) ~= "table" then
            appendIssue(issues, "malformed", perkID, "perk record is not a table")
        else
            if type(perk.id) ~= "string" or perk.id == "" then
                appendIssue(issues, "malformed", perkID, "missing non-empty string field 'id'")
            elseif perk.id ~= perkID then
                appendIssue(issues, "malformed", perkID, "perk key does not match perk.id")
            end

            if type(perk.skill) ~= "string" or perk.skill == "" then
                appendIssue(issues, "malformed", perkID, "missing non-empty string field 'skill'")
            elseif core.stats.Skill.records[perk.skill] == nil then
                appendIssue(issues, "malformed", perkID, "unknown skill id '" .. tostring(perk.skill) .. "'")
            end

            if type(perk.effectId) ~= "string" or perk.effectId == "" then
                appendIssue(issues, "malformed", perkID, "missing non-empty string field 'effectId'")
            end

            if type(perk.cost) ~= "number" or perk.cost < 1 or perk.cost ~= math.floor(perk.cost) then
                appendIssue(issues, "malformed", perkID, "field 'cost' must be a positive integer")
            end

            if perk.requirements ~= nil and type(perk.requirements) ~= "table" then
                appendIssue(issues, "malformed", perkID, "field 'requirements' must be a table if present")
            end
        end
    end

    table.sort(issues, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)

    return issues
end

local function collectMissingEffects()
    local missing = {}
    local effects = effectsRegistry.getEffects()
    for perkID, perk in pairs(registryState.getPerks()) do
        if type(perk) == "table" and type(perk.effectId) == "string" and perk.effectId ~= "" then
            if effects[perk.effectId] == nil then
                table.insert(missing, {
                    perkID = perkID,
                    effectID = perk.effectId,
                    source = registryState.getPerkSource(perkID) or "unknown",
                })
            end
        end
    end

    table.sort(missing, function(a, b)
        if a.effectID == b.effectID then
            return a.perkID < b.perkID
        end
        return a.effectID < b.effectID
    end)

    return missing
end

local function printValidationSummary()
    pluginLoader.loadInstalledPacks(require("scripts.SkillPerkSystem.plugin_api"))

    local packs = listContentPacks()
    local missingEffects = collectMissingEffects()
    local malformedPerks = validatePerkDefinitions()
    local duplicatePerks = registryState.getDuplicatePerkRegistrations()
    local duplicateNodes = registryState.getDuplicateTreeNodeRegistrations()
    local duplicateEffects = effectsRegistry.getDuplicateEffectRegistrations()

    print("[" .. settings.MOD_NAME .. "] skillperks_validate")
    print("  loaded packs (from content files): " .. tostring(#packs))
    for _, pack in ipairs(packs) do
        print("    - " .. pack.packName .. " (" .. pack.file .. ")")
    end

    print("  registry counts: perks=" .. tostring(#registryState.getPerkIDs()) .. " effects=" .. tostring(countKeys(effectsRegistry.getEffects())))

    print("  duplicate ids: perk=" .. tostring(#duplicatePerks) .. " treeNode=" .. tostring(#duplicateNodes) .. " effect=" .. tostring(#duplicateEffects))
    for _, duplicate in ipairs(duplicatePerks) do
        print(
            "    - perk "
                .. tostring(duplicate.id)
                .. " (first="
                .. tostring(duplicate.previousSource)
                .. ", attempted="
                .. tostring(duplicate.attemptedSource)
                .. ")"
        )
    end
    for _, duplicate in ipairs(duplicateNodes) do
        print(
            "    - treeNode "
                .. tostring(duplicate.id)
                .. " (first="
                .. tostring(duplicate.previousSource)
                .. ", attempted="
                .. tostring(duplicate.attemptedSource)
                .. ")"
        )
    end

    for _, duplicate in ipairs(duplicateEffects) do
        print(
            "    - effect "
                .. tostring(duplicate.id)
                .. " (first="
                .. tostring(duplicate.previousSource)
                .. ", attempted="
                .. tostring(duplicate.attemptedSource)
                .. ")"
        )
    end

    print("  missing effect handlers: " .. tostring(#missingEffects))
    for _, missing in ipairs(missingEffects) do
        print(
            "    - perk="
                .. tostring(missing.perkID)
                .. " effectId="
                .. tostring(missing.effectID)
                .. " source="
                .. tostring(missing.source)
        )
    end

    print("  malformed perk definitions: " .. tostring(#malformedPerks))
    for _, issue in ipairs(malformedPerks) do
        print("    - perk=" .. tostring(issue.id) .. " issue=" .. tostring(issue.message))
    end
end

return {
    printValidationSummary = printValidationSummary,
}
