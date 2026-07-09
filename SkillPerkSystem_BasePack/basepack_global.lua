-- Consolidated GLOBAL runtime for SkillPerkSystem_BasePack.
-- Supersedes the former BasePack GLOBAL scripts listed in SkillPerkSystem_BasePack.omwscripts.

-- 1. shared requires/constants/helpers
local subsystems = {}

-- 2. shared event names/script path constants
local BASEPACK_ACTOR_TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/basepack_actor_target.lua"
local TARGET_SCRIPT_IDLE_EVENT = "SkillPerkSystem_BasePack_TargetScriptIdle"

-- 3. shared actor scanning/target attachment helpers
-- Target-side systems share one active-actor scan and one attached-target cache so idle state
-- changes do not require each subsystem to repeatedly walk world.activeActors.
local targetWatcher = {
    interval = 1.0,
    timer = 0,
    scanRequested = false,
    providers = {},
    providerOrder = {},
    attachedTargets = {},
}

local function registerTargetWatcherProvider(id, provider)
    if type(id) ~= "string" or id == "" or type(provider) ~= "table" then
        return
    end
    if targetWatcher.providers[id] == nil then
        targetWatcher.providerOrder[#targetWatcher.providerOrder + 1] = id
    end
    targetWatcher.providers[id] = provider
end

local function providerIsActive(provider)
    return provider ~= nil and type(provider.isActive) == "function" and provider.isActive() == true
end

local function anyTargetWatcherProviderActive()
    for _, id in ipairs(targetWatcher.providerOrder) do
        if providerIsActive(targetWatcher.providers[id]) then
            return true
        end
    end
    return false
end

local function isValidTargetWatcherActor(actor)
    local types = require("openmw.types")
    local world = require("openmw.world")
    local Actor = types.Actor
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    return type(actor.hasScript) == "function" and type(actor.addScript) == "function"
end

local function rememberAttachedTarget(actor)
    if actor ~= nil then
        targetWatcher.attachedTargets[actor] = true
    end
end

local function forgetAttachedTarget(actor)
    if actor ~= nil then
        targetWatcher.attachedTargets[actor] = nil
    end
end

local function sendActiveTargetWatcherStates(actor)
    if actor == nil or type(actor.sendEvent) ~= "function" then
        return
    end
    for _, id in ipairs(targetWatcher.providerOrder) do
        local provider = targetWatcher.providers[id]
        if providerIsActive(provider) and type(provider.sendState) == "function" then
            provider.sendState(actor)
        end
    end
end

local function sendTargetWatcherStateToAttached(provider)
    if provider == nil or type(provider.sendState) ~= "function" then
        return
    end
    for actor in pairs(targetWatcher.attachedTargets) do
        if isValidTargetWatcherActor(actor) and actor:hasScript(BASEPACK_ACTOR_TARGET_SCRIPT) then
            provider.sendState(actor)
        else
            forgetAttachedTarget(actor)
        end
    end
end

local function requestTargetWatcherRefresh()
    targetWatcher.scanRequested = true
    targetWatcher.timer = targetWatcher.interval
end

local function refreshCombinedTargetWatchers()
    if not anyTargetWatcherProviderActive() then
        targetWatcher.scanRequested = false
        return
    end

    local world = require("openmw.world")
    for _, actor in ipairs(world.activeActors) do
        if isValidTargetWatcherActor(actor) then
            if actor:hasScript(BASEPACK_ACTOR_TARGET_SCRIPT) then
                rememberAttachedTarget(actor)
                sendActiveTargetWatcherStates(actor)
            else
                actor:addScript(BASEPACK_ACTOR_TARGET_SCRIPT, {})
                rememberAttachedTarget(actor)
                sendActiveTargetWatcherStates(actor)
            end
        end
    end

    targetWatcher.scanRequested = false
end

local function onTargetWatcherProviderStateChanged(id, active)
    local provider = targetWatcher.providers[id]
    if active == true then
        requestTargetWatcherRefresh()
    else
        sendTargetWatcherStateToAttached(provider)
    end
end

local function removeIdleTargetScript(data)
    if type(data) ~= "table" then
        return
    end
    local target = data.target
    if target == nil or type(target.isValid) ~= "function" or not target:isValid() then
        forgetAttachedTarget(target)
        return
    end
    if type(target.hasScript) ~= "function" or not target:hasScript(BASEPACK_ACTOR_TARGET_SCRIPT) then
        forgetAttachedTarget(target)
        return
    end
    if type(target.removeScript) == "function" then
        target:removeScript(BASEPACK_ACTOR_TARGET_SCRIPT)
        forgetAttachedTarget(target)
    end
end

subsystems.shared_target_watcher = {
    eventHandlers = {
        [TARGET_SCRIPT_IDLE_EVENT] = removeIdleTargetScript,
    },
    engineHandlers = {
        onUpdate = function(dt)
            if not anyTargetWatcherProviderActive() then
                targetWatcher.timer = 0
                targetWatcher.scanRequested = false
                return
            end

            targetWatcher.timer = targetWatcher.timer + (tonumber(dt) or 0)
            if targetWatcher.scanRequested or targetWatcher.timer >= targetWatcher.interval then
                targetWatcher.timer = 0
                refreshCombinedTargetWatchers()
            end
        end,
        onLoad = requestTargetWatcherRefresh,
    },
}

-- 4. security global hooks
do
-- Begin consolidated from SkillPerkSystem_BasePack/global.lua
local steadyHandsEffect = require("scripts.SkillPerkSystem_BasePack.perks.security.steady_hands_effect")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local MODIFY_SECURITY_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_ModifySecurityToolCondition"
local MODIFY_REPAIR_TOOL_CONDITION_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_ModifyRepairToolCondition"
local CAREFUL_REPAIRS_REFUND_RESULT_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_RefundResult"
local APPRENTICE_HAMMER_OVERREPAIR_REQUEST_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest"
local APPRENTICE_HAMMER_OVERREPAIR_RESULT_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairResult"
local WEAPON_TEMPER_REQUEST_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Request"
local WEAPON_TEMPER_RESULT_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Result"
local ARMOR_REFIT_REQUEST_EVENT = "SkillPerkSystem_BasePack_ArmorRefit_Request"
local ARMOR_REFIT_RESULT_EVENT = "SkillPerkSystem_BasePack_ArmorRefit_Result"
local MASTERWORK_REQUEST_EVENT = "SkillPerkSystem_BasePack_Masterwork_Request"
local MASTERWORK_RESULT_EVENT = "SkillPerkSystem_BasePack_Masterwork_Result"
local TEMPER_STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_WeaponTemper"
local TEMPERED_WEAPONS_KEY = "temperedWeapons"
local REFITTED_ARMOR_KEY = "refittedArmor"
local DRAIN_LOCKPICK_EVENT = "DrainLockpick"
local TUMBLER_SENSE_FAILURE_EVENT = "SkillPerkSystem_BasePack_TumblerSense_Failure"
local STEADY_HANDS_TOOL_DRAIN_EVENT = "SkillPerkSystem_BasePack_SteadyHands_ToolDrain"
local TUMBLER_SENSE_FAILURE_SOURCE = "drain_lockpick_event"

local temperStorage = storage.globalSection(TEMPER_STORAGE_SECTION_ID)

local function classifySecurityTool(item)
    if item == nil then
        return nil
    end
    if types.Lockpick.objectIsInstance(item) then
        return "Lockpick"
    end
    if types.Probe.objectIsInstance(item) then
        return "Probe"
    end
    return nil
end

local function apprenticeHammerLog(message)
    print("[SkillPerkSystem_BasePack][ApprenticeHammer][Global] " .. tostring(message))
end

local function sendOverrepairResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(APPRENTICE_HAMMER_OVERREPAIR_RESULT_EVENT, result)
    end
end

local function safeGetRecordField(record, fieldName)
    if record == nil then return nil end

    local okField, value = pcall(function()
        return record[fieldName]
    end)
    if okField then
        return value
    end
    return nil
end

local function getEquipmentRecord(item)
    if item == nil then return nil end

    if types.Weapon.objectIsInstance(item) then
        local okRecord, record = pcall(types.Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Weapon.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    elseif types.Armor.objectIsInstance(item) then
        local okRecord, record = pcall(types.Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        local recordId = item.recordId
        if type(recordId) == "string" and recordId ~= "" then
            local okById, recordById = pcall(function()
                return types.Armor.records[recordId]
            end)
            if okById then
                return recordById
            end
        end
    end

    return nil
end

local function getEquipmentMaxCondition(item)
    local record = getEquipmentRecord(item)
    return tonumber(safeGetRecordField(record, "health") or safeGetRecordField(record, "maxCondition"))
end

local function isAtNormalMaxCondition(currentCondition, maxCondition)
    if type(currentCondition) ~= "number" or type(maxCondition) ~= "number" then
        return false
    end

    local currentRounded = math.floor(currentCondition + 0.5)
    local maxRounded = math.floor(maxCondition + 0.5)
    return currentRounded == maxRounded
end

local function getObjectCount(item)
    if item == nil then return 1 end

    local okCount, count = pcall(function()
        return item.count
    end)
    if okCount and type(count) == "number" and count > 0 then
        return count
    end

    return 1
end

local function splitOneFromStack(item)
    if getObjectCount(item) <= 1 then
        return item, false
    end

    local okSplit, splitItem = pcall(function()
        return item:split(1)
    end)
    if okSplit and splitItem ~= nil then
        return splitItem, true
    end

    return nil, false
end

local function moveIntoPlayerInventory(player, item)
    if player == nil or item == nil then
        return false
    end

    local okInventory, inventory = pcall(types.Actor.inventory, player)
    if not okInventory or inventory == nil then
        return false
    end

    local okMove = pcall(function()
        item:moveInto(inventory)
    end)
    return okMove
end

local function overrepairFailure(player, reason, message, recordId)
    apprenticeHammerLog("overrepair failed reason=" .. tostring(reason) .. " recordId=" .. tostring(recordId))
    sendOverrepairResult(player, {
        success = false,
        reason = reason,
        message = message,
        recordId = recordId,
    })
end

local function applyApprenticeHammerOverrepair(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local repairTool = data.repairTool
    local targetItem = data.targetItem
    local recordId = targetItem ~= nil and targetItem.recordId or nil
    local targetName = data.targetName or recordId or "Item"
    local usesCost = tonumber(data.usesCost) or 5
    local multiplier = tonumber(data.multiplier) or 1.10

    if player == nil then
        overrepairFailure(nil, "missing_player", "That item could not be over-repaired.", recordId)
        return
    end
    if repairTool == nil or not types.Repair.objectIsInstance(repairTool) then
        overrepairFailure(player, "missing_repair_tool", "No repair tool found.", recordId)
        return
    end
    if targetItem == nil or not (types.Weapon.objectIsInstance(targetItem) or types.Armor.objectIsInstance(targetItem)) then
        overrepairFailure(player, "missing_target", "That item is no longer eligible.", recordId)
        return
    end

    local repairToolData = types.Item.itemData(repairTool)
    local repairToolCondition = repairToolData ~= nil and repairToolData.condition or nil
    local sourceTargetData = types.Item.itemData(targetItem)
    local currentCondition = sourceTargetData ~= nil and sourceTargetData.condition or nil
    local maxCondition = getEquipmentMaxCondition(targetItem)

    if type(repairToolCondition) ~= "number" or repairToolCondition < usesCost then
        overrepairFailure(player, "not_enough_tool_uses", "Not enough hammer uses remaining (need 5).", recordId)
        return
    end
    if sourceTargetData == nil or type(currentCondition) ~= "number" then
        overrepairFailure(player, "missing_target_condition", "That item could not be over-repaired.", recordId)
        return
    end
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        overrepairFailure(player, "missing_max_condition", "That item could not be over-repaired.", recordId)
        return
    end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then
        if currentCondition > maxCondition then
            overrepairFailure(player, "target_already_overrepaired", "That item is already over-repaired.", recordId)
        else
            overrepairFailure(player, "target_not_at_normal_max", "That item is no longer eligible.", recordId)
        end
        return
    end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then
        overrepairFailure(player, "target_condition_not_higher", "That item could not be over-repaired.", recordId)
        return
    end

    local remainingToolCondition = repairToolCondition - usesCost
    local targetStackCount = getObjectCount(targetItem)
    local repairToolStackCount = getObjectCount(repairTool)
    local targetStackSplit = false
    local repairToolStackSplit = false
    local okWrite, err = pcall(function()
        local targetToModify = targetItem
        if targetStackCount > 1 then
            targetToModify, targetStackSplit = splitOneFromStack(targetItem)
            if targetToModify == nil then
                error("failed to split target stack")
            end
        end

        local targetData = types.Item.itemData(targetToModify)
        if targetData == nil then
            error("split target has no item data")
        end
        targetData.condition = targetCondition
        if targetStackSplit and not moveIntoPlayerInventory(player, targetToModify) then
            error("failed to move split target back into player inventory")
        end

        if remainingToolCondition <= 0 then
            repairTool:remove(1)
        else
            local repairToolToModify = repairTool
            local writableRepairToolData = repairToolData
            if repairToolStackCount > 1 then
                repairToolToModify, repairToolStackSplit = splitOneFromStack(repairTool)
                if repairToolToModify == nil then
                    error("failed to split repair tool stack")
                end
                writableRepairToolData = types.Item.itemData(repairToolToModify)
                if writableRepairToolData == nil then
                    error("split repair tool has no item data")
                end
            end
            writableRepairToolData.condition = remainingToolCondition
            if repairToolStackSplit and not moveIntoPlayerInventory(player, repairToolToModify) then
                error("failed to move split repair tool back into player inventory")
            end
        end
    end)
    if not okWrite then
        overrepairFailure(player, "write_failed", "That item could not be over-repaired.", recordId)
        apprenticeHammerLog("overrepair write failed err=" .. tostring(err) .. " recordId=" .. tostring(recordId))
        return
    end

    apprenticeHammerLog("overrepair success recordId=" .. tostring(recordId) .. " target=" .. tostring(targetCondition) .. " toolUses=" .. tostring(math.max(remainingToolCondition, 0)) .. " toolRemoved=" .. tostring(remainingToolCondition <= 0) .. " targetSplit=" .. tostring(targetStackSplit) .. " repairToolSplit=" .. tostring(repairToolStackSplit))
    sendOverrepairResult(player, {
        success = true,
        recordId = recordId,
        name = targetName,
        targetCondition = targetCondition,
        repairToolCondition = math.max(remainingToolCondition, 0),
        repairToolRemoved = remainingToolCondition <= 0,
        targetStackSplit = targetStackSplit,
        repairToolStackSplit = repairToolStackSplit,
    })
end

local function weaponTemperLog(message)
    print("[SkillPerkSystem_BasePack][WeaponTemper][Global] " .. tostring(message))
end

local function sendWeaponTemperResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(WEAPON_TEMPER_RESULT_EVENT, result)
    end
end

local function weaponTemperFailure(player, reason, message, recordId)
    weaponTemperLog("failed reason=" .. tostring(reason) .. " recordId=" .. tostring(recordId))
    sendWeaponTemperResult(player, {
        success = false,
        reason = reason,
        message = message,
        recordId = recordId,
    })
end

local function armorRefitLog(message)
    print("[SkillPerkSystem_BasePack][ArmorRefit][Global] " .. tostring(message))
end

local function sendArmorRefitResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(ARMOR_REFIT_RESULT_EVENT, result)
    end
end

local function armorRefitFailure(player, reason, message, recordId)
    armorRefitLog("failed reason=" .. tostring(reason) .. " recordId=" .. tostring(recordId))
    sendArmorRefitResult(player, {
        success = false,
        reason = reason,
        message = message,
        recordId = recordId,
    })
end

local function masterworkLog(message)
    print("[SkillPerkSystem_BasePack][Masterwork][Global] " .. tostring(message))
end

local function sendMasterworkResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(MASTERWORK_RESULT_EVENT, result)
    end
end

local function masterworkFailure(player, reason, message, recordId)
    masterworkLog("failed reason=" .. tostring(reason) .. " recordId=" .. tostring(recordId))
    sendMasterworkResult(player, {
        success = false,
        reason = reason,
        message = message,
        recordId = recordId,
    })
end

local function getTemperedWeaponRecords()
    local records = temperStorage:get(TEMPERED_WEAPONS_KEY)
    if type(records) ~= "table" then
        records = {}
    end
    if type(records.byGeneratedName) ~= "table" then
        records.byGeneratedName = {}
    end
    return records
end

local function setTemperedWeaponRecords(records)
    temperStorage:set(TEMPERED_WEAPONS_KEY, records)
end

local function getRefittedArmorRecords()
    local records = temperStorage:get(REFITTED_ARMOR_KEY)
    if type(records) ~= "table" then
        records = {}
    end
    if type(records.byGeneratedName) ~= "table" then
        records.byGeneratedName = {}
    end
    return records
end

local function setRefittedArmorRecords(records)
    temperStorage:set(REFITTED_ARMOR_KEY, records)
end

local function inferMasterworkModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Masterwork " then
        return "masterwork"
    end
    return nil
end

local function stripMasterworkPrefix(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Masterwork " then
        return string.sub(name, 12)
    end
    return nil
end

local function inferTemperModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 6) == "Honed " then
        return "honed"
    elseif string.sub(name, 1, 9) == "Hardened " then
        return "hardened"
    end
    return nil
end

local function stripTemperPrefix(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 6) == "Honed " then
        return string.sub(name, 7)
    elseif string.sub(name, 1, 9) == "Hardened " then
        return string.sub(name, 10)
    end
    return nil
end

local function inferArmorRefitModeFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Reinforced " then
        return "reinforced"
    elseif string.sub(name, 1, 8) == "Trimmed " then
        return "trimmed"
    end
    return nil
end

local function stripArmorRefitPrefix(name)
    if type(name) ~= "string" then
        return nil
    end
    if string.sub(name, 1, 11) == "Reinforced " then
        return string.sub(name, 12)
    elseif string.sub(name, 1, 8) == "Trimmed " then
        return string.sub(name, 9)
    end
    return nil
end

local function findWeaponRecordIdByName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local okPairs, foundId = pcall(function()
        for id, record in pairs(types.Weapon.records) do
            if safeGetRecordField(record, "name") == name then
                return id
            end
        end
        return nil
    end)

    if okPairs and type(foundId) == "string" and foundId ~= "" then
        return foundId
    end
    return nil
end

local function findArmorRecordIdByName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local okPairs, foundId = pcall(function()
        for id, record in pairs(types.Armor.records) do
            if safeGetRecordField(record, "name") == name then
                return id
            end
        end
        return nil
    end)

    if okPairs and type(foundId) == "string" and foundId ~= "" then
        return foundId
    end
    return nil
end

local function getTemperedWeaponEntry(records, recordId, recordName)
    local entry = records[recordId]
    if type(entry) == "table" then
        return entry
    end

    local byName = records.byGeneratedName
    if type(byName) == "table" and type(recordName) == "string" then
        entry = byName[recordName]
        if type(entry) == "table" then
            records[recordId] = entry
            return entry
        end
    end

    return nil
end

local function getRefittedArmorEntry(records, recordId, recordName)
    local entry = records[recordId]
    if type(entry) == "table" then
        return entry
    end

    local byName = records.byGeneratedName
    if type(byName) == "table" and type(recordName) == "string" then
        entry = byName[recordName]
        if type(entry) == "table" then
            records[recordId] = entry
            return entry
        end
    end

    return nil
end

local function getWeaponRecord(item)
    if item == nil then return nil end
    local okRecord, record = pcall(types.Weapon.record, item)
    if okRecord and record ~= nil then
        return record
    end
    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        local okById, recordById = pcall(function()
            return types.Weapon.records[recordId]
        end)
        if okById then
            return recordById
        end
    end
    return nil
end

local function getArmorRecord(item)
    if item == nil then return nil end
    local okRecord, record = pcall(types.Armor.record, item)
    if okRecord and record ~= nil then
        return record
    end
    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        local okById, recordById = pcall(function()
            return types.Armor.records[recordId]
        end)
        if okById then
            return recordById
        end
    end
    return nil
end

local function recordNumber(record, fieldName, fallback)
    local value = tonumber(safeGetRecordField(record, fieldName))
    if type(value) == "number" then
        return value
    end
    return fallback
end

local function scaleDamage(value, multiplier)
    local n = math.floor((tonumber(value) or 0) * multiplier + 0.5)
    if n < 0 then n = 0 end
    return n
end

local function cloneWeaponStats(record)
    return {
        name = safeGetRecordField(record, "name"),
        model = safeGetRecordField(record, "model"),
        icon = safeGetRecordField(record, "icon"),
        mwscript = safeGetRecordField(record, "mwscript"),
        type = safeGetRecordField(record, "type"),
        weight = recordNumber(record, "weight", 0),
        value = recordNumber(record, "value", 0),
        health = recordNumber(record, "health", 1),
        speed = recordNumber(record, "speed", 1),
        reach = recordNumber(record, "reach", 1),
        enchant = safeGetRecordField(record, "enchant"),
        enchantCapacity = recordNumber(record, "enchantCapacity", 0),
        isMagical = safeGetRecordField(record, "isMagical") == true,
        isSilver = safeGetRecordField(record, "isSilver") == true,
        chopMinDamage = recordNumber(record, "chopMinDamage", 0),
        chopMaxDamage = recordNumber(record, "chopMaxDamage", 0),
        slashMinDamage = recordNumber(record, "slashMinDamage", 0),
        slashMaxDamage = recordNumber(record, "slashMaxDamage", 0),
        thrustMinDamage = recordNumber(record, "thrustMinDamage", 0),
        thrustMaxDamage = recordNumber(record, "thrustMaxDamage", 0),
    }
end

local function cloneArmorStats(record)
    return {
        name = safeGetRecordField(record, "name"),
        model = safeGetRecordField(record, "model"),
        icon = safeGetRecordField(record, "icon"),
        mwscript = safeGetRecordField(record, "mwscript"),
        type = safeGetRecordField(record, "type"),
        weight = recordNumber(record, "weight", 0),
        value = recordNumber(record, "value", 0),
        health = recordNumber(record, "health", 1),
        baseArmor = recordNumber(record, "baseArmor", 0),
        enchant = safeGetRecordField(record, "enchant"),
        enchantCapacity = recordNumber(record, "enchantCapacity", 0),
    }
end

local function applyTemperToStats(base, mode)
    local out = {}
    for key, value in pairs(base) do
        out[key] = value
    end

    if mode == "honed" then
        out.name = "Honed " .. tostring(base.name or "Weapon")
        out.weight = math.max(0.01, (tonumber(base.weight) or 0) * 0.90)
        out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 0.75 + 0.5))
        out.chopMinDamage = scaleDamage(base.chopMinDamage, 1.10)
        out.chopMaxDamage = scaleDamage(base.chopMaxDamage, 1.10)
        out.slashMinDamage = scaleDamage(base.slashMinDamage, 1.10)
        out.slashMaxDamage = scaleDamage(base.slashMaxDamage, 1.10)
        out.thrustMinDamage = scaleDamage(base.thrustMinDamage, 1.10)
        out.thrustMaxDamage = scaleDamage(base.thrustMaxDamage, 1.10)
    elseif mode == "hardened" then
        out.name = "Hardened " .. tostring(base.name or "Weapon")
        out.weight = math.max(0.01, (tonumber(base.weight) or 0) * 1.15)
        out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 1.40 + 0.5))
        out.chopMinDamage = scaleDamage(base.chopMinDamage, 0.95)
        out.chopMaxDamage = scaleDamage(base.chopMaxDamage, 0.95)
        out.slashMinDamage = scaleDamage(base.slashMinDamage, 0.95)
        out.slashMaxDamage = scaleDamage(base.slashMaxDamage, 0.95)
        out.thrustMinDamage = scaleDamage(base.thrustMinDamage, 0.95)
        out.thrustMaxDamage = scaleDamage(base.thrustMaxDamage, 0.95)
    end

    if type(base.enchant) ~= "string" or base.enchant == "" then
        out.enchant = nil
        out.enchantCapacity = 0
        out.isMagical = false
    end

    out.value = math.max(0, math.floor((tonumber(base.value) or 0) * 1.10 + 0.5))
    return out
