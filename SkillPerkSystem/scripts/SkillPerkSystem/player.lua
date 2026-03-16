local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")
local types = require("openmw.types")

local MOD_NAME = settings.MOD_NAME
local MILESTONE_STEP = settings.MILESTONE_STEP
local DEBUG_LOGS = settings.DEBUG_LOGS == true

local earnedMilestonesBySkill = {}
local spentPointsBySkill = {}
local activePerks = {}
local updateTimer = 0

local function debugPrint(message)
    if not DEBUG_LOGS then
        return
    end
    print("[" .. MOD_NAME .. "][debug] " .. message)
end

local function getSkillIds()
    local out = {}
    for _, record in ipairs(core.stats.Skill.records) do
        table.insert(out, record.id)
    end
    table.sort(out)
    return out
end

local function skillBase(skillID)
    local accessor = types.NPC.stats.skills[skillID]
    if type(accessor) ~= "function" then
        print("[" .. MOD_NAME .. "] Missing NPC skill accessor for skill id: " .. tostring(skillID))
        return 0
    end

    local stat = accessor(pself)
    if stat == nil or type(stat.base) ~= "number" then
        return 0
    end
    return stat.base
end

local function milestonesForSkill(skillID)
    return math.floor(skillBase(skillID) / MILESTONE_STEP)
end

local function earnedPoints(skillID)
    return earnedMilestonesBySkill[skillID] or 0
end

local function spentPoints(skillID)
    return spentPointsBySkill[skillID] or 0
end

local function availablePoints(skillID)
    return earnedPoints(skillID) - spentPoints(skillID)
end

local function requirementSatisfied(perk)
    for _, requirement in ipairs(perk.requirements or {}) do
        if type(requirement.check) == "function" and not requirement.check() then
            return false
        end
    end
    return true
end

local function hasPerk(perkID)
    for _, id in ipairs(activePerks) do
        if id == perkID then
            return true
        end
    end
    return false
end

local function getMissingParentPerks(perkID)
    if type(interfaces[MOD_NAME].getTreeNode) ~= "function" then
        return {}
    end

    local node = interfaces[MOD_NAME].getTreeNode(perkID)
    if node == nil then
        return {}
    end

    local missing = {}
    for _, requiredID in ipairs(node.requires or {}) do
        if not hasPerk(requiredID) then
            table.insert(missing, requiredID)
        end
    end
    return missing
end

local function getActivePerks()
    local out = {}
    for _, perkID in ipairs(activePerks) do
        table.insert(out, perkID)
    end
    return out
end

local function grantRetroactiveMilestones()
    for _, skillID in ipairs(getSkillIds()) do
        local oldMilestones = earnedPoints(skillID)
        local currentMilestones = milestonesForSkill(skillID)
        if currentMilestones > oldMilestones then
            earnedMilestonesBySkill[skillID] = currentMilestones
            debugPrint(string.format(
                "Retroactive milestones increased for %s: %d -> %d (available=%d)",
                skillID,
                oldMilestones,
                currentMilestones,
                availablePoints(skillID)
            ))
        end
        if spentPointsBySkill[skillID] == nil then
            spentPointsBySkill[skillID] = 0
        end
    end
end

local function reconcileSaveState()
    local perks = interfaces[MOD_NAME].getPerks()
    local filteredActivePerks = {}
    local recomputedSpentBySkill = {}

    for _, skillID in ipairs(getSkillIds()) do
        recomputedSpentBySkill[skillID] = 0
    end

    for _, perkID in ipairs(activePerks) do
        local perk = perks[perkID]
        if perk ~= nil then
            table.insert(filteredActivePerks, perkID)
            recomputedSpentBySkill[perk.skill] = (recomputedSpentBySkill[perk.skill] or 0) + perk.cost
        else
            print("[" .. MOD_NAME .. "] Dropping missing active perk from save: " .. tostring(perkID))
        end
    end

    activePerks = filteredActivePerks
    spentPointsBySkill = recomputedSpentBySkill

    for _, skillID in ipairs(getSkillIds()) do
        local earned = earnedPoints(skillID)
        local spent = spentPoints(skillID)
        if spent > earned then
            spentPointsBySkill[skillID] = earned
        end
    end
end

