local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")
local types = require("openmw.types")
local effectsRegistry = require("scripts.SkillPerkSystem.effects_registry")
local pointsLedger = require("scripts.SkillPerkSystem.points")
local registryState = require("scripts.SkillPerkSystem.registry_state")

local MOD_NAME = settings.MOD_NAME
local DEBUG_LOGS = settings.DEBUG_LOGS == true

local earnedMilestonesBySkill = {}
local spentPointsBySkill = {}
local activePerks = {}
local updateTimer = 0
local pointSourcesInitialized = false

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

local function getRegisteredTabIds()
    local api = interfaces[MOD_NAME]
    if api ~= nil and type(api.getTabIDs) == "function" then
        return api.getTabIDs() or {}
    end
    return {}
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


local function playerLevel()
    local stat = types.Actor.stats.level(pself)
    if stat and type(stat.current) == "number" then
        return math.max(1, math.floor(stat.current))
    end

    return 1
end

local function sortedNumericKeys(map)
    local keys = {}
    for key, _ in pairs(map or {}) do
        if type(key) == "number" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    return keys
end

local function awardFromSource(sourceId, claimId, amount, reason)
    local beforeAvailable = pointsLedger.getAvailablePoints()
    local ok, resultOrErr = pointsLedger.claimAndAddPoints(sourceId, claimId, amount, reason)
    if ok then
        local afterAvailable = pointsLedger.getAvailablePoints()
        print(string.format(
            "[%s] Point grant OK source=%s claim=%s amount=%s available=%d->%d totalAdded=%d totalSpent=%d",
            MOD_NAME,
            tostring(sourceId),
            tostring(claimId),
            tostring(amount),
            beforeAvailable,
            afterAvailable,
            pointsLedger.getTotalAdded(),
            pointsLedger.getTotalSpent()
        ))
        debugPrint(string.format("Point source '%s' granted %d for claim '%s'", sourceId, amount, claimId))
    elseif resultOrErr ~= "already claimed" then
        print("[" .. MOD_NAME .. "] point source '" .. tostring(sourceId) .. "' failed claim='" .. tostring(claimId) .. "': " .. tostring(resultOrErr))
    else
        debugPrint(string.format(
            "Point grant skipped source=%s claim=%s reason=already claimed available=%d totalAdded=%d totalSpent=%d",
            tostring(sourceId),
            tostring(claimId),
            pointsLedger.getAvailablePoints(),
            pointsLedger.getTotalAdded(),
            pointsLedger.getTotalSpent()
        ))
    end
    return ok
end

local function earnedPoints(skillID)
    return earnedMilestonesBySkill[skillID] or 0
end

local function spentPoints(skillID)
    return spentPointsBySkill[skillID] or 0
end

local function availablePoints(skillID)
    -- Compatibility adapter during migration to global points.
    -- Keep the skillID arg for callers that still pass it.
    return pointsLedger.getAvailablePoints()
end

local function globalAvailablePoints()
    return pointsLedger.getAvailablePoints()
end