end

local function scaleArmorRating(value, multiplier)
    local n = math.floor((tonumber(value) or 0) * multiplier + 0.5)
    if n < 0 then n = 0 end
    return n
end

local function applyMasterworkToWeaponStats(base)
    local out = {}
    for key, value in pairs(base) do
        out[key] = value
    end
    out.name = "Masterwork " .. tostring(base.name or "Weapon")
    out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 1.25 + 0.5))
    out.chopMinDamage = scaleDamage(base.chopMinDamage, 1.15)
    out.chopMaxDamage = scaleDamage(base.chopMaxDamage, 1.15)
    out.slashMinDamage = scaleDamage(base.slashMinDamage, 1.15)
    out.slashMaxDamage = scaleDamage(base.slashMaxDamage, 1.15)
    out.thrustMinDamage = scaleDamage(base.thrustMinDamage, 1.15)
    out.thrustMaxDamage = scaleDamage(base.thrustMaxDamage, 1.15)
    if type(base.enchant) ~= "string" or base.enchant == "" then
        out.enchant = nil
        out.enchantCapacity = 0
        out.isMagical = false
    end
    return out
end

local function applyMasterworkToArmorStats(base)
    local out = {}
    for key, value in pairs(base) do
        out[key] = value
    end
    out.name = "Masterwork " .. tostring(base.name or "Armor")
    out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 1.25 + 0.5))
    out.baseArmor = scaleArmorRating(base.baseArmor, 1.15)
    if type(base.enchant) ~= "string" or base.enchant == "" then
        out.enchant = nil
        out.enchantCapacity = 0
    end
    return out
end

local function applyArmorRefitToStats(base, mode)
    local out = {}
    for key, value in pairs(base) do
        out[key] = value
    end

    if mode == "reinforced" then
        out.name = "Reinforced " .. tostring(base.name or "Armor")
        out.weight = math.max(0.01, (tonumber(base.weight) or 0) * 1.20)
        out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 1.15 + 0.5))
        out.baseArmor = scaleArmorRating(base.baseArmor, 1.07)
    elseif mode == "trimmed" then
        out.name = "Trimmed " .. tostring(base.name or "Armor")
        out.weight = math.max(0.01, (tonumber(base.weight) or 0) * 0.80)
        out.health = math.max(1, math.floor((tonumber(base.health) or 1) * 0.80 + 0.5))
        out.baseArmor = scaleArmorRating(base.baseArmor, 0.90)
    end

    if type(base.enchant) ~= "string" or base.enchant == "" then
        out.enchant = nil
        out.enchantCapacity = 0
    end

    return out
end

local function weaponDraftFromStats(template, stats)
    return types.Weapon.createRecordDraft({
        template = template,
        name = stats.name,
        model = stats.model,
        icon = stats.icon,
        mwscript = stats.mwscript,
        type = stats.type,
        weight = stats.weight,
        value = stats.value,
        health = stats.health,
        speed = stats.speed,
        reach = stats.reach,
        enchant = stats.enchant,
        enchantCapacity = stats.enchantCapacity,
        isMagical = stats.isMagical,
        isSilver = stats.isSilver,
        chopMinDamage = stats.chopMinDamage,
        chopMaxDamage = stats.chopMaxDamage,
        slashMinDamage = stats.slashMinDamage,
        slashMaxDamage = stats.slashMaxDamage,
        thrustMinDamage = stats.thrustMinDamage,
        thrustMaxDamage = stats.thrustMaxDamage,
    })
