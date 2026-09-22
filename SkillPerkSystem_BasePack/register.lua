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

    local normalized = perk.tab:gsub("[^%w]", ""):lower()
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

-- Hidden perks: shown only to a character with a particular race and class
-- skill combination. A perk carries
--
--     hiddenUnless = {
--         race = "wood elf",                 -- race record id, spacing ignored
--         majorSkills = { "conjuration" },   -- every one must be a major skill
--         classSkills = { "athletics" },     -- every one must be major or minor
--         classSkillsAny = { "illusion", "mercantile" }, -- at least one major or minor
--         contentFiles = { "Bloodmoon.esm" },-- every one must be loaded
--         label = "Wood Elf, Conjuration major",
--     }
--
-- and the check becomes both the tree's visibility test and a requirement on
-- buying it. Everything is pcall-wrapped: the menu can run against mocked
-- engine modules, and a missing API must hide the perk rather than break the
-- page.
local function normalizeName(value)
    local out = tostring(value or ""):lower():gsub("[^%w]", "")
    return out
end

local function playerNpcRecord()
    local ok, record = pcall(function() return types.NPC.record(pself) end)
    return ok and record or nil
end

local function playerClassSkills()
    local record = playerNpcRecord()
    local classId = record ~= nil and record.class or nil
    if classId == nil then
        return nil, nil
    end
    local ok, classRecord = pcall(function() return types.NPC.classes.records[classId] end)
    if not ok or classRecord == nil then
        return nil, nil
    end
    local major, minor = {}, {}
    pcall(function()
        for _, id in ipairs(classRecord.majorSkills) do major[normalizeName(id)] = true end
    end)
    pcall(function()
        for _, id in ipairs(classRecord.minorSkills) do minor[normalizeName(id)] = true end
    end)
    return major, minor
end

local function contentFileLoaded(name)
    local ok, has = pcall(function() return core.contentFiles.has(name) end)
    return ok and has == true
end

local function buildVisibleCheck(rule)
    return function()
        if type(rule.race) == "string" then
            local record = playerNpcRecord()
            if record == nil or normalizeName(record.race) ~= normalizeName(rule.race) then
                return false
            end
        end
        if type(rule.majorSkills) == "table" or type(rule.classSkills) == "table"
                or type(rule.classSkillsAny) == "table" then
            local major, minor = playerClassSkills()
            if major == nil then
                return false
            end
            for _, skill in ipairs(rule.majorSkills or {}) do
                if not major[normalizeName(skill)] then
                    return false
                end
            end
            for _, skill in ipairs(rule.classSkills or {}) do
                local id = normalizeName(skill)
                if not major[id] and not minor[id] then
                    return false
                end
            end
            if type(rule.classSkillsAny) == "table" and #rule.classSkillsAny > 0 then
                local anyHeld = false
                for _, skill in ipairs(rule.classSkillsAny) do
                    local id = normalizeName(skill)
                    if major[id] or minor[id] then
                        anyHeld = true
                        break
                    end
                end
                if not anyHeld then
                    return false
                end
            end
        end
        for _, file in ipairs(rule.contentFiles or {}) do
            if not contentFileLoaded(file) then
                return false
            end
        end
        return true
    end
end

local function hiddenRequirement(perk)
    local rule = perk.hiddenUnless
    if type(rule) ~= "table" then
        return nil
    end
    local check = buildVisibleCheck(rule)
    return {
        label = type(rule.label) == "string" and rule.label or "Hidden",
        check = function()
            local ok, visible = pcall(check)
            return ok and visible == true
        end,
    }
end

