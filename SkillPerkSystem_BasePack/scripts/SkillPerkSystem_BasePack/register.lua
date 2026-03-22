local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local api = interfaces.SkillPerkSystem
if
    api == nil
    or type(api.registerPerk) ~= "function"
    or type(api.registerTreeNode) ~= "function"
    or type(api.registerEffect) ~= "function"
then
    local keys = {}
    for key, _ in pairs(interfaces) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    if #keys == 0 then
        print("[SkillPerkSystem_BasePack] visible interfaces snapshot: <none>")
    else
        print("[SkillPerkSystem_BasePack] visible interfaces snapshot: " .. table.concat(keys, ", "))
    end
    error("[SkillPerkSystem_BasePack] interfaces.SkillPerkSystem unavailable or missing required methods", 2)
end

api.assertCompatibleApiVersion(1)

local function inferSkillId(perk)
    if type(perk.skillId) == "string" and perk.skillId ~= "" then
        return perk.skillId
    end
    if type(perk.tab) ~= "string" or perk.tab == "" then
        return nil
    end

    local normalized = perk.tab:gsub("%s+", ""):lower()
    if normalized ~= "" then
        return normalized
    end
    return nil
end

local function getSkillLabel(skillID)
    local record = core.stats.Skill.records[skillID]
    if record ~= nil and type(record.name) == "string" and record.name ~= "" then
        return record.name
    end
    return tostring(skillID)
end

local function minimumSkillLevelRequirement(skillID, minimumLevel)
    return {
        label = string.format("%s %d+", getSkillLabel(skillID), minimumLevel),
        check = function()
            local accessor = types.NPC.stats.skills[skillID]
            if type(accessor) ~= "function" then
                return false
            end
            local stat = accessor(pself)
            return stat ~= nil and type(stat.base) == "number" and stat.base >= minimumLevel
        end,
    }
end

local function buildPerkRequirements(perk)
    local out = {}

    if type(perk.requirements) == "table" then
        for _, requirement in ipairs(perk.requirements) do
            table.insert(out, requirement)
        end
    end

    if type(perk.minimumSkill) == "number" then
        local skillID = inferSkillId(perk)
        if skillID ~= nil then
            table.insert(out, minimumSkillLevelRequirement(skillID, perk.minimumSkill))
        end
    end

    return out
end

local modules = {
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.block.block",
        data = require("scripts.SkillPerkSystem_BasePack.perks.block.block"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
        data = require("scripts.SkillPerkSystem_BasePack.perks.longblade.longblade"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.security",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.security"),
    },
}

local effectModules = {
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect"),
    },
}

local function registerEffectSafe(effectData, source)
    local ok, err = pcall(api.registerEffect, effectData, source)
    if ok then
        return
    end

    local message = tostring(err)
    local effectID = type(effectData) == "table" and effectData.id or "<unknown>"
    local duplicateIDFragment = "duplicate effect id '" .. tostring(effectID) .. "'"
    local duplicateSourceFragment = "source='" .. tostring(source) .. "'"
    local duplicateConflictFragment = "conflicts with source='" .. tostring(source) .. "'"

    if
        message:find(duplicateIDFragment, 1, true)
        and message:find(duplicateSourceFragment, 1, true)
        and message:find(duplicateConflictFragment, 1, true)
    then
        print(
            "[SkillPerkSystem_BasePack] duplicate effect registration ignored for id='"
                .. tostring(effectID)
                .. "' source='"
                .. tostring(source)
                .. "'"
        )
        return
    end

    error(err, 2)
end

for _, entry in ipairs(effectModules) do
    registerEffectSafe(entry.data, entry.source)
end

for _, entry in ipairs(modules) do
    for _, perk in ipairs(entry.data.perks or {}) do
        api.registerPerk({
            id = perk.id,
            tab = perk.tab,
            tabDescription = perk.tabDescription,
            effectId = perk.effectId,
            cost = perk.cost,
            requirements = buildPerkRequirements(perk),
        }, entry.source)

        api.registerTreeNode({
            id = perk.id,
            tab = perk.tab,
            tabDescription = perk.tabDescription,
            x = perk.x,
            y = perk.y,
            requires = perk.requires or {},
            requiresAny = perk.requiresAny or {},
            title = perk.title,
            description = perk.description,
        }, entry.source)
    end
end

for _, entry in ipairs(effectModules) do
    api.registerEffect(entry.data, entry.source)
end

return {}