end

local function armorDraftFromStats(template, stats)
    return types.Armor.createRecordDraft({
        template = template,
        name = stats.name,
        model = stats.model,
        icon = stats.icon,
        mwscript = stats.mwscript,
        type = stats.type,
        weight = stats.weight,
        value = stats.value,
        health = stats.health,
        baseArmor = stats.baseArmor,
        enchant = stats.enchant,
        enchantCapacity = stats.enchantCapacity,
    })
end

local function createdRecordId(createdRecord)
    if type(createdRecord) == "string" then
        return createdRecord
    end
    if createdRecord ~= nil then
        local okId, idValue = pcall(function()
            return createdRecord.id
        end)
        if okId and type(idValue) == "string" and idValue ~= "" then
            return idValue
        end
    end
    return nil
end

local function copyItemRuntimeData(sourceItem, targetItem, sourceMaxCondition, targetMaxCondition)
    local sourceData = types.Item.itemData(sourceItem)
    local targetData = types.Item.itemData(targetItem)
    if sourceData == nil or targetData == nil then
        return
    end

    local currentCondition = sourceData.condition
    if type(currentCondition) == "number" and type(sourceMaxCondition) == "number" and sourceMaxCondition > 0 and type(targetMaxCondition) == "number" then
        targetData.condition = math.max(1, math.floor((currentCondition / sourceMaxCondition) * targetMaxCondition + 0.5))
    elseif type(currentCondition) == "number" then
        targetData.condition = currentCondition
    end

    pcall(function()
        targetData.enchantmentCharge = sourceData.enchantmentCharge
    end)
    pcall(function()
        targetData.soul = sourceData.soul
    end)
end

local function createWeaponForPlayer(player, recordId, sourceItem, sourceMaxCondition, targetMaxCondition)
    local created = world.createObject(recordId, 1)
    if created == nil then
        return nil, "create_object_failed"
    end
    copyItemRuntimeData(sourceItem, created, sourceMaxCondition, targetMaxCondition)
    if not moveIntoPlayerInventory(player, created) then
        return nil, "move_failed"
    end
    return created, nil
end

local function createArmorForPlayer(player, recordId, sourceItem, sourceMaxCondition, targetMaxCondition)
    local created = world.createObject(recordId, 1)
    if created == nil then
        return nil, "create_object_failed"
    end
    copyItemRuntimeData(sourceItem, created, sourceMaxCondition, targetMaxCondition)
    if not moveIntoPlayerInventory(player, created) then
        return nil, "move_failed"
    end
    return created, nil
end

