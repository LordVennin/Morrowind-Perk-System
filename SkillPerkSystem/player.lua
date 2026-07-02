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
local effectEnabledByPerkId = {}
local updateTimer = 0
local pointSourcesInitialized = false
local pendingReconcileAfterRegistry = false

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

local function getRequirementCheck(requirement)
    if type(requirement) == "function" then
        return requirement
    end
    if type(requirement) == "table" and type(requirement.check) == "function" then
        return requirement.check
    end
    return nil
end

local function requirementSatisfied(perk)
    for _, requirement in ipairs(perk.requirements or {}) do
        local check = getRequirementCheck(requirement)
        if check ~= nil and not check() then
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

    local requiresAny = node.requiresAny or {}
    if #requiresAny > 0 then
        local anyOwned = false
        for _, requiredID in ipairs(requiresAny) do
            if hasPerk(requiredID) then
                anyOwned = true
                break
            end
        end
        if not anyOwned then
            table.insert(missing, "ANY:" .. table.concat(requiresAny, "|"))
        end
    end
    return missing
end

local function applyEffectAcquire(effectID, context)
    local modApi = interfaces[MOD_NAME]
    if modApi ~= nil and type(modApi.applyEffectOnAcquire) == "function" then
        return modApi.applyEffectOnAcquire(effectID, context)
    end
    return effectsRegistry.onAcquire(effectID, context)
end

local function applyEffectRemove(effectID, context)
    local modApi = interfaces[MOD_NAME]
    if modApi ~= nil and type(modApi.applyEffectOnRemove) == "function" then
        return modApi.applyEffectOnRemove(effectID, context)
    end
    return effectsRegistry.onRemove(effectID, context)
end

local function getActivePerks()
    local out = {}
    for _, perkID in ipairs(activePerks) do
        table.insert(out, perkID)
    end
    return out
end

local function isPerkEffectEnabled(perkID)
    if not hasPerk(perkID) then
        return false
    end

    local savedState = effectEnabledByPerkId[perkID]
    if type(savedState) == "boolean" then
        return savedState
    end
    return true
end

local function setPerkEffectEnabledState(perkID, enabled)
    if type(enabled) ~= "boolean" then
        error("setPerkEffectEnabledState() requires enabled = boolean")
    end

    if enabled then
        effectEnabledByPerkId[perkID] = true
    else
        effectEnabledByPerkId[perkID] = false
    end
end

local function notifyPerkStateChanged(perkID, reason, enabled)
    if type(perkID) ~= "string" or perkID == "" then
        return
    end
    if pself ~= nil and type(pself.sendEvent) == "function" then
        pself:sendEvent(MOD_NAME .. "_PerkStateChanged", {
            perkID = perkID,
            reason = reason,
            enabled = enabled,
        })
    end
end