local function registerBuiltInPointSources()
    local pointSourceSettings = settings.POINT_SOURCES or {}
    local levelUpConfig = pointSourceSettings.levelUpRewards or {}
    local levelUpRewardsEnabled = settings.getLevelUpRewardsEnabled and settings.getLevelUpRewardsEnabled()
    if levelUpRewardsEnabled == nil then
        levelUpRewardsEnabled = (levelUpConfig.enabled ~= false)
    end
    if levelUpRewardsEnabled then
        pointsLedger.registerPointSource("level-up", {
            onUpdate = function(_)
                local pointsPerLevel = settings.getPointsPerLevel and settings.getPointsPerLevel() or (tonumber(levelUpConfig.pointsPerLevel) or 1)
                local firstRewardLevel = math.max(1, math.floor(tonumber(levelUpConfig.firstRewardLevel) or 2))
                local currentLevel = playerLevel()
                debugPrint(string.format(
                    "Level reward check playerLevel=%d firstRewardLevel=%d pointsPerLevel=%d available=%d",
                    currentLevel,
                    firstRewardLevel,
                    pointsPerLevel,
                    pointsLedger.getAvailablePoints()
                ))
                print("[SkillPerkSystem][LEVEL_DEBUG] playerLevel=" .. tostring(playerLevel()))
                for level = firstRewardLevel, currentLevel do
                    awardFromSource("level-up", "level:" .. tostring(level), pointsPerLevel, "Level up reward")
                end
            end,
        })
    end

    local milestoneConfig = pointSourceSettings.skillMilestoneRewards or {}
    if settings.getSkillMilestoneRewards ~= nil or milestoneConfig.enabled ~= false then
        pointsLedger.registerPointSource("skill-milestones", {
            onUpdate = function(_)
                local rewardsByLevel = settings.getSkillMilestoneRewards and settings.getSkillMilestoneRewards()
                    or milestoneConfig.rewardsBySkillLevel
                    or {
                        [50] = 1,
                        [75] = 1,
                        [100] = 1,
                    }
                for _, skillID in ipairs(getSkillIds()) do
                    local skillLevel = skillBase(skillID)
                    local grantedCount = 0
                    for _, milestone in ipairs(sortedNumericKeys(rewardsByLevel)) do
                        if skillLevel >= milestone then
                            local reward = rewardsByLevel[milestone]
                            if type(reward) == "number" and reward > 0 then
                                local claimId = skillID .. ":" .. tostring(milestone)
                                if awardFromSource("skill-milestones", claimId, reward, "Skill milestone reward") then
                                    grantedCount = grantedCount + reward
                                end
                            end
                        end
                    end
                    if grantedCount > 0 then
                        earnedMilestonesBySkill[skillID] = (earnedMilestonesBySkill[skillID] or 0) + grantedCount
                    end
                end
            end,
        })
    end

    local questConfig = pointSourceSettings.questCompletionRewards or {}
    if questConfig.enabled ~= false then
        pointsLedger.registerPointSource("quest-completion", {
            onQuestCompleted = function(data)
                local questId = type(data.questId) == "string" and data.questId or nil
                if questId == nil or questId == "" then
                    return
                end
                local points = tonumber(data.points) or tonumber(questConfig.defaultPoints) or 1
                if points <= 0 then
                    return
                end
                awardFromSource("quest-completion", "quest:" .. questId, points, "Quest completion reward")
            end,
        })
    end
end

local function registerExternalPointSources()
    for sourceId, source in pairs(registryState.getPointSources()) do
        if type(source) == "table" and type(source.handlers) == "table" then
            pointsLedger.registerPointSource(sourceId, source.handlers)
        end
    end
end

local function initializePointSources()
    if pointSourcesInitialized then
        return
    end

    registerBuiltInPointSources()
    registerExternalPointSources()
    pointSourcesInitialized = true
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