local function buildPerkRequirements(perk)
    local out = {}

    local hidden = hiddenRequirement(perk)
    if hidden ~= nil then
        table.insert(out, hidden)
    end

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
        source = "scripts.SkillPerkSystem_BasePack.perks.shortblade.shortblade",
        data = require("scripts.SkillPerkSystem_BasePack.perks.shortblade.shortblade"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.axe.axe",
        data = require("scripts.SkillPerkSystem_BasePack.perks.axe.axe"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.bluntweapon.bluntweapon",
        data = require("scripts.SkillPerkSystem_BasePack.perks.bluntweapon.bluntweapon"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.handtohand.handtohand",
        data = require("scripts.SkillPerkSystem_BasePack.perks.handtohand.handtohand"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.security",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.security"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.armorer.armorer",
        data = require("scripts.SkillPerkSystem_BasePack.perks.armorer.armorer"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.marksman.marksman",
        data = require("scripts.SkillPerkSystem_BasePack.perks.marksman.marksman"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.lightarmor.lightarmor",
        data = require("scripts.SkillPerkSystem_BasePack.perks.lightarmor.lightarmor"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.mediumarmor.mediumarmor",
        data = require("scripts.SkillPerkSystem_BasePack.perks.mediumarmor.mediumarmor"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.heavyarmor.heavyarmor",
        data = require("scripts.SkillPerkSystem_BasePack.perks.heavyarmor.heavyarmor"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.spear.spear",
        data = require("scripts.SkillPerkSystem_BasePack.perks.spear.spear"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.unarmored.unarmored",
        data = require("scripts.SkillPerkSystem_BasePack.perks.unarmored.unarmored"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.destruction.destruction",
        data = require("scripts.SkillPerkSystem_BasePack.perks.destruction.destruction"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.alchemy.alchemy",
        data = require("scripts.SkillPerkSystem_BasePack.perks.alchemy.alchemy"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.athletics.athletics",
        data = require("scripts.SkillPerkSystem_BasePack.perks.athletics.athletics"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.acrobatics.acrobatics",
        data = require("scripts.SkillPerkSystem_BasePack.perks.acrobatics.acrobatics"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.sneak.sneak",
        data = require("scripts.SkillPerkSystem_BasePack.perks.sneak.sneak"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.conjuration.conjuration",
        data = require("scripts.SkillPerkSystem_BasePack.perks.conjuration.conjuration"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.mysticism.mysticism",
        data = require("scripts.SkillPerkSystem_BasePack.perks.mysticism.mysticism"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.alteration.alteration",
        data = require("scripts.SkillPerkSystem_BasePack.perks.alteration.alteration"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.illusion.illusion",
        data = require("scripts.SkillPerkSystem_BasePack.perks.illusion.illusion"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.restoration.restoration",
        data = require("scripts.SkillPerkSystem_BasePack.perks.restoration.restoration"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.enchant.enchant",
        data = require("scripts.SkillPerkSystem_BasePack.perks.enchant.enchant"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.mercantile.mercantile",
        data = require("scripts.SkillPerkSystem_BasePack.perks.mercantile.mercantile"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.speechcraft.speechcraft",
        data = require("scripts.SkillPerkSystem_BasePack.perks.speechcraft.speechcraft"),
    },
}


local TUMBLER_SENSE_TOGGLE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Toggle"

local function sendPlayerEventOrGlobal(context, eventName, payload)
    local player = type(context) == "table" and context.player or nil
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(eventName, payload)
        return
    end

    core.sendGlobalEvent(eventName, payload)
end

local function tumblerSensePayload(enable, bonusPerFailedAttempt, maxStacks)
    return {
        enable = enable == true,
        bonusPerFailedAttempt = bonusPerFailedAttempt or 1,
        maxStacks = maxStacks or 5,
        initialStacks = 0,
        sharedDecaySeconds = 10,
    }
end

local tumblerSenseEffect = {
    id = "security_tumbler_sense_effect",
    name = "Tumbler Sense",
    description = "Starts at 0 stacks. Failed lockpick attempts grant +1 Security per stack (max 5) with a shared 10s decay timer.",
    onAcquire = function(context)
        sendPlayerEventOrGlobal(context, TUMBLER_SENSE_TOGGLE_EVENT, tumblerSensePayload(true, 1, 5))
    end,
    onRemove = function(context)
        sendPlayerEventOrGlobal(context, TUMBLER_SENSE_TOGGLE_EVENT, tumblerSensePayload(false, 1, 5))
    end,
}

local perfectPressureEffect = {
    id = "security_perfect_pressure_effect",
    name = "Perfect Pressure",
    description = "Tumbler Sense now grants +2 Security per failed attempt and can stack up to +10 Security.",
    onAcquire = function(context)
        sendPlayerEventOrGlobal(context, TUMBLER_SENSE_TOGGLE_EVENT, tumblerSensePayload(true, 2, 10))
    end,
    onRemove = function(context)
        sendPlayerEventOrGlobal(context, TUMBLER_SENSE_TOGGLE_EVENT, tumblerSensePayload(true, 1, 5))
    end,
}

local effectModules = {
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.register:tumbler_sense_effect",
        data = tumblerSenseEffect,
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.quick_pick_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.quick_pick_effect"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.treasure_sense_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.treasure_sense_effect"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.lucky_find_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.lucky_find_effect"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.fortunes_habit_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.fortunes_habit_effect"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.register:perfect_pressure_effect",
        data = perfectPressureEffect,
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.security.unseen_hand_effect",
        data = require("scripts.SkillPerkSystem_BasePack.perks.security.unseen_hand_effect"),
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
        -- The registry stores these tables as given, so the visibility check
        -- rides along on both the perk and its node for the menu to read.
        local hidden = hiddenRequirement(perk)
        local visibleCheck = hidden ~= nil and hidden.check or nil

        api.registerPerk({
            id = perk.id,
            tab = perk.tab,
            tabDescription = perk.tabDescription,
            effectId = perk.effectId,
            cost = perk.cost,
            requirements = buildPerkRequirements(perk),
            hidden = visibleCheck ~= nil,
            visibleCheck = visibleCheck,
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
            hidden = visibleCheck ~= nil,
            visibleCheck = visibleCheck,
        }, entry.source)
    end
end

return {}