local function reconcileSaveState()
    local modApi = interfaces[MOD_NAME]
    if modApi == nil or type(modApi.getPerks) ~= "function" then
        print("[" .. MOD_NAME .. "] reconcileSaveState skipped: perk registry API unavailable")
        return
    end

    local perks = modApi.getPerks() or {}
    local registryPerkCount = 0
    for _, _ in pairs(perks) do
        registryPerkCount = registryPerkCount + 1
    end
    if registryPerkCount == 0 then
        print(string.format("[%s] reconcileSaveState deferred: loadedActive=%d registryPerks=%d dropped=0", MOD_NAME, #activePerks, registryPerkCount))
        return
    end

    local loadedActiveCount = #activePerks
    local droppedCount = 0
    local filteredActivePerks = {}
    local recomputedSpentBySkill = {}
    local filteredEffectEnabledByPerkId = {}

    for _, perkID in ipairs(activePerks) do
        local perk = perks[perkID]
        if perk ~= nil then
            table.insert(filteredActivePerks, perkID)
            recomputedSpentBySkill[perk.tab] = (recomputedSpentBySkill[perk.tab] or 0) + perk.cost
            local savedEffectEnabled = effectEnabledByPerkId[perkID]
            if type(savedEffectEnabled) == "boolean" then
                filteredEffectEnabledByPerkId[perkID] = savedEffectEnabled
            else
                filteredEffectEnabledByPerkId[perkID] = true
            end
        else
            droppedCount = droppedCount + 1
            print("[" .. MOD_NAME .. "] Dropping missing active perk from save: " .. tostring(perkID))
        end
    end

    activePerks = filteredActivePerks
    spentPointsBySkill = recomputedSpentBySkill
    effectEnabledByPerkId = filteredEffectEnabledByPerkId

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

    print(string.format(
        "[%s] reconcileSaveState complete: loadedActive=%d registryPerks=%d dropped=%d",
        MOD_NAME,
        loadedActiveCount,
        registryPerkCount,
        droppedCount
    ))
end

local function syncActivePerkRuntimeEffects()
    local modApi = interfaces[MOD_NAME]
    if modApi == nil or type(modApi.getPerks) ~= "function" then
        print("[" .. MOD_NAME .. "][warn] syncActivePerkRuntimeEffects skipped: perk registry API unavailable")
        return
    end

    local perks = modApi.getPerks() or {}
    for _, perkID in ipairs(activePerks) do
        local perk = perks[perkID]
        if perk == nil then
            print("[" .. MOD_NAME .. "][warn] syncActivePerkRuntimeEffects skipped unknown perk id: " .. tostring(perkID))
        else
            local enabled = isPerkEffectEnabled(perkID)
            if enabled then
                -- Clear any stale runtime state before reapplying restored effects.
                -- Some effect implementations are not strictly idempotent on acquire.
                applyEffectRemove(perk.effectId, { perkID = perkID, perk = perk, player = pself, restored = true, resync = true })
                applyEffectAcquire(perk.effectId, { perkID = perkID, perk = perk, player = pself, restored = true })
            else
                applyEffectRemove(perk.effectId, { perkID = perkID, perk = perk, player = pself, restored = true, disabled = true })
            end
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
    effectEnabledByPerkId[data.perkID] = true
    print(string.format(
        "[%s] Added perk=%s cost=%d available=%d totalAdded=%d totalSpent=%d",
        MOD_NAME,
        tostring(data.perkID),
        perk.cost,
        pointsLedger.getAvailablePoints(),
        pointsLedger.getTotalAdded(),
        pointsLedger.getTotalSpent()
    ))
    applyEffectAcquire(perk.effectId, { perkID = data.perkID, perk = perk, player = pself })
    notifyPerkStateChanged(data.perkID, "added", true)
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
            effectEnabledByPerkId[data.perkID] = nil
            applyEffectRemove(perk.effectId, { perkID = data.perkID, perk = perk, player = pself })
            notifyPerkStateChanged(data.perkID, "removed", false)
            return
        end
    end
end

local function togglePerkEffect(data)
    if type(data) ~= "table" or type(data.perkID) ~= "string" then
        error("togglePerkEffect() requires { perkID = string, enabled = boolean|nil }")
    end

    local perk = interfaces[MOD_NAME].getPerks()[data.perkID]
    if perk == nil then
        error("Unknown perk id: " .. tostring(data.perkID))
    end
    if not hasPerk(data.perkID) then
        print("[" .. MOD_NAME .. "] Cannot toggle effect for unowned perk " .. data.perkID)
        return false
    end

    local currentlyEnabled = isPerkEffectEnabled(data.perkID)
    local targetEnabled = type(data.enabled) == "boolean" and data.enabled or (not currentlyEnabled)
    if targetEnabled == currentlyEnabled then
        return currentlyEnabled
    end

    setPerkEffectEnabledState(data.perkID, targetEnabled)
    if targetEnabled then
        applyEffectAcquire(perk.effectId, { perkID = data.perkID, perk = perk, player = pself, reenabled = true })
    else
        applyEffectRemove(perk.effectId, { perkID = data.perkID, perk = perk, player = pself, disabled = true })
    end

    print(string.format("[%s] Perk effect toggled perk=%s enabled=%s", MOD_NAME, tostring(data.perkID), tostring(targetEnabled)))
    notifyPerkStateChanged(data.perkID, "toggled", targetEnabled)
    return targetEnabled
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
            if isPerkEffectEnabled(perkID) then
                applyEffectRemove(perk.effectId, { perkID = perkID, perk = perk, player = pself })
            end
            effectEnabledByPerkId[perkID] = nil
            removedCount = removedCount + 1
            notifyPerkStateChanged(perkID, "respec", false)
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

    if pendingReconcileAfterRegistry then
        local modApi = interfaces[MOD_NAME]
        local registryCount = 0
        if modApi ~= nil and type(modApi.getPerks) == "function" then
            local perks = modApi.getPerks() or {}
            for _, _ in pairs(perks) do
                registryCount = registryCount + 1
            end
        end

        if registryCount > 0 then
            reconcileSaveState()
            syncActivePerkRuntimeEffects()
            pendingReconcileAfterRegistry = false
            print(string.format("[%s] Delayed reconcileSaveState ran after perk registry became available", MOD_NAME))
        end
    end
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
    end
end


local function onInit()
    initializePointSources()
    print(string.format("[%s] Initialized point sources", MOD_NAME))
end

local function onLoad(data)
    local hasEarnedMilestonesBySkill = data ~= nil and data.earnedMilestonesBySkill ~= nil
    local hasSpentPointsBySkill = data ~= nil and data.spentPointsBySkill ~= nil
    local hasActivePerks = data ~= nil and data.activePerks ~= nil
    local hasPointsLedger = data ~= nil and data.pointsLedger ~= nil
    print(string.format(
        "[%s] onLoad data keys present: earnedMilestonesBySkill=%s spentPointsBySkill=%s activePerks=%s pointsLedger=%s",
        MOD_NAME,
        tostring(hasEarnedMilestonesBySkill),
        tostring(hasSpentPointsBySkill),
        tostring(hasActivePerks),
        tostring(hasPointsLedger)
    ))

    earnedMilestonesBySkill = (data and data.earnedMilestonesBySkill) or {}
    spentPointsBySkill = (data and data.spentPointsBySkill) or {}
    activePerks = (data and data.activePerks) or {}
    effectEnabledByPerkId = (data and data.effectEnabledByPerkId) or {}
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
        local migratedBalance = math.max(0, migratedEarned - migratedSpent)
        pointsLedger.importState({
            balance = migratedBalance,
            totalAdded = migratedEarned,
            totalSpent = migratedSpent,
            history = {
                {
                    id = 1,
                    type = "migration",
                    amount = migratedBalance,
                    reason = "Migrated legacy per-skill points to global ledger",
                    sourceId = "migration",
                },
            },
            nextEntryID = 2,
        })
        print(string.format(
            "[%s][warn] pointsLedger missing in save; using migration fallback (migratedEarned=%d, migratedSpent=%d, balance=%d)",
            MOD_NAME,
            migratedEarned,
            migratedSpent,
            migratedBalance
        ))
    end

    pointsLedger.emitPointSourceEvent("onUpdate", { dt = 0 })
    local modApi = interfaces[MOD_NAME]
    local registryCount = 0
    if modApi ~= nil and type(modApi.getPerks) == "function" then
        local perks = modApi.getPerks() or {}
        for _, _ in pairs(perks) do
            registryCount = registryCount + 1
        end
    end

    if registryCount > 0 and (not hasActivePerks or #activePerks == 0) then
        print(string.format(
            "[%s][warn] Save has missing/empty activePerks while perk registry contains entries (%d); this may indicate save incompatibility or version mismatch",
            MOD_NAME,
            registryCount
        ))
    end

    if registryCount == 0 then
        pendingReconcileAfterRegistry = true
        print(string.format("[%s] Delaying reconcileSaveState: perk registry is empty during onLoad", MOD_NAME))
    else
        pendingReconcileAfterRegistry = false
        reconcileSaveState()
        syncActivePerkRuntimeEffects()
    end

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
        effectEnabledByPerkId = effectEnabledByPerkId,
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
        isPerkEffectEnabled = isPerkEffectEnabled,
        setPerkEffectEnabled = togglePerkEffect,
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
        [MOD_NAME .. "togglePerkEffect"] = togglePerkEffect,
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
