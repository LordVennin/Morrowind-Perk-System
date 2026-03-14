local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")
local types = require("openmw.types")

local MOD_NAME = settings.MOD_NAME
local MILESTONE_STEP = settings.MILESTONE_STEP

local earnedMilestonesBySkill = {}
local spentPointsBySkill = {}
local activePerks = {}
local updateTimer = 0

local function getSkillIds()
    local out = {}
    for skillID, _ in pairs(core.stats.Skill.records) do
        table.insert(out, skillID)
    end
    table.sort(out)
    return out
end

local function skillBase(skillID)
    return types.NPC.stats.skills[skillID](pself).base
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

local function getActivePerks()
    local out = {}
    for _, perkID in ipairs(activePerks) do
        table.insert(out, perkID)
    end
    return out
end

local function grantRetroactiveMilestones()
    for _, skillID in ipairs(getSkillIds()) do
        local currentMilestones = milestonesForSkill(skillID)
        if currentMilestones > earnedPoints(skillID) then
            earnedMilestonesBySkill[skillID] = currentMilestones
        end
        if spentPointsBySkill[skillID] == nil then
            spentPointsBySkill[skillID] = 0
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

local function onConsoleCommand(mode, command, selectedObject)
    local lower = command:lower()
    if lower == "lua skillperks" then
        printSkillMenu(nil)
    elseif lower == "lua skillperksrespec" then
        respecAllPerks()
    elseif lower:sub(1, 15) == "lua skillperks " then
        local skillID = command:sub(16)
        printSkillMenu(skillID)
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

local function onLoad(data)
    earnedMilestonesBySkill = (data and data.earnedMilestonesBySkill) or {}
    spentPointsBySkill = (data and data.spentPointsBySkill) or {}
    activePerks = (data and data.activePerks) or {}
    grantRetroactiveMilestones()
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