local function addPerk(data)
    if type(data) ~= "table" or type(data.perkID) ~= "string" then
        error("addPerk() requires { perkID = string }")
    end

    local perk = interfaces[MOD_NAME].getPerks()[data.perkID]
    if perk == nil then
        error("Unknown perk id: " .. tostring(data.perkID))
    end
    if hasPerk(data.perkID) then
        return
    end
    if not requirementSatisfied(perk) then
        print("[" .. MOD_NAME .. "] Cannot add perk " .. data.perkID .. ": requirements not met")
        return
    end

    local missingParents = getMissingParentPerks(data.perkID)
    if #missingParents > 0 then
        print("[" .. MOD_NAME .. "] Cannot add perk " .. data.perkID .. ": missing parents (" .. table.concat(missingParents, ", ") .. ")")
        return
    end

    if availablePoints(perk.skill) < perk.cost then
        print("[" .. MOD_NAME .. "] Cannot add perk " .. data.perkID .. ": not enough " .. perk.skill .. " perk points (cost=" .. perk.cost .. ")")
        return
    end

    table.insert(activePerks, data.perkID)
    spentPointsBySkill[perk.skill] = spentPoints(perk.skill) + perk.cost
    perk.onAdd()
end

local function removePerk(data)
    if type(data) ~= "table" or type(data.perkID) ~= "string" then
        error("removePerk() requires { perkID = string }")
    end

    local perk = interfaces[MOD_NAME].getPerks()[data.perkID]
    if perk == nil then
        error("Unknown perk id: " .. tostring(data.perkID))
    end

    for i, id in ipairs(activePerks) do
        if id == data.perkID then
            table.remove(activePerks, i)
            spentPointsBySkill[perk.skill] = math.max(0, spentPoints(perk.skill) - perk.cost)
            perk.onRemove()
            return
        end
    end
end

local function printSkillMenu(filterSkill)
    print("--- Skill Perk Menu ---")
    for _, skillID in ipairs(getSkillIds()) do
        if filterSkill == nil or filterSkill == "" or filterSkill == skillID then
            local base = skillBase(skillID)
            local earned = earnedPoints(skillID)
            local spent = spentPoints(skillID)
            local available = availablePoints(skillID)
            print(string.format("%s | skill=%d | milestones=%d | spent=%d | available=%d", skillID, base, earned, spent, available))

            local perkIds = interfaces[MOD_NAME].getPerkIDsForSkill(skillID)
            table.sort(perkIds)
            for _, perkID in ipairs(perkIds) do
                local owned = hasPerk(perkID) and "[owned]" or ""
                local perk = interfaces[MOD_NAME].getPerks()[perkID]
                print(string.format("  - %s (cost=%d) %s", perkID, perk.cost, owned))
            end
        end
    end
    print("-----------------------")
end

local function respecAllPerks()
    local perks = interfaces[MOD_NAME].getPerks()
    local refundsBySkill = {}
    local removedCount = 0

    for _, perkID in ipairs(activePerks) do
        local perk = perks[perkID]
        if perk ~= nil then
            refundsBySkill[perk.skill] = (refundsBySkill[perk.skill] or 0) + perk.cost
            perk.onRemove()
            removedCount = removedCount + 1
        else
            print("[" .. MOD_NAME .. "] Skipping unknown active perk during respec: " .. tostring(perkID))
        end
    end

    activePerks = {}
    for _, skillID in ipairs(getSkillIds()) do
        spentPointsBySkill[skillID] = 0
    end

    print("[" .. MOD_NAME .. "] Respec complete: removed " .. removedCount .. " perks")
    print("[" .. MOD_NAME .. "] Points refunded by skill:")
    for _, skillID in ipairs(getSkillIds()) do
        print(string.format("  %s: %d", skillID, refundsBySkill[skillID] or 0))
    end
end

local function normalizeConsoleArgs(mode, command)
    if type(mode) == "table" then
        command = mode.command
        mode = mode.mode
    elseif command == nil and type(mode) == "string" then
        -- Some OpenMW revisions only pass the command string.
        command = mode
        mode = nil
    end

    local normalizedCommand = type(command) == "string" and command:match("^%s*(.-)%s*$") or nil
    local normalizedMode = type(mode) == "string" and mode:lower() or nil

    return normalizedMode, normalizedCommand
end