local function applyWeaponTemper(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local targetItem = data.targetItem
    local mode = data.mode
    local recordId = targetItem ~= nil and targetItem.recordId or nil
    local targetName = data.targetName or recordId or "Weapon"

    if player == nil then
        weaponTemperFailure(nil, "missing_player", "That weapon could not be tempered.", recordId)
        return
    end
    if targetItem == nil or not types.Weapon.objectIsInstance(targetItem) then
        weaponTemperFailure(player, "missing_target", "That weapon is no longer eligible.", recordId)
        return
    end
    if mode ~= "honed" and mode ~= "hardened" and mode ~= "restore" then
        weaponTemperFailure(player, "invalid_mode", "That tempering option is invalid.", recordId)
        return
    end

    local records = getTemperedWeaponRecords()
    local sourceRecord = getWeaponRecord(targetItem)
    if sourceRecord == nil then
        weaponTemperFailure(player, "missing_record", "That weapon's record could not be read.", recordId)
        return
    end

    local sourceRecordName = safeGetRecordField(sourceRecord, "name") or targetName
    local requestGeneratedName = data.generatedName or targetName
    local existing = getTemperedWeaponEntry(records, recordId, sourceRecordName)
    if type(existing) ~= "table" and requestGeneratedName ~= sourceRecordName then
        existing = getTemperedWeaponEntry(records, recordId, requestGeneratedName)
    end
    if type(existing) ~= "table" and type(data.originalRecordId) == "string" and data.originalRecordId ~= "" then
        existing = {
            originalRecordId = data.originalRecordId,
            originalName = data.originalName,
            generatedRecordId = data.generatedRecordId or recordId,
            generatedName = requestGeneratedName,
            mode = inferTemperModeFromName(sourceRecordName) or inferTemperModeFromName(requestGeneratedName) or "tempered",
        }
    end
    local inferredMode = inferTemperModeFromName(sourceRecordName) or inferTemperModeFromName(requestGeneratedName)

    local sourceMaxCondition = recordNumber(sourceRecord, "health", nil)
    if type(sourceMaxCondition) ~= "number" or sourceMaxCondition <= 0 then
        weaponTemperFailure(player, "missing_condition", "That weapon could not be tempered.", recordId)
        return
    end

    if mode == "restore" then
        if type(existing) ~= "table" or type(existing.originalRecordId) ~= "string" then
            local strippedName = stripTemperPrefix(sourceRecordName) or stripTemperPrefix(requestGeneratedName)
            local inferredOriginalRecordId = findWeaponRecordIdByName(strippedName)
            if type(inferredOriginalRecordId) ~= "string" then
                weaponTemperFailure(player, "not_tempered", "That weapon has not been tempered or its original record could not be inferred.", recordId)
                return
            end
            existing = {
                originalRecordId = inferredOriginalRecordId,
                originalName = strippedName,
                generatedRecordId = recordId,
                generatedName = sourceRecordName,
                mode = inferredMode or "tempered",
            }
        end
        local originalRecord = types.Weapon.records[existing.originalRecordId]
        if originalRecord == nil then
            weaponTemperFailure(player, "missing_original", "The original weapon record could not be found.", recordId)
            return
        end
        local originalMaxCondition = recordNumber(originalRecord, "health", sourceMaxCondition)
        local okRestore, restoreErr = pcall(function()
            local restored, err = createWeaponForPlayer(player, existing.originalRecordId, targetItem, sourceMaxCondition, originalMaxCondition)
            if restored == nil then
                error(err or "restore_create_failed")
            end
            targetItem:remove(1)
        end)
        if not okRestore then
            weaponTemperFailure(player, "restore_failed", "That weapon could not be restored.", recordId)
            weaponTemperLog("restore failed err=" .. tostring(restoreErr))
            return
        end
        records[recordId] = nil
        if type(records.byGeneratedName) == "table" and type(existing.generatedName) == "string" then
            records.byGeneratedName[existing.generatedName] = nil
        end
        setTemperedWeaponRecords(records)
        sendWeaponTemperResult(player, {
            success = true,
            recordId = existing.originalRecordId,
            restoredRecordId = recordId,
            mode = "restore",
            message = tostring(existing.originalName or targetName) .. " has been restored.",
        })
        return
    end

    if type(existing) == "table" or inferredMode ~= nil then
        weaponTemperFailure(player, "already_tempered", "That weapon is already tempered. Restore it first.", recordId)
        return
    end

    if type(types.Weapon.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        weaponTemperFailure(player, "api_unavailable", "Weapon tempering is unavailable in this OpenMW version.", recordId)
        return
    end

    local baseStats = cloneWeaponStats(sourceRecord)
    local modifiedStats = applyTemperToStats(baseStats, mode)
    local okDraft, draft = pcall(weaponDraftFromStats, sourceRecord, modifiedStats)
    if not okDraft or draft == nil then
        weaponTemperFailure(player, "draft_failed", "That weapon could not be tempered.", recordId)
        weaponTemperLog("draft failed err=" .. tostring(draft))
        return
    end

    local okCreate, createdRecord = pcall(world.createRecord, draft)
    local generatedRecordId = okCreate and createdRecordId(createdRecord) or nil
    if type(generatedRecordId) ~= "string" or generatedRecordId == "" then
        weaponTemperFailure(player, "record_create_failed", "That weapon could not be tempered.", recordId)
        weaponTemperLog("create record failed err=" .. tostring(createdRecord))
        return
    end

    local okReplace, replaceErr = pcall(function()
        local created, err = createWeaponForPlayer(player, generatedRecordId, targetItem, sourceMaxCondition, modifiedStats.health)
        if created == nil then
            error(err or "create_failed")
        end
        targetItem:remove(1)
    end)
    if not okReplace then
        weaponTemperFailure(player, "replace_failed", "That weapon could not be tempered.", recordId)
        weaponTemperLog("replace failed err=" .. tostring(replaceErr))
        return
    end

    local entry = {
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedRecordId = generatedRecordId,
        generatedName = modifiedStats.name,
        mode = mode,
        original = baseStats,
        modified = modifiedStats,
    }
    records[generatedRecordId] = entry
    records.byGeneratedName[modifiedStats.name] = entry
    setTemperedWeaponRecords(records)

    local modeLabel = mode == "honed" and "honed" or "hardened"
    sendWeaponTemperResult(player, {
        success = true,
        recordId = generatedRecordId,
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedName = modifiedStats.name,
        mode = mode,
        message = tostring(targetName) .. " has been " .. modeLabel .. ".",
    })
end


local function applyArmorRefit(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local targetItem = data.targetItem
    local mode = data.mode
    local recordId = targetItem ~= nil and targetItem.recordId or nil
    local targetName = data.targetName or recordId or "Armor"

    if player == nil then
        armorRefitFailure(nil, "missing_player", "That armor could not be refitted.", recordId)
        return
    end
    if targetItem == nil or not types.Armor.objectIsInstance(targetItem) then
        armorRefitFailure(player, "missing_target", "That armor is no longer eligible.", recordId)
        return
    end
    if mode ~= "reinforced" and mode ~= "trimmed" and mode ~= "restore" then
        armorRefitFailure(player, "invalid_mode", "That armor refit option is invalid.", recordId)
        return
    end

    local records = getRefittedArmorRecords()
    local sourceRecord = getArmorRecord(targetItem)
    if sourceRecord == nil then
        armorRefitFailure(player, "missing_record", "That armor's record could not be read.", recordId)
        return
    end

    local sourceRecordName = safeGetRecordField(sourceRecord, "name") or targetName
    local requestGeneratedName = data.generatedName or targetName
    local existing = getRefittedArmorEntry(records, recordId, sourceRecordName)
    if type(existing) ~= "table" and requestGeneratedName ~= sourceRecordName then
        existing = getRefittedArmorEntry(records, recordId, requestGeneratedName)
    end
    if type(existing) ~= "table" and type(data.originalRecordId) == "string" and data.originalRecordId ~= "" then
        existing = {
            originalRecordId = data.originalRecordId,
            originalName = data.originalName,
            generatedRecordId = data.generatedRecordId or recordId,
            generatedName = requestGeneratedName,
            mode = inferArmorRefitModeFromName(sourceRecordName) or inferArmorRefitModeFromName(requestGeneratedName) or "refitted",
        }
    end
    local inferredMode = inferArmorRefitModeFromName(sourceRecordName) or inferArmorRefitModeFromName(requestGeneratedName)

    local sourceMaxCondition = recordNumber(sourceRecord, "health", nil)
    if type(sourceMaxCondition) ~= "number" or sourceMaxCondition <= 0 then
        armorRefitFailure(player, "missing_condition", "That armor could not be refitted.", recordId)
        return
    end

    if mode == "restore" then
        if type(existing) ~= "table" or type(existing.originalRecordId) ~= "string" then
            local strippedName = stripArmorRefitPrefix(sourceRecordName) or stripArmorRefitPrefix(requestGeneratedName)
            local inferredOriginalRecordId = findArmorRecordIdByName(strippedName)
            if type(inferredOriginalRecordId) ~= "string" then
                armorRefitFailure(player, "not_refitted", "That armor has not been refitted or its original record could not be inferred.", recordId)
                return
            end
            existing = {
                originalRecordId = inferredOriginalRecordId,
                originalName = strippedName,
                generatedRecordId = recordId,
                generatedName = sourceRecordName,
                mode = inferredMode or "refitted",
            }
        end
        local originalRecord = types.Armor.records[existing.originalRecordId]
        if originalRecord == nil then
            armorRefitFailure(player, "missing_original", "The original armor record could not be found.", recordId)
            return
        end
        local originalMaxCondition = recordNumber(originalRecord, "health", sourceMaxCondition)
        local okRestore, restoreErr = pcall(function()
            local restored, err = createArmorForPlayer(player, existing.originalRecordId, targetItem, sourceMaxCondition, originalMaxCondition)
            if restored == nil then
                error(err or "restore_create_failed")
            end
            targetItem:remove(1)
        end)
        if not okRestore then
            armorRefitFailure(player, "restore_failed", "That armor could not be restored.", recordId)
            armorRefitLog("restore failed err=" .. tostring(restoreErr))
            return
        end
        records[recordId] = nil
        if type(records.byGeneratedName) == "table" and type(existing.generatedName) == "string" then
            records.byGeneratedName[existing.generatedName] = nil
        end
        setRefittedArmorRecords(records)
        sendArmorRefitResult(player, {
            success = true,
            recordId = existing.originalRecordId,
            restoredRecordId = recordId,
            mode = "restore",
            message = tostring(existing.originalName or targetName) .. " has been restored.",
        })
        return
    end

    if type(existing) == "table" or inferredMode ~= nil then
        armorRefitFailure(player, "already_refitted", "That armor is already refitted. Restore it first.", recordId)
        return
    end

    if type(types.Armor.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        armorRefitFailure(player, "api_unavailable", "Armor refitting is unavailable in this OpenMW version.", recordId)
        return
    end

    local baseStats = cloneArmorStats(sourceRecord)
    local modifiedStats = applyArmorRefitToStats(baseStats, mode)
    local okDraft, draft = pcall(armorDraftFromStats, sourceRecord, modifiedStats)
    if not okDraft or draft == nil then
        armorRefitFailure(player, "draft_failed", "That armor could not be refitted.", recordId)
        armorRefitLog("draft failed err=" .. tostring(draft))
        return
    end

    local okCreate, createdRecord = pcall(world.createRecord, draft)
    local generatedRecordId = okCreate and createdRecordId(createdRecord) or nil
    if type(generatedRecordId) ~= "string" or generatedRecordId == "" then
        armorRefitFailure(player, "record_create_failed", "That armor could not be refitted.", recordId)
        armorRefitLog("create record failed err=" .. tostring(createdRecord))
        return
    end

    local okReplace, replaceErr = pcall(function()
        local created, err = createArmorForPlayer(player, generatedRecordId, targetItem, sourceMaxCondition, modifiedStats.health)
        if created == nil then
            error(err or "create_failed")
        end
        targetItem:remove(1)
    end)
    if not okReplace then
        armorRefitFailure(player, "replace_failed", "That armor could not be refitted.", recordId)
        armorRefitLog("replace failed err=" .. tostring(replaceErr))
        return
    end

    local entry = {
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedRecordId = generatedRecordId,
        generatedName = modifiedStats.name,
        mode = mode,
        original = baseStats,
        modified = modifiedStats,
    }
    records[generatedRecordId] = entry
    records.byGeneratedName[modifiedStats.name] = entry
    setRefittedArmorRecords(records)

    local modeLabel = mode == "reinforced" and "reinforced" or "trimmed"
    sendArmorRefitResult(player, {
        success = true,
        recordId = generatedRecordId,
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedName = modifiedStats.name,
        mode = mode,
        message = tostring(targetName) .. " has been " .. modeLabel .. ".",
    })
end

local function applyMasterwork(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local targetItem = data.targetItem
    local mode = data.mode
    local recordId = targetItem ~= nil and targetItem.recordId or nil
    local targetName = data.targetName or recordId or "Item"

    if player == nil then
        masterworkFailure(nil, "missing_player", "That item could not be masterworked.", recordId)
        return
    end
    local isWeapon = targetItem ~= nil and types.Weapon.objectIsInstance(targetItem)
    local isArmor = targetItem ~= nil and types.Armor.objectIsInstance(targetItem)
    if targetItem == nil or (not isWeapon and not isArmor) then
        masterworkFailure(player, "missing_target", "That item is no longer eligible.", recordId)
        return
    end
    if mode ~= "masterwork" and mode ~= "restore" then
        masterworkFailure(player, "invalid_mode", "That masterwork option is invalid.", recordId)
        return
    end

    local active = type(data.activeMasterwork) == "table" and data.activeMasterwork or nil
    local sourceRecord = isWeapon and getWeaponRecord(targetItem) or getArmorRecord(targetItem)
    if sourceRecord == nil then
        masterworkFailure(player, "missing_record", "That item's record could not be read.", recordId)
        return
    end

    local sourceRecordName = safeGetRecordField(sourceRecord, "name") or targetName
    local requestGeneratedName = data.generatedName or targetName
    local sourceMaxCondition = recordNumber(sourceRecord, "health", nil)
    if type(sourceMaxCondition) ~= "number" or sourceMaxCondition <= 0 then
        masterworkFailure(player, "missing_condition", "That item could not be masterworked.", recordId)
        return
    end

    if mode == "restore" then
        local existing = active
        if type(existing) ~= "table" and type(data.originalRecordId) == "string" and data.originalRecordId ~= "" then
            existing = {
                originalRecordId = data.originalRecordId,
                originalName = data.originalName,
                generatedRecordId = data.generatedRecordId or recordId,
                generatedName = requestGeneratedName,
                itemType = data.itemType or (isWeapon and "weapon" or "armor"),
                mode = "masterwork",
            }
        end
        if type(existing) ~= "table" or type(existing.originalRecordId) ~= "string" then
            local strippedName = stripMasterworkPrefix(sourceRecordName) or stripMasterworkPrefix(requestGeneratedName)
            local inferredOriginalRecordId = isWeapon and findWeaponRecordIdByName(strippedName) or findArmorRecordIdByName(strippedName)
            if type(inferredOriginalRecordId) ~= "string" then
                masterworkFailure(player, "not_masterworked", "That item has not been masterworked or its original record could not be inferred.", recordId)
                return
            end
            existing = {
                originalRecordId = inferredOriginalRecordId,
                originalName = strippedName,
                generatedRecordId = recordId,
                generatedName = sourceRecordName,
                itemType = isWeapon and "weapon" or "armor",
                mode = "masterwork",
            }
        end
        if existing.generatedRecordId ~= recordId and existing.generatedName ~= sourceRecordName then
            masterworkFailure(player, "wrong_masterwork", "Restore your active masterwork item first.", recordId)
            return
        end
        local originalRecord = existing.itemType == "armor" and types.Armor.records[existing.originalRecordId] or types.Weapon.records[existing.originalRecordId]
        if originalRecord == nil then
            masterworkFailure(player, "missing_original", "The original item record could not be found.", recordId)
            return
        end
        local originalMaxCondition = recordNumber(originalRecord, "health", sourceMaxCondition)
        local okRestore, restoreErr = pcall(function()
            local restored, err
            if existing.itemType == "armor" then
                restored, err = createArmorForPlayer(player, existing.originalRecordId, targetItem, sourceMaxCondition, originalMaxCondition)
            else
                restored, err = createWeaponForPlayer(player, existing.originalRecordId, targetItem, sourceMaxCondition, originalMaxCondition)
            end
            if restored == nil then
                error(err or "restore_create_failed")
            end
            targetItem:remove(1)
        end)
        if not okRestore then
            masterworkFailure(player, "restore_failed", "That item could not be restored.", recordId)
            masterworkLog("restore failed err=" .. tostring(restoreErr))
            return
        end
        sendMasterworkResult(player, {
            success = true,
            recordId = existing.originalRecordId,
            restoredRecordId = recordId,
            mode = "restore",
            message = tostring(existing.originalName or targetName) .. " has been restored.",
        })
        return
    end

    if type(active) == "table" then
        masterworkFailure(player, "already_masterworked", "Restore your current masterwork before choosing another item.", recordId)
        return
    end
    if inferMasterworkModeFromName(sourceRecordName) ~= nil or inferTemperModeFromName(sourceRecordName) ~= nil or inferArmorRefitModeFromName(sourceRecordName) ~= nil then
        masterworkFailure(player, "already_modified", "Restore that item before masterworking it.", recordId)
        return
    end

    if isWeapon and (type(types.Weapon.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function") then
        masterworkFailure(player, "api_unavailable", "Masterworking is unavailable in this OpenMW version.", recordId)
        return
    elseif isArmor and (type(types.Armor.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function") then
        masterworkFailure(player, "api_unavailable", "Masterworking is unavailable in this OpenMW version.", recordId)
        return
    end

    local baseStats = isWeapon and cloneWeaponStats(sourceRecord) or cloneArmorStats(sourceRecord)
    local modifiedStats = isWeapon and applyMasterworkToWeaponStats(baseStats) or applyMasterworkToArmorStats(baseStats)
    local okDraft, draft = pcall(isWeapon and weaponDraftFromStats or armorDraftFromStats, sourceRecord, modifiedStats)
    if not okDraft or draft == nil then
        masterworkFailure(player, "draft_failed", "That item could not be masterworked.", recordId)
        masterworkLog("draft failed err=" .. tostring(draft))
        return
    end

    local okCreate, createdRecord = pcall(world.createRecord, draft)
    local generatedRecordId = okCreate and createdRecordId(createdRecord) or nil
    if type(generatedRecordId) ~= "string" or generatedRecordId == "" then
        masterworkFailure(player, "record_create_failed", "That item could not be masterworked.", recordId)
        masterworkLog("create record failed err=" .. tostring(createdRecord))
        return
    end

    local okReplace, replaceErr = pcall(function()
        local created, err
        if isWeapon then
            created, err = createWeaponForPlayer(player, generatedRecordId, targetItem, sourceMaxCondition, modifiedStats.health)
        else
            created, err = createArmorForPlayer(player, generatedRecordId, targetItem, sourceMaxCondition, modifiedStats.health)
        end
        if created == nil then
            error(err or "create_failed")
        end
        targetItem:remove(1)
    end)
    if not okReplace then
        masterworkFailure(player, "replace_failed", "That item could not be masterworked.", recordId)
        masterworkLog("replace failed err=" .. tostring(replaceErr))
        return
    end

    local entry = {
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedRecordId = generatedRecordId,
        generatedName = modifiedStats.name,
        itemType = isWeapon and "weapon" or "armor",
        mode = "masterwork",
        original = baseStats,
        modified = modifiedStats,
    }
    sendMasterworkResult(player, {
        success = true,
        recordId = generatedRecordId,
        originalRecordId = recordId,
        originalName = baseStats.name,
        generatedName = modifiedStats.name,
        itemType = entry.itemType,
        mode = "masterwork",
        message = tostring(targetName) .. " has been masterworked.",
    })
end

local function sendCarefulRepairsRefundResult(player, result)
    if player ~= nil and type(player.sendEvent) == "function" then
        player:sendEvent(CAREFUL_REPAIRS_REFUND_RESULT_EVENT, result)
    end
end

local function repairToolMaxCondition(item)
    if item == nil then
        return nil
    end

    local okRecord, record = pcall(types.Repair.record, item)
    if okRecord and record ~= nil then
        local okMax, maxCondition = pcall(function()
            return record.maxCondition
        end)
        if okMax and type(maxCondition) == "number" then
            return maxCondition
        end
    end

    local recordId = item.recordId
    if type(recordId) == "string" and recordId ~= "" then
        local okById, recordById = pcall(function()
            return types.Repair.records[recordId]
        end)
        if okById and recordById ~= nil then
            local okMax, maxCondition = pcall(function()
                return recordById.maxCondition
            end)
            if okMax and type(maxCondition) == "number" then
                return maxCondition
            end
        end
    end

    return nil
end

local function findRepairToolInInventory(player, recordId)
    if player == nil or type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local okInventory, inventory = pcall(types.Actor.inventory, player)
    if not okInventory or inventory == nil then
        return nil
    end

    if type(inventory.find) == "function" then
        local okFind, found = pcall(function()
            return inventory:find(recordId)
        end)
        if okFind and found ~= nil and types.Repair.objectIsInstance(found) then
            return found
        end
    end

    local okAll, items = pcall(function()
        return inventory:getAll(types.Repair)
    end)
    if not okAll or items == nil then
        return nil
    end

    local okPairs, found = pcall(function()
        for _, item in pairs(items) do
            if item ~= nil and item.recordId == recordId and types.Repair.objectIsInstance(item) then
                return item
            end
        end
        return nil
    end)
    if okPairs then
        return found
    end

    return nil
end

local function modifyRepairToolCondition(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    local amount = tonumber(data.amount) or 0
    local recordId = data.recordId
    if player == nil or amount == 0 then
        return
    end

    local tool = data.tool
    if tool == nil or not types.Repair.objectIsInstance(tool) then
        tool = findRepairToolInInventory(player, recordId)
    end

    if tool == nil or not types.Repair.objectIsInstance(tool) then
        sendCarefulRepairsRefundResult(player, {
            success = false,
            reason = "missing_repair_tool",
            amount = amount,
            recordId = recordId,
        })
        return
    end

    local itemData = types.Item.itemData(tool)
    if itemData == nil or type(itemData.condition) ~= "number" then
        sendCarefulRepairsRefundResult(player, {
            success = false,
            reason = "missing_repair_tool_condition",
            amount = amount,
            recordId = tool.recordId or recordId,
        })
        return
    end

    local currentCondition = itemData.condition
    local newCondition = currentCondition + amount
    local maxCondition = repairToolMaxCondition(tool)
    if type(maxCondition) == "number" and newCondition > maxCondition then
        newCondition = maxCondition
    end

    local okWrite, err = pcall(function()
        itemData.condition = newCondition
    end)
    if not okWrite then
        sendCarefulRepairsRefundResult(player, {
            success = false,
            reason = "write_failed",
            error = tostring(err),
            amount = amount,
            recordId = tool.recordId or recordId,
        })
        return
    end

    sendCarefulRepairsRefundResult(player, {
        success = true,
        amount = math.max(0, newCondition - currentCondition),
        recordId = tool.recordId or recordId,
        condition = newCondition,
    })
end

local function writeToolCondition(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil then
        return
    end
    local slot = data.slot
    if slot == nil then
        slot = types.Actor.EQUIPMENT_SLOT.CarriedRight
    end

    local tool = types.Actor.getEquipment(player, slot)
    local toolType = classifySecurityTool(tool)
    if toolType == nil then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no security tool resolved) slot=%s player=%s amount=%s",
            tostring(slot),
            tostring(player),
            tostring(data.amount)
        ))
        return
    end

    local amount = tonumber(data.amount) or 0
    if amount == 0 then
        return
    end

    local itemData = types.Item.itemData(tool)
    if itemData == nil or type(itemData.condition) ~= "number" then
        print(string.format(
            "[SkillPerkSystem_BasePack][SteadyHands][debug] refund skipped (no numeric itemData.condition) slot=%s type=%s amount=%s",
            tostring(slot),
            tostring(toolType),
            tostring(amount)
        ))
        return
    end

    local currentCondition = itemData.condition
    local newCondition = currentCondition + amount

    if newCondition <= 0 then
        tool:remove()
        return
    end

    types.Item.itemData(tool).condition = newCondition
end

local function inferProbeFromItem(item)
    if item == nil then
        return nil
    end

    if types.Probe.objectIsInstance(item) then
        return true
    end

    if types.Lockpick.objectIsInstance(item) then
        return false
    end

    return nil
end

local function inferProbeFromEquipment(player)
    if player == nil or types.Actor == nil or type(types.Actor.getEquipment) ~= "function" then
        return false
    end

    local slots = types.Actor.EQUIPMENT_SLOT or {}
    local rightSlot = slots.CarriedRight
    if rightSlot ~= nil then
        local rightItem = types.Actor.getEquipment(player, rightSlot)
        local probe = inferProbeFromItem(rightItem)
        if probe ~= nil then
            return probe
        end
    end

    local leftSlot = slots.CarriedLeft
    if leftSlot ~= nil then
        local leftItem = types.Actor.getEquipment(player, leftSlot)
        local probe = inferProbeFromItem(leftItem)
        if probe ~= nil then
            return probe
        end
    end

    return false
end

local function normalizeFailureProbe(data)
    if type(data) == "table" and type(data.probe) == "boolean" then
        return data.probe
    end

    if type(data) == "table" then
        local probeFromItem = inferProbeFromItem(data.item)
        if probeFromItem ~= nil then
            return probeFromItem
        end

        return inferProbeFromEquipment(data.player)
    end

    return false
end

local function forwardSecurityToolDrain(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player or data.actor
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    local probe = normalizeFailureProbe(data)
    player:sendEvent(TUMBLER_SENSE_FAILURE_EVENT, {
        source = TUMBLER_SENSE_FAILURE_SOURCE,
        probe = probe,
    })
    player:sendEvent(STEADY_HANDS_TOOL_DRAIN_EVENT, {
        item = data.item or data.object or data.tool,
        slot = data.slot,
        slotName = data.slotName,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][SecurityToolBridge] forwarded drain source=%s mode=%s",
        TUMBLER_SENSE_FAILURE_SOURCE,
        probe and "probe" or "lockpick"
    ))
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

subsystems.security_global = {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
        [MODIFY_REPAIR_TOOL_CONDITION_EVENT] = modifyRepairToolCondition,
        [APPRENTICE_HAMMER_OVERREPAIR_REQUEST_EVENT] = applyApprenticeHammerOverrepair,
        [WEAPON_TEMPER_REQUEST_EVENT] = applyWeaponTemper,
        [ARMOR_REFIT_REQUEST_EVENT] = applyArmorRefit,
        [MASTERWORK_REQUEST_EVENT] = applyMasterwork,
        [DRAIN_LOCKPICK_EVENT] = forwardSecurityToolDrain,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/global.lua
end

-- 5. treasure/lucky/unseen hand global logic
do
-- Begin consolidated from SkillPerkSystem_BasePack/treasure_sense_runtime.lua
local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local ENABLED_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.treasure_sense.enabled"
local FORTUNES_HABIT_ENABLED_KEY = "security.fortunes_habit.enabled"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_TreasureSense_Toggle"
local FORTUNES_HABIT_TOGGLE_EVENT = "SkillPerkSystem_BasePack_FortunesHabit_Toggle"
local GOLD_RECORD_ID = "gold_001"
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local TREASURE_SENSE_PERK_ID = "security_treasure_sense"

local enabledSection = storage.globalSection(ENABLED_SECTION_ID)

-- Per-save state
local rewardedChests = {}

local function perkInterfaceSaysEnabled()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    local hasPerk = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(TREASURE_SENSE_PERK_ID)
    if not hasPerk then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(TREASURE_SENSE_PERK_ID)
    end

    return true
end

local function treasureSenseEnabled()
    if enabledSection:get(ENABLED_KEY) == true then
        return true
    end

    return perkInterfaceSaysEnabled()
end

local function fortunesHabitEnabled()
    return enabledSection:get(FORTUNES_HABIT_ENABLED_KEY) == true
end

local function stringHasChest(value)
    if type(value) ~= "string" then
        return false
    end
    return string.find(string.lower(value), "chest", 1, true) ~= nil
end

local function isChestLikeContainer(container)
    if not types.Container.objectIsInstance(container) then
        return false
    end

    local record = types.Container.record(container)
    if record ~= nil and stringHasChest(record.name) then
        return true
    end

    return stringHasChest(container.recordId)
end

local function objectKey(object)
    return tostring(object.id or object.formId or object.recordId)
end

local function resolveLuckStat(actor)
    if actor == nil then
        return nil
    end

    local okType, actorType = pcall(function()
        return actor.type
    end)
    if not okType or actorType == nil then
        return nil
    end

    local function tryLuckGetter(t)
        if t == nil then
            return nil
        end

        local okStats, stats = pcall(function()
            return t.stats
        end)
        if not okStats or stats == nil then
            return nil
        end

        local okAttrs, attrs = pcall(function()
            return stats.attributes
        end)
        if not okAttrs or attrs == nil then
            return nil
        end

        local okFn, fn = pcall(function()
            return attrs.luck
        end)
        if not okFn or type(fn) ~= "function" then
            return nil
        end

        local okStat, stat = pcall(fn, actor)
        if not okStat then
            return nil
        end

        return stat
    end

    local stat = tryLuckGetter(actorType)
    if stat ~= nil then
        return stat
    end

    local okBase, baseType = pcall(function()
        return actorType.baseType
    end)
    if okBase and baseType ~= nil then
        stat = tryLuckGetter(baseType)
        if stat ~= nil then
            return stat
        end
    end

    return nil
end

local function goldFromLuck(actor)
    local luckStat = resolveLuckStat(actor)
    local luck = 0

    local okModified, modified = pcall(function()
        return luckStat.modified
    end)

    if okModified and type(modified) == "number" then
        luck = math.max(0, math.floor(modified))
    end

    local luckDivisor = fortunesHabitEnabled() and 8 or 10
    local bonus = math.floor(luck / luckDivisor)
    local rollA = math.random(1, 20)
    local rollB = math.random(0, bonus)
    local amount = rollA + rollB
    if fortunesHabitEnabled() then
        amount = math.floor(amount * 1.10)
    end

    return math.max(1, math.floor(amount))
end

local function addGoldToContainer(container, amount)
    if amount <= 0 then
        return
    end

    local gold = world.createObject(GOLD_RECORD_ID, amount)
    gold:moveInto(types.Container.inventory(container))
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledSection:set(ENABLED_KEY, data.enable == true)
end

local function handleFortunesHabitToggle(data)
    if type(data) ~= "table" then
        return
    end

    enabledSection:set(FORTUNES_HABIT_ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor == nil or actor ~= world.players[1] then
        return
    end

    if not treasureSenseEnabled() then
        return
    end

    if not types.Container.objectIsInstance(object) then
        return
    end

    if not isChestLikeContainer(object) then
        return
    end

    local key = objectKey(object)
    if rewardedChests[key] then
        return
    end

    local goldCount = goldFromLuck(actor)
    addGoldToContainer(object, goldCount)
    rewardedChests[key] = true
end

local function onSave()
    return {
        rewardedChests = rewardedChests,
    }
end

local function onLoad(savedData)
    rewardedChests = {}

    if type(savedData) == "table" and type(savedData.rewardedChests) == "table" then
        rewardedChests = savedData.rewardedChests
    end
end

local function onNewGame()
    rewardedChests = {}
    enabledSection:set(FORTUNES_HABIT_ENABLED_KEY, false)
end

subsystems.treasure_sense = {
    engineHandlers = {
        onActivate = onActivate,
        onSave = onSave,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        [FORTUNES_HABIT_TOGGLE_EVENT] = handleFortunesHabitToggle,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/treasure_sense_runtime.lua
end

do
-- Begin consolidated from SkillPerkSystem_BasePack/lucky_find_runtime.lua
local storage = require("openmw.storage")
local types = require("openmw.types")
local world = require("openmw.world")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local FORTUNES_HABIT_ENABLED_KEY = "security.fortunes_habit.enabled"
local COIN_RECORD_ID_KEY = "security.lucky_find.coin_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"
local FORTUNES_HABIT_TOGGLE_EVENT = "SkillPerkSystem_BasePack_FortunesHabit_Toggle"
local GOLD_TEMPLATE_RECORD_ID = "gold_001"
local CONFIGURED_LUCKY_COIN_RECORD_ID = "sps_lucky_coin"
local BASE_FIND_CHANCE = 0.015
local FORTUNES_HABIT_FIND_CHANCE = 0.025

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)

local checkedContainers = {}
local luckyCoinRecordReady = false
local activeLuckyCoinRecordId = nil

local function luckyFindEnabled()
    return effectsSection:get(ENABLED_KEY) == true
end

local function fortunesHabitEnabled()
    return effectsSection:get(FORTUNES_HABIT_ENABLED_KEY) == true
end

local function findChance()
    if fortunesHabitEnabled() then
        return FORTUNES_HABIT_FIND_CHANCE
    end
    return BASE_FIND_CHANCE
end

local function objectKey(object)
    local explicitId = object.id or object.formId
    if explicitId ~= nil then
        return "id:" .. tostring(explicitId)
    end

    local recordId = tostring(object.recordId or "<unknown>")
    local cellPart = "cell:<unknown>"
    local okCell, cell = pcall(function()
        return object.cell
    end)
    if okCell and cell ~= nil then
        local name = cell.name or cell.id
        if type(name) == "string" and name ~= "" then
            cellPart = "cell:" .. name
        end
    end

    local posPart = "pos:<unknown>"
    local okPos, pos = pcall(function()
        return object.position
    end)
    if okPos and pos ~= nil and type(pos.x) == "number" and type(pos.y) == "number" and type(pos.z) == "number" then
        posPart = string.format("pos:%.3f,%.3f,%.3f", pos.x, pos.y, pos.z)
    end

    return table.concat({
        "record:" .. recordId,
        cellPart,
        posPart,
    }, "|")
end

local function ensureLuckyCoinRecord()
    if luckyCoinRecordReady then
        return true
    end

    if types.Miscellaneous == nil then
        return false
    end

    local okRecords, records = pcall(function()
        return types.Miscellaneous.records
    end)
    if not okRecords or records == nil then
        return false
    end

    if type(activeLuckyCoinRecordId) == "string" and activeLuckyCoinRecordId ~= "" and records[activeLuckyCoinRecordId] ~= nil then
        luckyCoinRecordReady = true
        return true
    end

    local configuredRecord = records[CONFIGURED_LUCKY_COIN_RECORD_ID]
    if configuredRecord ~= nil then
        activeLuckyCoinRecordId = CONFIGURED_LUCKY_COIN_RECORD_ID
        effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
        luckyCoinRecordReady = true
        return true
    end

    local savedRecordId = effectsSection:get(COIN_RECORD_ID_KEY)
    if type(savedRecordId) == "string" and savedRecordId ~= "" and records[savedRecordId] ~= nil then
        activeLuckyCoinRecordId = savedRecordId
        luckyCoinRecordReady = true
        return true
    end

    if type(types.Miscellaneous.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        return false
    end

    local template = records[GOLD_TEMPLATE_RECORD_ID]
    if template == nil then
        return false
    end

    local okDraft, recordDraft = pcall(types.Miscellaneous.createRecordDraft, {
        template = template,
        name = "Lucky Coin",
        weight = 0.01,
    })
    if not okDraft or recordDraft == nil then
        return false
    end

    local okCreate, createdRecord = pcall(world.createRecord, recordDraft)
    local createdId = nil
    if type(createdRecord) == "string" then
        createdId = createdRecord
    elseif createdRecord ~= nil then
        local okId, idValue = pcall(function()
            return createdRecord.id
        end)
        if okId and type(idValue) == "string" and idValue ~= "" then
            createdId = idValue
        end
    end

    if not okCreate or type(createdId) ~= "string" or createdId == "" then
        return false
    end

    activeLuckyCoinRecordId = createdId
    effectsSection:set(COIN_RECORD_ID_KEY, activeLuckyCoinRecordId)
    luckyCoinRecordReady = true
    return true
end

local function addLuckyCoinsToContainer(container, amount)
    if amount <= 0 then
        return false
    end

    local recordId = activeLuckyCoinRecordId
    if type(recordId) ~= "string" or recordId == "" then
        return false
    end

    local ok, coin = pcall(world.createObject, recordId, amount)
    if not ok or coin == nil then
        return false
    end

    coin:moveInto(types.Container.inventory(container))
    return true
end

local function handleToggle(data)
    if type(data) ~= "table" then
        return
    end

    effectsSection:set(ENABLED_KEY, data.enable == true)
end

local function onActivate(object, actor)
    if actor == nil or actor ~= world.players[1] then
        return
    end

    if not luckyFindEnabled() then
        return
    end

    if not types.Container.objectIsInstance(object) then
        return
    end

    local key = objectKey(object)
    if checkedContainers[key] then
        return
    end

    local foundCoin = math.random() <= findChance()
    if foundCoin and not ensureLuckyCoinRecord() then
        return
    end

    checkedContainers[key] = true

    if foundCoin then
        addLuckyCoinsToContainer(object, 1)
    end
end

local function onSave()
    return {
        checkedContainers = checkedContainers,
    }
end

local function onLoad(savedData)
    checkedContainers = {}
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    effectsSection:set(ENABLED_KEY, false)
    effectsSection:set(FORTUNES_HABIT_ENABLED_KEY, false)

    if type(savedData) == "table" and type(savedData.checkedContainers) == "table" then
        checkedContainers = savedData.checkedContainers
    end
end

local function onNewGame()
    checkedContainers = {}
    luckyCoinRecordReady = false
    activeLuckyCoinRecordId = nil
    effectsSection:set(ENABLED_KEY, false)
    effectsSection:set(FORTUNES_HABIT_ENABLED_KEY, false)
    effectsSection:set(COIN_RECORD_ID_KEY, nil)
end

local function handleFortunesHabitToggle(data)
    if type(data) ~= "table" then
        return
    end

    effectsSection:set(FORTUNES_HABIT_ENABLED_KEY, data.enable == true)
end

subsystems.lucky_find = {
    engineHandlers = {
        onActivate = onActivate,
        onSave = onSave,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
        [FORTUNES_HABIT_TOGGLE_EVENT] = handleFortunesHabitToggle,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/lucky_find_runtime.lua
end

do
-- Begin consolidated from SkillPerkSystem_BasePack/unseen_hand_global_runtime.lua
local world = require("openmw.world")

local PLAYER_TOGGLE_EVENT = "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle"

local function forwardToPlayer(data)
    local player = world.players[1]
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    player:sendEvent(PLAYER_TOGGLE_EVENT, data)
end

subsystems.unseen_hand = {
    eventHandlers = {
        [PLAYER_TOGGLE_EVENT] = function(data)
            if type(data) ~= "table" then
                return
            end

            forwardToPlayer({
                enable = data.enable == true,
            })
        end,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/unseen_hand_global_runtime.lua
end

-- 5a. short blade global state handling
do
local world = require("openmw.world")

local shortBladeState = {
    playerId = nil,
    vitalStrikeEnabled = false,
    flashCutEnabled = false,
    closeMeasureEnabled = false,
}
local SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT = "SkillPerkSystem_CloseMeasureTriggered"

local function shortBladeTargetStateActive()
    return (shortBladeState.vitalStrikeEnabled == true or shortBladeState.flashCutEnabled == true or shortBladeState.closeMeasureEnabled == true) and type(shortBladeState.playerId) == "string" and shortBladeState.playerId ~= ""
end

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_ShortBladeRefresh", shortBladeState)
    end
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("shortblade", shortBladeTargetStateActive())
end

local function onShortBladeState(data)
    if type(data) ~= "table" then
        return
    end

    shortBladeState = {
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        vitalStrikeEnabled = data.vitalStrikeEnabled == true,
        flashCutEnabled = data.flashCutEnabled == true,
        closeMeasureEnabled = data.closeMeasureEnabled == true,
    }
    refreshWatchers()
end

local function forwardCloseMeasureTrigger(data)
    if type(data) ~= "table" or type(data.playerId) ~= "string" or data.playerId ~= shortBladeState.playerId then
        return
    end
    if not shortBladeState.closeMeasureEnabled then
        return
    end

    local player = world.players[1]
    if player == nil or type(player.sendEvent) ~= "function" or player.id ~= data.playerId then
        return
    end

    player:sendEvent(SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT, data)
end

registerTargetWatcherProvider("shortblade", {
    isActive = shortBladeTargetStateActive,
    sendState = sendState,
})

subsystems.shortblade = {
    eventHandlers = {
        SkillPerkSystem_ShortBladeState = onShortBladeState,
        [SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT] = forwardCloseMeasureTrigger,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

end

-- 6. axe global state handling
do
-- Begin consolidated from SkillPerkSystem_BasePack/axe_global.lua
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local AXE_TARGET_SCRIPT = BASEPACK_ACTOR_TARGET_SCRIPT
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local kindlingGripState = {
    enabled = false,
    damageBonusCount = 0,
    bloodletterEnabled = false,
    draggingWoundEnabled = false,
    hewerHeartEnabled = false,
    crimsonCleaveEnabled = false,
    ironCanopyEnabled = false,
    thrownFundamentalsEnabled = false,
    trickThrowEnabled = false,
    pinningShotEnabled = false,
    deadeyeMasteryEnabled = false,
    playerId = nil,
    steadyDrawPlayerId = nil,
    steadyDrawMultiplier = 1,
    steadyDrawExpiresAt = 0,
    steadyDrawSequence = 0,
}

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(AXE_TARGET_SCRIPT)
end

local function sendState(actor)
    if actor == nil or type(actor.sendEvent) ~= "function" then
        return
    end

    actor:sendEvent("SkillPerkSystem_AxeKindlingGripRefresh", kindlingGripState)
end

local function axeTargetStateActive()
    return kindlingGripState.enabled
        or kindlingGripState.damageBonusCount > 0
        or kindlingGripState.bloodletterEnabled
        or kindlingGripState.draggingWoundEnabled
        or kindlingGripState.hewerHeartEnabled
        or kindlingGripState.crimsonCleaveEnabled
        or kindlingGripState.ironCanopyEnabled
        or kindlingGripState.thrownFundamentalsEnabled
        or kindlingGripState.trickThrowEnabled
        or kindlingGripState.pinningShotEnabled
        or kindlingGripState.deadeyeMasteryEnabled
        or kindlingGripState.steadyDrawMultiplier > 1
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("axe", axeTargetStateActive())
end

local function onKindlingGripState(data)
    if type(data) ~= "table" then
        return
    end

    kindlingGripState = {
        enabled = data.enabled == true,
        damageBonusCount = math.max(0, math.floor(tonumber(data.damageBonusCount) or 0)),
        bloodletterEnabled = data.bloodletterEnabled == true,
        draggingWoundEnabled = data.draggingWoundEnabled == true,
        hewerHeartEnabled = data.hewerHeartEnabled == true,
        crimsonCleaveEnabled = data.crimsonCleaveEnabled == true,
        ironCanopyEnabled = data.ironCanopyEnabled == true,
        thrownFundamentalsEnabled = data.thrownFundamentalsEnabled == true,
        trickThrowEnabled = data.trickThrowEnabled == true,
        pinningShotEnabled = data.pinningShotEnabled == true,
        deadeyeMasteryEnabled = data.deadeyeMasteryEnabled == true,
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        steadyDrawPlayerId = kindlingGripState.steadyDrawPlayerId,
        steadyDrawMultiplier = kindlingGripState.steadyDrawMultiplier,
        steadyDrawExpiresAt = kindlingGripState.steadyDrawExpiresAt,
        steadyDrawSequence = kindlingGripState.steadyDrawSequence,
    }
    refreshWatchers()
end

local function onSteadyDrawState(data)
    if type(data) ~= "table" then
        return
    end

    kindlingGripState.steadyDrawPlayerId = type(data.playerId) == "string" and data.playerId or nil
    kindlingGripState.steadyDrawMultiplier = math.max(1, tonumber(data.multiplier) or 1)
    kindlingGripState.steadyDrawExpiresAt = math.max(0, tonumber(data.expiresAt) or 0)
    kindlingGripState.steadyDrawSequence = math.max(0, math.floor(tonumber(data.sequence) or 0))
    refreshWatchers()
end

registerTargetWatcherProvider("axe", {
    isActive = axeTargetStateActive,
    sendState = sendState,
})

subsystems.axe = {
    eventHandlers = {
        SkillPerkSystem_AxeKindlingGripState = onKindlingGripState,
        SkillPerkSystem_MarksmanSteadyDrawState = onSteadyDrawState,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/axe_global.lua
end

-- 6a. spear global state handling
do
local spearPointControlState = {
    playerId = nil,
    pointControlEnabled = false,
    drivingStepEnabled = false,
    hookAndTurnEnabled = false,
    lineBreakerEnabled = false,
    masterVanguardEnabled = false,
}

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_SpearPointControlRefresh", spearPointControlState)
    end
end

local function spearTargetStateActive()
    return spearPointControlState.pointControlEnabled or spearPointControlState.drivingStepEnabled or spearPointControlState.hookAndTurnEnabled or spearPointControlState.lineBreakerEnabled or spearPointControlState.masterVanguardEnabled
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("spear", spearTargetStateActive())
end

local function onSpearPointControlState(data)
    if type(data) ~= "table" then
        return
    end

    spearPointControlState = {
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        pointControlEnabled = data.pointControlEnabled == true,
        drivingStepEnabled = data.drivingStepEnabled == true,
        hookAndTurnEnabled = data.hookAndTurnEnabled == true,
        lineBreakerEnabled = data.lineBreakerEnabled == true,
        masterVanguardEnabled = data.masterVanguardEnabled == true,
    }
    refreshWatchers()
end

registerTargetWatcherProvider("spear", {
    isActive = spearTargetStateActive,
    sendState = sendState,
})

subsystems.spear = {
    eventHandlers = {
        SkillPerkSystem_SpearPointControlState = onSpearPointControlState,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

end

-- 6b. hand-to-hand global state handling
do
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local HAND_TO_HAND_TARGET_SCRIPT = BASEPACK_ACTOR_TARGET_SCRIPT
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local handToHandState = {
    playerId = nil,
    ironKnucklesEnabled = false,
    breakingFistEnabled = false,
    flowingCounterMode = "none",
    emptyBodyMasteryEnabled = false,
}

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(HAND_TO_HAND_TARGET_SCRIPT)
end

local function sendState(actor)
    if actor == nil or type(actor.sendEvent) ~= "function" then
        return
    end

    actor:sendEvent("SkillPerkSystem_HandToHandRefresh", handToHandState)
end

local function handToHandTargetStateActive()
    return handToHandState.ironKnucklesEnabled
        or handToHandState.breakingFistEnabled
        or handToHandState.flowingCounterMode ~= "none"
        or handToHandState.emptyBodyMasteryEnabled
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("handtohand", handToHandTargetStateActive())
end

local function onHandToHandState(data)
    if type(data) ~= "table" then
        return
    end

    handToHandState = {
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        ironKnucklesEnabled = data.ironKnucklesEnabled == true,
        breakingFistEnabled = data.breakingFistEnabled == true,
        flowingCounterMode = type(data.flowingCounterMode) == "string" and data.flowingCounterMode or "none",
        emptyBodyMasteryEnabled = data.emptyBodyMasteryEnabled == true,
    }
    refreshWatchers()
end

registerTargetWatcherProvider("handtohand", {
    isActive = handToHandTargetStateActive,
    sendState = sendState,
})

subsystems.handtohand = {
    eventHandlers = {
        SkillPerkSystem_HandToHandState = onHandToHandState,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

end

-- 7. blunt weapon global state handling
do
-- Begin consolidated from SkillPerkSystem_BasePack/bluntweapon_global.lua
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Item = types.Item
local TARGET_SCRIPT = BASEPACK_ACTOR_TARGET_SCRIPT
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local strengthInArmsState = {
    strengthInArmsEnabled = false,
    enabled = false,
    damageBonus = 0,
    platebreakerEnabled = false,
    breathstealerEnabled = false,
    heavyHitterEnabled = false,
    staggeringBlowEnabled = false,
    ironBellEnabled = false,
    playerId = nil,
}


local ARMOR_EQUIPMENT_SLOTS = {
    "Cuirass",
    "Greaves",
    "Helmet",
    "LeftGauntlet",
    "RightGauntlet",
    "LeftPauldron",
    "RightPauldron",
    "Boots",
    "CarriedLeft",
}

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getEquippedArmorItems(actor)
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" then
        return {}
    end

    local armorItems = {}
    for _, slotName in ipairs(ARMOR_EQUIPMENT_SLOTS) do
        local item = getEquippedItem(actor, slots[slotName])
        if item ~= nil and Armor.objectIsInstance(item) then
            local itemData = Item ~= nil and type(Item.itemData) == "function" and Item.itemData(item) or nil
            local condition = itemData ~= nil and tonumber(itemData.condition) or nil
            if condition ~= nil and condition > 0 then
                table.insert(armorItems, { itemData = itemData, condition = condition })
            end
        end
    end

    return armorItems
end

local function getEquippedShieldItem(actor)
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil or Armor == nil or Armor.TYPE == nil or type(Armor.objectIsInstance) ~= "function" then
        return nil
    end

    local item = getEquippedItem(actor, slots.CarriedLeft)
    if item == nil or not Armor.objectIsInstance(item) then
        return nil
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, item)
        if okRecord then
            record = value
        end
    end
    if record == nil and type(item.recordId) == "string" and type(Armor.records) == "table" then
        record = Armor.records[item.recordId]
    end
    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil
    end

    local itemData = Item ~= nil and type(Item.itemData) == "function" and Item.itemData(item) or nil
    local condition = itemData ~= nil and tonumber(itemData.condition) or nil
    if condition == nil or condition <= 0 then
        return nil
    end

    return { itemData = itemData, condition = condition }
end

local function applyHeavyHitterShieldDamage(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target == nil or (type(target.isValid) == "function" and not target:isValid()) then
        return
    end

    local conditionDamage = tonumber(data.conditionDamage)
    if conditionDamage == nil or conditionDamage <= 0 then
        return
    end
    conditionDamage = math.floor(conditionDamage)

    local shield = getEquippedShieldItem(target)
    if shield == nil then
        return
    end

    shield.itemData.condition = math.max(0, shield.condition - conditionDamage)
end

local function applyPlatebreakerArmorDamage(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target == nil or (type(target.isValid) == "function" and not target:isValid()) then
        return
    end

    local conditionDamage = tonumber(data.conditionDamage)
    if conditionDamage == nil or conditionDamage <= 0 then
        return
    end
    conditionDamage = math.floor(conditionDamage)

    local armorItems = getEquippedArmorItems(target)
    if #armorItems == 0 then
        return
    end

    local armor = armorItems[math.random(1, #armorItems)]
    armor.itemData.condition = math.max(0, armor.condition - conditionDamage)
end

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(TARGET_SCRIPT)
end

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_BluntWeaponStrengthInArmsRefresh", strengthInArmsState)
    end
end

local function bluntTargetStateActive()
    return strengthInArmsState.strengthInArmsEnabled
        or strengthInArmsState.enabled
        or strengthInArmsState.damageBonus > 0
        or strengthInArmsState.platebreakerEnabled
        or strengthInArmsState.breathstealerEnabled
        or strengthInArmsState.heavyHitterEnabled
        or strengthInArmsState.staggeringBlowEnabled
        or strengthInArmsState.ironBellEnabled
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("bluntweapon", bluntTargetStateActive())
end

local function onStrengthInArmsState(data)
    if type(data) ~= "table" then
        return
    end

    strengthInArmsState = {
        strengthInArmsEnabled = data.strengthInArmsEnabled == true or data.enabled == true,
        enabled = data.strengthInArmsEnabled == true or data.enabled == true,
        damageBonus = math.max(0, math.floor(tonumber(data.damageBonus) or 0)),
        platebreakerEnabled = data.platebreakerEnabled == true,
        breathstealerEnabled = data.breathstealerEnabled == true,
        heavyHitterEnabled = data.heavyHitterEnabled == true,
        staggeringBlowEnabled = data.staggeringBlowEnabled == true,
        ironBellEnabled = data.ironBellEnabled == true,
        playerId = type(data.playerId) == "string" and data.playerId or nil,
    }
    refreshWatchers()
end

registerTargetWatcherProvider("bluntweapon", {
    isActive = bluntTargetStateActive,
    sendState = sendState,
})

subsystems.bluntweapon = {
    eventHandlers = {
        SkillPerkSystem_BluntWeaponStrengthInArmsState = onStrengthInArmsState,
        SkillPerkSystem_ApplyPlatebreakerArmorDamage = applyPlatebreakerArmorDamage,
        SkillPerkSystem_ApplyHeavyHitterShieldDamage = applyHeavyHitterShieldDamage,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/bluntweapon_global.lua
end

-- 8. duelist tempo global state handling
do
-- Begin consolidated from SkillPerkSystem_BasePack/duelists_tempo_global.lua
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local DUELISTS_TEMPO_TARGET_SCRIPT = BASEPACK_ACTOR_TARGET_SCRIPT
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(DUELISTS_TEMPO_TARGET_SCRIPT)
end

subsystems.duelists_tempo = {
    engineHandlers = {},
}

-- End consolidated from SkillPerkSystem_BasePack/duelists_tempo_global.lua
end

-- 9. block reactive global logic
do
-- Begin consolidated from SkillPerkSystem_BasePack/block_reactive_global.lua
local core = require("openmw.core")
local types = require("openmw.types")

local Item = types.Item
local Actor = types.Actor

local REACTIVE_DEFAULT_VFX_MODEL = "meshes\\e\\magic_hit_myst.nif"
local REACTIVE_DEFAULT_SOUND_FILE = "Sound\\Fx\\magic\\mystH.wav"
local EMPTY_BODY_DEBUG = true

local function logEmptyBodyDebug(message)
    if EMPTY_BODY_DEBUG then
        print("[SkillPerkSystem_BasePack][EmptyBody][Global][debug] " .. tostring(message))
    end
end

local PRESENTATION_BY_EFFECT_ID = {
    -- Destruction / elemental damage
    firedamage = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    frostdamage = {
        vfx = "meshes\\e\\magic_hit_frost.nif",
        sound = "Sound\\Fx\\magic\\frstH.wav",
    },
    shockdamage = {
        vfx = "meshes\\e\\magic_hit_s.nif",
        sound = "Sound\\Fx\\magic\\shokH.wav",
    },

    -- Destruction / generic hostile damage-drain effects
    damagehealth = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damagefatigue = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damagemagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damageattribute = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damageskill = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainhealth = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainfatigue = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainmagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainattribute = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainskill = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessfire = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessfrost = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessshock = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessmagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesscommondisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessblightdisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesscorprusdisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesspoison = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    poison = {
        vfx = "meshes\\e\\magic_hit_poison.nif",
        sound = "Sound\\Fx\\magic\\poisH.wav",
    },

    -- Mysticism
    absorbhealth = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbfatigue = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbmagicka = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbattribute = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbskill = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    telekinesis = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectkey = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectanimal = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectenchantment = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    mark = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    recall = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    dispel = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    soultrap = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },

    -- Restoration / beneficial effects
    restorehealth = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    restorefatigue = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    restoremagicka = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyhealth = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyfatigue = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifymagicka = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyattribute = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyskill = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },

    -- Illusion
    sanctuary = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    chameleon = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    invisibility = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    blind = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    light = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    nighteye = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmcreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmanimal = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    frenzycreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    frenzyhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    demoralizecreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    demoralizehumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    rallycreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    rallyhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },

    -- Alteration-ish fallback
    shield = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fireresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    frostresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    shockresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    resistmagicka = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    waterbreathing = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    waterwalking = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    levitate = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    slowfall = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    jump = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    open = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    lock = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
}

local function normalizeEffectId(effectId)
    if type(effectId) ~= "string" then
        return nil
    end
    return string.lower(effectId)
end

local function getEffectId(effect)
    if effect == nil then
        return nil
    end

    local ok, value = pcall(function()
        return effect.id or (effect.effect and effect.effect.id) or effect.effect
    end)
    if ok then
        return normalizeEffectId(value)
    end
    return nil
end

local function resolveRange(effect)
    if effect == nil then
        return nil
    end

    local okRaw, rawRange = pcall(function()
        return effect.range or effect.castType
    end)
    if not okRaw then
        return nil
    end

    if type(rawRange) == "string" then
        local normalized = string.lower(rawRange)
        if normalized == "self" or normalized == "touch" or normalized == "target" then
            return normalized
        end
    end

    local rangeType = core.magic and (core.magic.RANGE or core.magic.RANGE_TYPE) or nil
    if rangeType ~= nil then
        if rawRange == rangeType.Self then return "self" end
        if rawRange == rangeType.Touch then return "touch" end
        if rawRange == rangeType.Target then return "target" end
    end

    return nil
end

local function getEnchantmentRecord(enchantmentId)
    local records = core.magic and core.magic.enchantments and core.magic.enchantments.records or nil
    if records == nil then
        return nil
    end

    local direct = records[enchantmentId]
    if direct ~= nil then
        return direct
    end

    local lowerId = type(enchantmentId) == "string" and string.lower(enchantmentId) or enchantmentId
    local lowered = records[lowerId]
    if lowered ~= nil then
        return lowered
    end

    for _, rec in pairs(records) do
        if rec ~= nil then
            local recId = rec.id
            if recId == enchantmentId then
                return rec
            end
            if type(recId) == "string" and type(enchantmentId) == "string" and string.lower(recId) == string.lower(enchantmentId) then
                return rec
            end
        end
    end

    return nil
end

local function splitEffectIndexes(enchantment)
    local selfIndexes = {}
    local attackerIndexes = {}
    local effects = enchantment and enchantment.effects or nil

    if effects == nil then
        return selfIndexes, attackerIndexes
    end

    for index, effect in ipairs(effects) do
        local range = resolveRange(effect)
        local zeroIndex = index - 1

        if range == "self" then
            table.insert(selfIndexes, zeroIndex)
        elseif range == "touch" or range == "target" then
            table.insert(attackerIndexes, zeroIndex)
        end
    end

    return selfIndexes, attackerIndexes
end

local function getPresentationForEnchantment(enchantment)
    local effects = enchantment and enchantment.effects or nil
    if effects ~= nil then
        for _, effect in ipairs(effects) do
            local effectId = getEffectId(effect)
            if effectId ~= nil then
                local mapped = PRESENTATION_BY_EFFECT_ID[effectId]
                if mapped ~= nil then
                    return mapped
                end
            end
        end
    end

    return {
        vfx = REACTIVE_DEFAULT_VFX_MODEL,
        sound = REACTIVE_DEFAULT_SOUND_FILE,
    }
end

local function addVfx(target, model, vfxId)
    if target == nil or type(model) ~= "string" or model == "" then
        return
    end

    target:sendEvent("AddVfx", {
        model = model,
        options = {
            vfxId = vfxId,
            loop = false,
        }
    })
end

local function playSound(target, soundFile)
    if target == nil or type(soundFile) ~= "string" or soundFile == "" then
        return
    end

    core.sound.playSoundFile3d(soundFile, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
end

local function addEffectsToTarget(target, sourceItemId, effectIndexes, caster, item)
    if target == nil then
        return false
    end
    if type(sourceItemId) ~= "string" or sourceItemId == "" then
        return false
    end
    if type(effectIndexes) ~= "table" or #effectIndexes == 0 then
        return true
    end

    local ok, result = pcall(function()
        Actor.activeSpells(target):add({
            id = sourceItemId,
            effects = effectIndexes,
            caster = caster,
            item = item,
            stackable = true,
        })
        return true
    end)

    if not ok then
        return false
    end

    return result == true
end

local function applyPresentation(target, presentation, label)
    if target == nil or presentation == nil then
        return
    end

    addVfx(target, presentation.vfx, "sps_reactive_" .. tostring(label))
    playSound(target, presentation.sound)
end

local function onApplyReactiveShieldEnchant(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    local attacker = e.attacker
    local shield = e.shield
    local enchantmentId = e.enchantmentId

    if blocker == nil or shield == nil or type(enchantmentId) ~= "string" or enchantmentId == "" then
        return
    end

    local sourceItemId = shield.recordId
    if type(sourceItemId) ~= "string" or sourceItemId == "" then
        return
    end

    local enchantment = getEnchantmentRecord(enchantmentId)
    if enchantment == nil then
        return
    end

    local constantEffectType = core.magic and core.magic.ENCHANTMENT_TYPE and core.magic.ENCHANTMENT_TYPE.ConstantEffect or nil
    if constantEffectType ~= nil and enchantment.type == constantEffectType then
        return
    end

    local itemData = Item and type(Item.itemData) == "function" and Item.itemData(shield) or nil
    if itemData == nil then
        return
    end

    local enchantCost = tonumber(enchantment.cost or enchantment.enchantmentCost or enchantment.castCost) or 0
    local maxCharge = tonumber(enchantment.charge or enchantment.maxCharge or enchantment.enchantmentCharge)
    local currentCharge = tonumber(itemData.enchantmentCharge)
    if currentCharge == nil and type(maxCharge) == "number" then
        currentCharge = maxCharge
    end

    if currentCharge == nil then
        return
    end
    if enchantCost > 0 and currentCharge < enchantCost then
        return
    end

    local selfIndexes, attackerIndexes = splitEffectIndexes(enchantment)
    if #selfIndexes == 0 and #attackerIndexes == 0 then
        return
    end

    local presentation = getPresentationForEnchantment(enchantment)
    local appliedAny = false

    if #selfIndexes > 0 then
        local appliedSelf = addEffectsToTarget(blocker, sourceItemId, selfIndexes, blocker, shield)
        appliedAny = appliedSelf or appliedAny
        if appliedSelf then
            applyPresentation(blocker, presentation, "self")
        end
    end

    if attacker ~= nil and #attackerIndexes > 0 then
        local appliedAttacker = addEffectsToTarget(attacker, sourceItemId, attackerIndexes, blocker, shield)
        appliedAny = appliedAttacker or appliedAny
        if appliedAttacker then
            applyPresentation(attacker, presentation, "target")
        end
    end

    if not appliedAny then
        return
    end

    if enchantCost > 0 then
        local nextCharge = math.max(0, currentCharge - enchantCost)
        itemData.enchantmentCharge = nextCharge
    end
end

local function onApplyEmptyBodyGloveEnchant(e)
    if type(e) ~= "table" then
        return
    end

    local attacker = e.attacker
    local target = e.target
    local glove = e.glove
    local enchantmentId = e.enchantmentId

    if attacker == nil or target == nil or glove == nil or type(enchantmentId) ~= "string" or enchantmentId == "" then
        logEmptyBodyDebug("skipped invalid payload")
        return
    end

    local sourceItemId = glove.recordId
    if type(sourceItemId) ~= "string" or sourceItemId == "" then
        logEmptyBodyDebug("skipped glove without source item id")
        return
    end

    local enchantment = getEnchantmentRecord(enchantmentId)
    if enchantment == nil then
        logEmptyBodyDebug("skipped missing enchantment record id=" .. tostring(enchantmentId))
        return
    end

    local constantEffectType = core.magic and core.magic.ENCHANTMENT_TYPE and core.magic.ENCHANTMENT_TYPE.ConstantEffect or nil
    if constantEffectType ~= nil and enchantment.type == constantEffectType then
        logEmptyBodyDebug("rejected constant effect enchantment id=" .. tostring(enchantmentId))
        return
    end

    local itemData = Item and type(Item.itemData) == "function" and Item.itemData(glove) or nil
    if itemData == nil then
        logEmptyBodyDebug("skipped missing itemData")
        return
    end

    local enchantCost = tonumber(enchantment.cost or enchantment.enchantmentCost or enchantment.castCost) or 0
    local maxCharge = tonumber(enchantment.charge or enchantment.maxCharge or enchantment.enchantmentCharge)
    local currentCharge = tonumber(itemData.enchantmentCharge)
    if currentCharge == nil and type(maxCharge) == "number" then
        currentCharge = maxCharge
    end

    if currentCharge == nil then
        logEmptyBodyDebug("skipped missing enchantment charge")
        return
    end
    if enchantCost > 0 and currentCharge < enchantCost then
        logEmptyBodyDebug("skipped insufficient charge current=" .. tostring(currentCharge) .. " cost=" .. tostring(enchantCost))
        return
    end

    local _, targetIndexes = splitEffectIndexes(enchantment)
    if #targetIndexes == 0 then
        logEmptyBodyDebug("rejected no touch/target effects id=" .. tostring(enchantmentId))
        return
    end

    local applied = addEffectsToTarget(target, sourceItemId, targetIndexes, attacker, glove)
    if not applied then
        logEmptyBodyDebug("target effect application failed id=" .. tostring(enchantmentId))
        return
    end

    applyPresentation(target, getPresentationForEnchantment(enchantment), "empty_body_" .. tostring(e.hand or "glove"))

    if enchantCost > 0 then
        itemData.enchantmentCharge = math.max(0, currentCharge - enchantCost)
    end
    logEmptyBodyDebug("applied target indexes=" .. tostring(#targetIndexes) .. " cost=" .. tostring(enchantCost))
end

subsystems.block_reactive = {
    eventHandlers = {
        SkillPerkSystem_ApplyReactiveShieldEnchant = onApplyReactiveShieldEnchant,
        SkillPerkSystem_ApplyEmptyBodyGloveEnchant = onApplyEmptyBodyGloveEnchant,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/block_reactive_global.lua
end

-- 10. block bulwark global logic
do
-- Begin consolidated from SkillPerkSystem_BasePack/block_bulwark_global.lua
local core = require("openmw.core")
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local Creature = types.Creature

local BULWARK_DAMAGE_SPELL_ID = "sps_Bullareadmg"
local BULWARK_RADIUS = 384

-- If these do not resolve in your setup, try the full asset paths instead:
-- "meshes\\magic_hit_dst.nif" and "Sound\\Fx\\destH.wav"
local BULWARK_HIT_VFX_MODEL = "meshes\\e\\magic_hit_dst.nif"
local BULWARK_HIT_SOUND_FILE = "Sound\\Fx\\magic\\destH.wav"

local function isUndeadOrDaedra(actor)
    if actor == nil then
        return false
    end
    if not Creature.objectIsInstance(actor) then
        return false
    end

    local record = Creature.record(actor)
    if record == nil then
        return false
    end

    return record.type == Creature.TYPE.Undead or record.type == Creature.TYPE.Daedra
end

local function isWithinRadius(source, target, radius)
    if source == nil or target == nil then
        return false
    end

    local sourcePos = source.position
    local targetPos = target.position
    if sourcePos == nil or targetPos == nil then
        return false
    end

    local dx = targetPos.x - sourcePos.x
    local dy = targetPos.y - sourcePos.y
    local dz = targetPos.z - sourcePos.z
    local distanceSquared = dx * dx + dy * dy + dz * dz
    return distanceSquared <= (radius * radius)
end

local function addHitVfx(target)
    if target == nil then
        return
    end

    target:sendEvent("AddVfx", {
        model = BULWARK_HIT_VFX_MODEL,
        options = {
            vfxId = "sps_bulwark_hit_vfx",
            loop = false,
        }
    })
end

local function playHitSound(target)
    if target == nil then
        return
    end

    core.sound.playSoundFile3d(BULWARK_HIT_SOUND_FILE, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
end

local function applyBulwarkSmite(blocker, target)
    Actor.activeSpells(target):add({
        id = BULWARK_DAMAGE_SPELL_ID,
        effects = { 0 },
        caster = blocker,
        stackable = true,
    })

    addHitVfx(target)
    playHitSound(target)
end

local function onApplyBulwarkOfLight(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    if blocker == nil then
        return
    end

    for _, actor in ipairs(world.activeActors) do
        if actor ~= nil
            and actor ~= blocker
            and not Actor.isDead(actor)
            and isUndeadOrDaedra(actor)
            and isWithinRadius(blocker, actor, BULWARK_RADIUS)
        then
            applyBulwarkSmite(blocker, actor)
        end
    end
end

subsystems.block_bulwark = {
    eventHandlers = {
        SkillPerkSystem_ApplyBulwarkOfLight = onApplyBulwarkOfLight,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/block_bulwark_global.lua
end

-- 11. block aegis rite global logic
do
-- Begin consolidated from SkillPerkSystem_BasePack/block_aegis_rite_global.lua
local core = require("openmw.core")

local AEGIS_RITE_TARGET_SCRIPT = BASEPACK_ACTOR_TARGET_SCRIPT
local AEGIS_RITE_SMITE_SPELL_ID = "sps_MeleeSmite"
local AEGIS_RITE_HIT_VFX_MODEL = "meshes\\e\\magic_hit_dst.nif"
local AEGIS_RITE_HIT_SOUND_FILE = "Sound\\Fx\\magic\\destH.wav"

local function addHitVfx(target)
    if target == nil then
        return
    end

    target:sendEvent("AddVfx", {
        model = AEGIS_RITE_HIT_VFX_MODEL,
        options = {
            vfxId = "sps_aegis_rite_hit_vfx",
            loop = false,
        }
    })
end

local function playHitSound(target)
    if target == nil then
        return
    end

    core.sound.playSoundFile3d(AEGIS_RITE_HIT_SOUND_FILE, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
end

local function onPrimeAegisRite(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    local attacker = e.attacker
    local duration = tonumber(e.duration) or 3.0

    if blocker == nil or attacker == nil then
        return
    end
    if not attacker:isValid() then
        return
    end

    local initData = {
        playerId = blocker.id,
        duration = duration,
    }

    if attacker:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        attacker:sendEvent("SkillPerkSystem_AegisRiteRefresh", initData)
    else
        attacker:addScript(AEGIS_RITE_TARGET_SCRIPT, initData)
    end
end

local function onApplyAegisRiteEffect(e)
    if type(e) ~= "table" then
        return
    end

    local attacker = e.attacker
    local target = e.target
    if attacker == nil or target == nil then
        return
    end
    if not target:isValid() then
        return
    end

    local Actor = require("openmw.types").Actor
    Actor.activeSpells(target):add({
        id = AEGIS_RITE_SMITE_SPELL_ID,
        effects = { 0 },
        caster = attacker,
        stackable = true,
    })

    addHitVfx(target)
    playHitSound(target)

    if target:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        target:sendEvent("SkillPerkSystem_AegisRiteRefresh", {
            playerId = attacker.id,
            duration = 0,
        })
    end
end

local function onRemoveAegisRiteTarget(e)
    if type(e) ~= "table" then
        return
    end

    local target = e.target
    if target == nil then
        return
    end
    if not target:isValid() then
        return
    end
    if not target:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        return
    end

    target:sendEvent("SkillPerkSystem_AegisRiteRefresh", {
        duration = 0,
    })
end

subsystems.block_aegis_rite = {
    eventHandlers = {
        SkillPerkSystem_PrimeAegisRite = onPrimeAegisRite,
        SkillPerkSystem_ApplyAegisRiteEffect = onApplyAegisRiteEffect,
        SkillPerkSystem_RemoveAegisRiteTarget = onRemoveAegisRiteTarget,
    },
}

-- End consolidated from SkillPerkSystem_BasePack/block_aegis_rite_global.lua
end

-- 12. apprentice hammer capture global logic
do
-- Begin consolidated from SkillPerkSystem_BasePack/apprentice_hammer_capture_global.lua
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local LOG_TAG = "[SkillPerkSystem_BasePack][ApprenticeHammer][CaptureGlobal]"
local registered = false

local function logDebug(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function registerRepairCapture()
    if registered then
        return
    end

    local itemUsage = interfaces.ItemUsage
    if itemUsage == nil or type(itemUsage.addHandlerForType) ~= "function" then
        logDebug("interfaces.ItemUsage.addHandlerForType unavailable")
        return
    end

    itemUsage.addHandlerForType(types.Repair, function(repairItem, actor, options)
        if repairItem == nil or actor == nil then
            logDebug("repair capture skipped; item or actor missing")
            return
        end

        logDebug("captured repair tool " .. tostring(repairItem.recordId))
        actor:sendEvent("SkillPerkSystem_RecordRepairTool", {
            item = repairItem,
            recordId = repairItem.recordId,
        })
    end)

    registered = true
    logDebug("registered repair capture handler")
end

registerRepairCapture()

subsystems.apprentice_hammer_capture = {
    eventHandlers = {},
    engineHandlers = {},
}

-- End consolidated from SkillPerkSystem_BasePack/apprentice_hammer_capture_global.lua
end


-- 13. combined eventHandlers
local function dispatchEvent(subsystemName, eventName, data)
    local subsystem = subsystems[subsystemName]
    local handlers = subsystem and subsystem.eventHandlers or nil
    local handler = handlers and handlers[eventName] or nil
    if type(handler) == "function" then
        handler(data)
    end
end

local eventHandlers = {
    SkillPerkSystem_BasePack_ModifySecurityToolCondition = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_ModifySecurityToolCondition", data) end,
    SkillPerkSystem_BasePack_CarefulRepairs_ModifyRepairToolCondition = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_CarefulRepairs_ModifyRepairToolCondition", data) end,
    SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest", data) end,
    SkillPerkSystem_BasePack_WeaponTemper_Request = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_WeaponTemper_Request", data) end,
    SkillPerkSystem_BasePack_ArmorRefit_Request = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_ArmorRefit_Request", data) end,
    SkillPerkSystem_BasePack_Masterwork_Request = function(data) dispatchEvent("security_global", "SkillPerkSystem_BasePack_Masterwork_Request", data) end,
    DrainLockpick = function(data) dispatchEvent("security_global", "DrainLockpick", data) end,

    SkillPerkSystem_BasePack_TreasureSense_Toggle = function(data) dispatchEvent("treasure_sense", "SkillPerkSystem_BasePack_TreasureSense_Toggle", data) end,
    SkillPerkSystem_BasePack_LuckyFind_Toggle = function(data) dispatchEvent("lucky_find", "SkillPerkSystem_BasePack_LuckyFind_Toggle", data) end,
    SkillPerkSystem_BasePack_FortunesHabit_Toggle = function(data)
        dispatchEvent("treasure_sense", "SkillPerkSystem_BasePack_FortunesHabit_Toggle", data)
        dispatchEvent("lucky_find", "SkillPerkSystem_BasePack_FortunesHabit_Toggle", data)
    end,
    SkillPerkSystem_BasePack_UnseenHand_PlayerToggle = function(data) dispatchEvent("unseen_hand", "SkillPerkSystem_BasePack_UnseenHand_PlayerToggle", data) end,

    SkillPerkSystem_ShortBladeState = function(data) dispatchEvent("shortblade", "SkillPerkSystem_ShortBladeState", data) end,
    SkillPerkSystem_CloseMeasureTriggered = function(data) dispatchEvent("shortblade", "SkillPerkSystem_CloseMeasureTriggered", data) end,
    SkillPerkSystem_AxeKindlingGripState = function(data) dispatchEvent("axe", "SkillPerkSystem_AxeKindlingGripState", data) end,
    SkillPerkSystem_MarksmanSteadyDrawState = function(data) dispatchEvent("axe", "SkillPerkSystem_MarksmanSteadyDrawState", data) end,
    SkillPerkSystem_SpearPointControlState = function(data) dispatchEvent("spear", "SkillPerkSystem_SpearPointControlState", data) end,
    SkillPerkSystem_HandToHandState = function(data) dispatchEvent("handtohand", "SkillPerkSystem_HandToHandState", data) end,
    SkillPerkSystem_BluntWeaponStrengthInArmsState = function(data) dispatchEvent("bluntweapon", "SkillPerkSystem_BluntWeaponStrengthInArmsState", data) end,
    SkillPerkSystem_ApplyPlatebreakerArmorDamage = function(data) dispatchEvent("bluntweapon", "SkillPerkSystem_ApplyPlatebreakerArmorDamage", data) end,
    SkillPerkSystem_ApplyHeavyHitterShieldDamage = function(data) dispatchEvent("bluntweapon", "SkillPerkSystem_ApplyHeavyHitterShieldDamage", data) end,
    SkillPerkSystem_ApplyReactiveShieldEnchant = function(data) dispatchEvent("block_reactive", "SkillPerkSystem_ApplyReactiveShieldEnchant", data) end,
    SkillPerkSystem_ApplyEmptyBodyGloveEnchant = function(data) dispatchEvent("block_reactive", "SkillPerkSystem_ApplyEmptyBodyGloveEnchant", data) end,
    SkillPerkSystem_ApplyBulwarkOfLight = function(data) dispatchEvent("block_bulwark", "SkillPerkSystem_ApplyBulwarkOfLight", data) end,
    SkillPerkSystem_PrimeAegisRite = function(data) dispatchEvent("block_aegis_rite", "SkillPerkSystem_PrimeAegisRite", data) end,
    SkillPerkSystem_ApplyAegisRiteEffect = function(data) dispatchEvent("block_aegis_rite", "SkillPerkSystem_ApplyAegisRiteEffect", data) end,
    SkillPerkSystem_RemoveAegisRiteTarget = function(data) dispatchEvent("block_aegis_rite", "SkillPerkSystem_RemoveAegisRiteTarget", data) end,
    [TARGET_SCRIPT_IDLE_EVENT] = function(data) dispatchEvent("shared_target_watcher", TARGET_SCRIPT_IDLE_EVENT, data) end,
}

-- 14. combined engineHandlers
local engineOrder = {
    "security_global",
    "shared_target_watcher",
    "handtohand",
    "treasure_sense",
    "lucky_find",
    "unseen_hand",
    "shortblade",
    "axe",
    "spear",
    "bluntweapon",
    "duelists_tempo",
    "block_reactive",
    "block_bulwark",
    "block_aegis_rite",
    "apprentice_hammer_capture",
}

local function callEngineHandler(name, ...)
    for _, subsystemName in ipairs(engineOrder) do
        local subsystem = subsystems[subsystemName]
        local handlers = subsystem and subsystem.engineHandlers or nil
        local handler = handlers and handlers[name] or nil
        if type(handler) == "function" then
            handler(...)
        end
    end
end

local function saveEngineHandlers()
    local saved = {}
    for _, subsystemName in ipairs(engineOrder) do
        local subsystem = subsystems[subsystemName]
        local handlers = subsystem and subsystem.engineHandlers or nil
        local handler = handlers and handlers.onSave or nil
        if type(handler) == "function" then
            saved[subsystemName] = handler()
        end
    end
    return saved
end

local function loadEngineHandlers(savedData)
    for _, subsystemName in ipairs(engineOrder) do
        local subsystem = subsystems[subsystemName]
        local handlers = subsystem and subsystem.engineHandlers or nil
        local handler = handlers and handlers.onLoad or nil
        if type(handler) == "function" then
            local subsystemSavedData = type(savedData) == "table" and savedData[subsystemName] or nil
            handler(subsystemSavedData)
        end
    end
end

return {
    eventHandlers = eventHandlers,
    engineHandlers = {
        onActivate = function(object, actor) callEngineHandler("onActivate", object, actor) end,
        onSave = saveEngineHandlers,
        onLoad = loadEngineHandlers,
        onNewGame = function() callEngineHandler("onNewGame") end,
        onUpdate = function(dt) callEngineHandler("onUpdate", dt) end,
    },
}