local function reconcileSaveState()
    local perks = interfaces[MOD_NAME].getPerks()
    local filteredActivePerks = {}
    local recomputedSpentBySkill = {}

    for _, perkID in ipairs(activePerks) do
        local perk = perks[perkID]
        if perk ~= nil then
            table.insert(filteredActivePerks, perkID)
            recomputedSpentBySkill[perk.tab] = (recomputedSpentBySkill[perk.tab] or 0) + perk.cost
        else
            print("[" .. MOD_NAME .. "] Dropping missing active perk from save: " .. tostring(perkID))
        end
    end

    activePerks = filteredActivePerks
    spentPointsBySkill = recomputedSpentBySkill

    local recomputedSpentTotal = 0
    for _, amount in pairs(spentPointsBySkill) do
        recomputedSpentTotal = recomputedSpentTotal + amount
    end

    local totalAdded = pointsLedger.getTotalAdded()
    local expectedBalance = math.max(0, totalAdded - recomputedSpentTotal)
    if pointsLedger.getAvailablePoints() ~= expectedBalance or pointsLedger.getTotalSpent() ~= recomputedSpentTotal then
        pointsLedger.importState({
            balance = expectedBalance,
            totalAdded = totalAdded,
            totalSpent = recomputedSpentTotal,
            history = pointsLedger.getHistory(),
            claimedRewardsBySource = pointsLedger.exportState().claimedRewardsBySource,
        })
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

    if globalAvailablePoints() < perk.cost then
        print("[" .. MOD_NAME .. "] Cannot add perk " .. data.perkID .. ": not enough global perk points (cost=" .. perk.cost .. ")")
        return
    end

    local spentOk = pointsLedger.spendPoints(perk.cost, data.perkID)
    if not spentOk then
        print("[" .. MOD_NAME .. "] Cannot add perk " .. data.perkID .. ": ledger rejected spend")
        return
    end

    table.insert(activePerks, data.perkID)
    spentPointsBySkill[perk.tab] = spentPoints(perk.tab) + perk.cost
    print(string.format(
        "[%s] Added perk=%s cost=%d available=%d totalAdded=%d totalSpent=%d",
        MOD_NAME,
        tostring(data.perkID),
        perk.cost,
        pointsLedger.getAvailablePoints(),
        pointsLedger.getTotalAdded(),
        pointsLedger.getTotalSpent()
    ))
    effectsRegistry.onAcquire(perk.effectId, { perkID = data.perkID, perk = perk, player = pself })
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
            spentPointsBySkill[perk.tab] = math.max(0, spentPoints(perk.tab) - perk.cost)
            pointsLedger.addPoints(perk.cost, "Perk removed", data.perkID)
            effectsRegistry.onRemove(perk.effectId, { perkID = data.perkID, perk = perk, player = pself })
            return
        end
    end
end

local function printSkillMenu(filterSkill)
    print("--- Skill Perk Menu ---")
    for _, skillID in ipairs(getRegisteredTabIds()) do
        if filterSkill == nil or filterSkill == "" or filterSkill == skillID then
            local base = type(types.NPC.stats.skills[skillID]) == "function" and skillBase(skillID) or -1
            local earned = earnedPoints(skillID)
            local spent = spentPoints(skillID)
            local available = availablePoints(skillID)
            print(string.format("%s | actorSkill=%d | milestones=%d | spent=%d | available=%d", skillID, base, earned, spent, available))

            local perkIds = interfaces[MOD_NAME].getPerkIDsForTab(skillID)
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
            refundsBySkill[perk.tab] = (refundsBySkill[perk.tab] or 0) + perk.cost
            effectsRegistry.onRemove(perk.effectId, { perkID = perkID, perk = perk, player = pself })
            removedCount = removedCount + 1
        else
            print("[" .. MOD_NAME .. "] Skipping unknown active perk during respec: " .. tostring(perkID))
        end
    end

    activePerks = {}
    for _, skillID in ipairs(getRegisteredTabIds()) do
        spentPointsBySkill[skillID] = 0
    end

    local refunded = 0
    for _, amount in pairs(refundsBySkill) do
        refunded = refunded + amount
    end
    if refunded > 0 then
        pointsLedger.addPoints(refunded, "Respec refund", "respec")
    end

    print("[" .. MOD_NAME .. "] Respec complete: removed " .. removedCount .. " perks")
    print("[" .. MOD_NAME .. "] Points refunded by skill:")
    for _, skillID in ipairs(getRegisteredTabIds()) do
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
    pointsLedger.emitPointSourceEvent("onUpdate", { dt = dt })
end

local function shouldShowUI()
    return globalAvailablePoints() > 0
end