local function onConsoleCommand(mode, command, selectedObject)
    local normalizedMode, normalizedCommand = normalizeConsoleArgs(mode, command)
    if normalizedCommand == nil or normalizedCommand == "" then
        return
    end

    local lower = normalizedCommand:lower()
    local lowerWithMode = normalizedMode ~= nil and (normalizedMode .. " " .. lower) or nil

    local function getSuffixForCmd(prefix)
        local lowerPrefix = prefix:lower()
        if lower == lowerPrefix then
            return ""
        end

        local prefixWithSpace = lowerPrefix .. " "
        if lower:sub(1, #prefixWithSpace) == prefixWithSpace then
            return normalizedCommand:sub(#prefixWithSpace + 1):match("^%s*(.-)%s*$")
        end

        if lowerWithMode ~= nil then
            if lowerWithMode == lowerPrefix then
                return ""
            end

            local modePrefix = normalizedMode .. " "
            if lowerPrefix:sub(1, #modePrefix) == modePrefix then
                local commandPrefix = lowerPrefix:sub(#modePrefix + 1)
                local commandPrefixWithSpace = commandPrefix .. " "
                if lower:sub(1, #commandPrefixWithSpace) == commandPrefixWithSpace then
                    return normalizedCommand:sub(#commandPrefixWithSpace + 1):match("^%s*(.-)%s*$")
                end
            end
        end

        return nil
    end

    if lower == "lua skillperksrespec" or lower == "skillperksrespec" or lowerWithMode == "lua skillperksrespec" then
        respecAllPerks()
    else
        local suffix = getSuffixForCmd("skillperks")
        if suffix == nil then
            suffix = getSuffixForCmd("lua skillperks")
        end

        if suffix ~= nil then
            if suffix == "" then
                printSkillMenu(nil)
            else
                printSkillMenu(suffix)
            end
        end
    end
end

local function onUpdate(dt)
    updateTimer = updateTimer - dt
    if updateTimer > 0 then
        return
    end
    updateTimer = 1
    grantRetroactiveMilestones()
end

local function shouldShowUI()
    for _, skillID in ipairs(getSkillIds()) do
        if availablePoints(skillID) > 0 then
            return true
        end
    end
    return false
end

local function UiModeChanged(data)
    if data.newMode ~= nil then
        return
    end

    local hasNCGDMW = interfaces.NCGDMW ~= nil
    if data.oldMode == "LevelUp" then
        if shouldShowUI() then
            pself:sendEvent(MOD_NAME .. "showPerkUI", {})
        else
            pself:sendEvent(MOD_NAME .. "closePerkUI", {})
        end
    elseif hasNCGDMW and data.oldMode == "Rest" then
        if shouldShowUI() then
            pself:sendEvent(MOD_NAME .. "showPerkUI", {})
        else
            pself:sendEvent(MOD_NAME .. "closePerkUI", {})
        end
    else
        pself:sendEvent(MOD_NAME .. "closePerkUI", {})
    end
end

local function onLoad(data)
    earnedMilestonesBySkill = (data and data.earnedMilestonesBySkill) or {}
    spentPointsBySkill = (data and data.spentPointsBySkill) or {}
    activePerks = (data and data.activePerks) or {}
    reconcileSaveState()
    grantRetroactiveMilestones()

    local totalEarned = 0
    local totalSpent = 0
    for _, skillID in ipairs(getSkillIds()) do
        totalEarned = totalEarned + earnedPoints(skillID)
        totalSpent = totalSpent + spentPoints(skillID)
    end

    print(string.format(
        "[%s] Loaded (skills=%d, activePerks=%d, earned=%d, spent=%d, available=%d)",
        MOD_NAME,
        #getSkillIds(),
        #activePerks,
        totalEarned,
        totalSpent,
        totalEarned - totalSpent
    ))
end

local function onSave()
    return {
        earnedMilestonesBySkill = earnedMilestonesBySkill,
        spentPointsBySkill = spentPointsBySkill,
        activePerks = activePerks,
    }
end

return {
    interfaceName = MOD_NAME .. "Player",
    interface = {
        earnedPoints = earnedPoints,
        spentPoints = spentPoints,
        availablePoints = availablePoints,
        hasPerk = hasPerk,
        getActivePerks = getActivePerks,
    },
    eventHandlers = {
        UiModeChanged = UiModeChanged,
        [MOD_NAME .. "addPerk"] = addPerk,
        [MOD_NAME .. "removePerk"] = removePerk,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = onLoad,
        onSave = onSave,
        onConsoleCommand = onConsoleCommand,
    }
}