local function UiModeChanged(data)
    if data.newMode ~= nil then
        return
    end

    local hasNCGDMW = interfaces.NCGDMW ~= nil
    if data.oldMode == "LevelUp" then
        -- Run point source update immediately when the level-up menu closes so
        -- newly-earned level rewards are available before checking shouldShowUI().
        pointsLedger.emitPointSourceEvent("onUpdate", { dt = 0 })
        if shouldShowUI() then
            pself:sendEvent(MOD_NAME .. "showPerkUI", {})
        else
            pself:sendEvent(MOD_NAME .. "closePerkUI", {})
        end
    elseif hasNCGDMW and data.oldMode == "Rest" then
        -- NCGDMW level progression can happen when resting; refresh points first.
        pointsLedger.emitPointSourceEvent("onUpdate", { dt = 0 })
        if shouldShowUI() then
            pself:sendEvent(MOD_NAME .. "showPerkUI", {})
        else
            pself:sendEvent(MOD_NAME .. "closePerkUI", {})
        end
    else
        pself:sendEvent(MOD_NAME .. "closePerkUI", {})
    end
end


local function onInit()
    initializePointSources()
    print(string.format("[%s] Initialized point sources", MOD_NAME))
end

local function onLoad(data)
    earnedMilestonesBySkill = (data and data.earnedMilestonesBySkill) or {}
    spentPointsBySkill = (data and data.spentPointsBySkill) or {}
    activePerks = (data and data.activePerks) or {}
    pointsLedger.importState((data and data.pointsLedger) or nil)

    initializePointSources()

    if data == nil or data.pointsLedger == nil then
        local migratedEarned = 0
        local migratedSpent = 0
        for _, amount in pairs(earnedMilestonesBySkill) do
            migratedEarned = migratedEarned + (tonumber(amount) or 0)
        end
        for _, amount in pairs(spentPointsBySkill) do
            migratedSpent = migratedSpent + (tonumber(amount) or 0)
        end
        pointsLedger.importState({
            balance = math.max(0, migratedEarned - migratedSpent),
            totalAdded = migratedEarned,
            totalSpent = migratedSpent,
            history = {
                {
                    id = 1,
                    type = "migration",
                    amount = math.max(0, migratedEarned - migratedSpent),
                    reason = "Migrated legacy per-skill points to global ledger",
                    sourceId = "migration",
                },
            },
            nextEntryID = 2,
        })
    end

    pointsLedger.emitPointSourceEvent("onUpdate", { dt = 0 })
    reconcileSaveState()

    print(string.format(
        "[%s] Loaded (skills=%d, activePerks=%d, totalAdded=%d, spent=%d, available=%d)",
        MOD_NAME,
        #getRegisteredTabIds(),
        #activePerks,
        pointsLedger.getTotalAdded(),
        pointsLedger.getTotalSpent(),
        pointsLedger.getAvailablePoints()
    ))
end

local function onQuestCompleted(data)
    pointsLedger.emitPointSourceEvent("onQuestCompleted", data or {})
end

local function onSave()
    return {
        earnedMilestonesBySkill = earnedMilestonesBySkill,
        spentPointsBySkill = spentPointsBySkill,
        activePerks = activePerks,
        pointsLedger = pointsLedger.exportState(),
    }
end

return {
    interfaceName = MOD_NAME .. "Player",
    interface = {
        earnedPoints = earnedPoints,
        spentPoints = spentPoints,
        availablePoints = availablePoints,
        globalAvailablePoints = globalAvailablePoints,
        hasPerk = hasPerk,
        getActivePerks = getActivePerks,
        addPoints = pointsLedger.addPoints,
        spendPoints = pointsLedger.spendPoints,
        getPointHistory = pointsLedger.getHistory,
        registerPointSource = pointsLedger.registerPointSource,
    },
    eventHandlers = {
        UiModeChanged = UiModeChanged,
        [MOD_NAME .. "addPerk"] = addPerk,
        [MOD_NAME .. "removePerk"] = removePerk,
        [MOD_NAME .. "questCompleted"] = onQuestCompleted,
    },
    engineHandlers = {
        onInit = onInit,
        onUpdate = onUpdate,
        onLoad = onLoad,
        onSave = onSave,
        onConsoleCommand = onConsoleCommand,
    }
}
