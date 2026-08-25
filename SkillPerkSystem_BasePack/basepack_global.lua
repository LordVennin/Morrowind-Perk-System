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

local function validPlayerObject(player)
    if player == nil or type(player.sendEvent) ~= "function" then return false end
    if type(player.isValid) == "function" and not player:isValid() then return false end
    return true
end

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


-- 4b. legacy heavy armor target-watcher cleanup
-- Shock Padding and Juggernaut Stance are handled entirely by the player
-- runtime. Keep an inactive provider only so existing saves can receive a
-- disabled refresh and remove old actor-target script state.
local heavyArmorState = {
    playerId = nil,
    shockPaddingEnabled = false,
    juggernautEnabled = false,
}

local function heavyArmorTargetStateActive()
    return false
end

local function sendHeavyArmorState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_HeavyArmorRefresh", heavyArmorState)
    end
end

local function onHeavyArmorState(data)
    heavyArmorState = {
        playerId = type(data) == "table" and type(data.playerId) == "string" and data.playerId or nil,
        shockPaddingEnabled = false,
        juggernautEnabled = false,
    }
    -- The false transition pushes the disabled state to scripts already
    -- attached by older versions; it never requests a new actor scan.
    onTargetWatcherProviderStateChanged("heavyarmor", false)
end

registerTargetWatcherProvider("heavyarmor", {
    isActive = heavyArmorTargetStateActive,
    sendState = sendHeavyArmorState,
})

subsystems.heavyarmor = {
    eventHandlers = {
        SkillPerkSystem_HeavyArmorState = onHeavyArmorState,
    },
    engineHandlers = {},
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
    masterOfKnivesEnabled = false,
}
local SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT = "SkillPerkSystem_CloseMeasureTriggered"
local SHORT_BLADE_MASTER_OF_KNIVES_TRIGGER_EVENT = "SkillPerkSystem_MasterOfKnivesTriggered"

local function shortBladeTargetStateActive()
    return (shortBladeState.vitalStrikeEnabled == true or shortBladeState.flashCutEnabled == true or shortBladeState.closeMeasureEnabled == true or shortBladeState.masterOfKnivesEnabled == true) and type(shortBladeState.playerId) == "string" and shortBladeState.playerId ~= ""
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
        masterOfKnivesEnabled = data.masterOfKnivesEnabled == true,
    }
    refreshWatchers()
end

local function forwardShortBladePlayerTrigger(data, requiredStateKey, eventName)
    if type(data) ~= "table" or type(data.playerId) ~= "string" or data.playerId ~= shortBladeState.playerId then
        return
    end
    if not shortBladeState[requiredStateKey] then
        return
    end

    local player = world.players[1]
    if player == nil or type(player.sendEvent) ~= "function" or player.id ~= data.playerId then
        return
    end

    player:sendEvent(eventName, data)
end

local function forwardCloseMeasureTrigger(data)
    forwardShortBladePlayerTrigger(data, "closeMeasureEnabled", SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT)
end

local function forwardMasterOfKnivesTrigger(data)
    forwardShortBladePlayerTrigger(data, "masterOfKnivesEnabled", SHORT_BLADE_MASTER_OF_KNIVES_TRIGGER_EVENT)
end

registerTargetWatcherProvider("shortblade", {
    isActive = shortBladeTargetStateActive,
    sendState = sendState,
})

subsystems.shortblade = {
    eventHandlers = {
        SkillPerkSystem_ShortBladeState = onShortBladeState,
        [SHORT_BLADE_CLOSE_MEASURE_TRIGGER_EVENT] = forwardCloseMeasureTrigger,
        [SHORT_BLADE_MASTER_OF_KNIVES_TRIGGER_EVENT] = forwardMasterOfKnivesTrigger,
    },
    engineHandlers = {
        onLoad = function()
            refreshWatchers()
        end,
    },
}

end

-- 5b. sneak crit and One With Shadow global handling
do
local core = require("openmw.core")
local types = require("openmw.types")
local world = require("openmw.world")
local Actor = types.Actor

local LOG_TAG = "[SkillPerkSystem_BasePack][Sneak][Global]"
local function log(message) print(LOG_TAG .. " " .. tostring(message)) end

local sneakCritState = {
    playerId = nil,
    killersInstinctEnabled = false,
    knifeInTheDarkEnabled = false,
    sneaking = false,
}

local function sneakCritTargetStateActive()
    return sneakCritState.killersInstinctEnabled == true
        and type(sneakCritState.playerId) == "string" and sneakCritState.playerId ~= ""
end

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_SneakCritRefresh", sneakCritState)
    end
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("sneakcrit", sneakCritTargetStateActive())
end

local function onSneakCritState(data)
    if type(data) ~= "table" then
        return
    end

    sneakCritState = {
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        killersInstinctEnabled = data.killersInstinctEnabled == true,
        knifeInTheDarkEnabled = data.knifeInTheDarkEnabled == true,
        sneaking = data.sneaking == true,
    }
    refreshWatchers()
    -- Sneak toggles arrive through the same event; targets already attached
    -- need the fresh flag even when the provider's active state is unchanged.
    sendTargetWatcherStateToAttached(targetWatcher.providers["sneakcrit"])
end

registerTargetWatcherProvider("sneakcrit", {
    isActive = sneakCritTargetStateActive,
    sendState = sendState,
})

local function effectTypeId(name, fallback)
    local ok, value = pcall(function() return core.magic.EFFECT_TYPE[name] end)
    if ok and value ~= nil then return value end
    return fallback
end

-- ---- One With Shadow: Chameleon while dark and unburdened ----
--
-- The Chameleon ability is a dynamic record, so this side owns creating it
-- and adding/removing it from the player; the player script only reports
-- whether the capstone's conditions hold.

local CHAMELEON_MAGNITUDE = 10
local chameleonRecordId = nil

local function ensureChameleonRecord()
    if chameleonRecordId ~= nil then
        local ok, record = pcall(function() return core.magic.spells.records[chameleonRecordId] end)
        if ok and record ~= nil then return chameleonRecordId end
        chameleonRecordId = nil
    end

    local okDraft, draft = pcall(core.magic.spells.createRecordDraft, {
        name = "One With Shadow",
        type = core.magic.SPELL_TYPE.Ability,
        cost = 0,
        isAutocalc = false,
        effects = {
            {
                id = effectTypeId("Chameleon", "chameleon"),
                magnitudeMin = CHAMELEON_MAGNITUDE,
                magnitudeMax = CHAMELEON_MAGNITUDE,
                duration = 1,
                area = 0,
                range = core.magic.RANGE.Self,
            },
        },
    })
    if not okDraft or draft == nil then
        log("One With Shadow draft failed: " .. tostring(draft))
        return nil
    end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then
        log("One With Shadow record creation failed: " .. tostring(record))
        return nil
    end
    chameleonRecordId = record.id
    log("created One With Shadow record=" .. tostring(record.id))
    return chameleonRecordId
end

local function playerSpells(player)
    local okSpells, spells = pcall(Actor.spells, player)
    return okSpells and spells or nil
end

local function onShadowSet(data)
    local player = type(data) == "table" and data.player or nil
    if not validPlayerObject(player) then
        return
    end
    local wantActive = type(data) == "table" and data.active == true

    if wantActive and ensureChameleonRecord() == nil then
        return
    end
    if chameleonRecordId == nil then
        return
    end

    local spells = playerSpells(player)
    if spells == nil then
        return
    end
    -- Act without asking whether it is held; see reconcileFamily above.
    if wantActive then
        pcall(function() spells:add(chameleonRecordId) end)
    else
        pcall(function() spells:remove(chameleonRecordId) end)
    end
end

subsystems.sneakcrit = {
    eventHandlers = {
        SkillPerkSystem_SneakCritState = onSneakCritState,
        SkillPerkSystem_BasePack_OneWithShadow_Set = onShadowSet,
    },
    engineHandlers = {
        onSave = function()
            return {
                chameleonRecordId = chameleonRecordId,
            }
        end,
        onLoad = function(data)
            chameleonRecordId = type(data) == "table" and type(data.chameleonRecordId) == "string"
                and data.chameleonRecordId or nil
            refreshWatchers()
        end,
    },
}

end

-- 5c. conjuration global handling
do
local core = require("openmw.core")
local types = require("openmw.types")
local world = require("openmw.world")
local Actor = types.Actor

local LOG_TAG = "[SkillPerkSystem_BasePack][Conjuration][Global]"
local function log(message) print(LOG_TAG .. " " .. tostring(message)) end

local function conjEffectId(name, fallback)
    local ok, value = pcall(function() return core.magic.EFFECT_TYPE[name] end)
    if ok and value ~= nil then return value end
    return fallback
end

-- Every grant in this tree is a dynamic record added to or removed from the
-- player's spell list as the player script reports perk state. Records are
-- cached by grant key and persisted, so a save reuses its records instead of
-- accumulating new ones.
local conjRecords = {}

local function selfEffect(id, magnitude, duration)
    return {
        id = id,
        magnitudeMin = magnitude,
        magnitudeMax = magnitude,
        duration = duration,
        area = 0,
        range = core.magic.RANGE.Self,
    }
end

-- Grant definitions, keyed by the ids the player script sends. Powers are
-- once per day by engine rule; the pact tiers replace one another.
local GRANTS = {
    undead1 = { name = "Ancestral Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonAncestralGhost", "summonancestralghost"), 1, 60) } },
    undead2 = { name = "Deepened Ancestral Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonBonewalker", "summonbonewalker"), 1, 120) } },
    undead3 = { name = "Greater Ancestral Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonBonelord", "summonbonelord"), 1, 180) } },
    daedra1 = { name = "Daedric Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonScamp", "summonscamp"), 1, 60) } },
    daedra2 = { name = "Deepened Daedric Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonClannfear", "summonclannfear"), 1, 120) } },
    daedra3 = { name = "Greater Daedric Pact", type = "Power",
        effects = { selfEffect(conjEffectId("SummonDremora", "summondremora"), 1, 180) } },
    ward1 = { name = "Spectral Ward", type = "Ability",
        effects = { selfEffect(conjEffectId("Sanctuary", "sanctuary"), 10, 1) } },
    -- Granted as an Ability so the engine raises maximum magicka through its
    -- own effect path. Writing the dynamic stat's modifier directly does not
    -- do this: for health, magicka and fatigue the engine drives the value
    -- from active effects, and abilities are the mechanism that feeds it.
    tether1 = { name = "Soul Tether", type = "Ability",
        effects = { selfEffect(conjEffectId("FortifyMagicka", "fortifymagicka"), 30, 1) } },
}

-- Grant families: at most one member of a family is held at a time, selected
-- by the tier the player script reports (0 = none).
local FAMILIES = {
    undead = { "undead1", "undead2", "undead3" },
    daedra = { "daedra1", "daedra2", "daedra3" },
    ward = { "ward1" },
    tether = { "tether1" },
}

-- Families whose grant is a once-per-day Power. Handing the player a record
-- they were not already holding gives them a fresh daily use, so these are
-- gated on our own record of when the pact was last spent.
local DAILY_FAMILIES = { undead = true, daedra = true }

local FAMILY_OF_KEY = {}
for family, keys in pairs(FAMILIES) do
    for _, key in ipairs(keys) do FAMILY_OF_KEY[key] = family end
end

-- Every record id this pack has ever issued, mapped to its family. Tier swaps
-- must be able to take back a record created in an earlier session, so this is
-- persisted alongside the current-id cache and is the authority on what may be
-- removed. Nothing outside this table is ever removed from the player.
local conjIssued = {}

-- The grant key each family currently holds, and the game day on which each
-- daily family was last spent. Both persist: the whole point is that they
-- outlive a perk being toggled off and back on.
local conjHeldKey = {}
local conjUsedDay = {}

local function spellTypeFor(kind)
    if kind == "Power" then return core.magic.SPELL_TYPE.Power end
    if kind == "Ability" then return core.magic.SPELL_TYPE.Ability end
    return core.magic.SPELL_TYPE.Spell
end

local function ensureGrantRecord(key)
    local grant = GRANTS[key]
    if grant == nil then return nil end

    -- Trust the cache. core.magic.spells.records does not necessarily index
    -- records created through world.createRecord, so treating a nil lookup as
    -- "gone" minted a fresh record on every reconcile -- which both leaked
    -- records and lost the id needed to take the previous tier back.
    local cachedId = conjRecords[key]
    if cachedId ~= nil then
        return cachedId
    end

    local okDraft, draft = pcall(core.magic.spells.createRecordDraft, {
        name = grant.name,
        type = spellTypeFor(grant.type),
        cost = grant.cost or 0,
        alwaysSucceedFlag = grant.type ~= "Spell",
        isAutocalc = false,
        starterSpellFlag = false,
        effects = grant.effects,
    })
    if not okDraft or draft == nil then
        log("draft failed for " .. key .. ": " .. tostring(draft))
        return nil
    end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then
        log("record creation failed for " .. key .. ": " .. tostring(record))
        return nil
    end
    conjRecords[key] = record.id
    conjIssued[record.id] = FAMILY_OF_KEY[key]
    log("created record " .. key .. "=" .. tostring(record.id))
    return record.id
end

local function playerSpellList(player)
    local ok, spells = pcall(Actor.spells, player)
    return ok and spells or nil
end

-- Reconciles one family to exactly one held record (or none).
--
-- Deliberately does not ask whether the player holds a spell before acting.
-- spells:has() answers "no" for dynamically created ids and list enumeration
-- is no more trustworthy for them, so every previous tier is simply removed
-- and the desired one added: adding a spell already held is a no-op, and
-- removing one not held is harmless. That makes the outcome independent of
-- what the engine is willing to report back to us.
local function reconcileFamily(spells, family, desiredIndex)
    local keys = FAMILIES[family]
    if keys == nil then return end

    local desiredId = nil
    if desiredIndex >= 1 and keys[desiredIndex] ~= nil then
        desiredId = ensureGrantRecord(keys[desiredIndex])
    end

    -- Take back every record this pack has issued for the family, including
    -- ones minted in an earlier session, except the one being kept.
    for recordId, issuedFamily in pairs(conjIssued) do
        if issuedFamily == family and recordId ~= desiredId then
            local ok = pcall(function() spells:remove(recordId) end)
            if not ok then
                local okRecord, record = pcall(function() return core.magic.spells.records[recordId] end)
                if okRecord and record ~= nil then
                    pcall(function() spells:remove(record) end)
                end
            end
        end
    end

    if desiredId ~= nil then
        local ok, err = pcall(function() spells:add(desiredId) end)
        if not ok then log("grant add failed " .. family .. ": " .. tostring(err)) end
    end
end

-- Refuses to hand over a daily power the player has already spent today.
--
-- Toggling a perk off and on, or moving to a different tier, replaces the
-- Power record and hands back a fresh daily use, which let a player cycle
-- through every tier for a free summon each. Our own "spent on day N" record
-- lives in save data and is unaffected by any of that, so the pact simply
-- stays gone until the next day. A player who has not toggled anything keeps
-- the record they already hold and never notices this.
local function dailyGate(family, tierIndex, currentDay)
    if not DAILY_FAMILIES[family] or tierIndex < 1 then
        return tierIndex
    end
    local keys = FAMILIES[family]
    local desiredKey = keys[tierIndex]
    if desiredKey ~= nil and conjHeldKey[family] ~= desiredKey
            and conjUsedDay[family] == currentDay then
        log(family .. " pact already spent today; withholding until tomorrow")
        return 0
    end
    return tierIndex
end

local function onSetGrants(data)
    local player = type(data) == "table" and data.player or nil
    if not validPlayerObject(player) then
        return
    end
    local spells = playerSpellList(player)
    if spells == nil then
        return
    end

    local function tier(value, maximum)
        local number = math.floor(tonumber(value) or 0)
        return math.max(0, math.min(maximum, number))
    end

    local currentDay = math.floor(tonumber(data.currentDay) or 0)

    -- The player script watches for a pact power actually taking effect and
    -- reports the day, so a use is recorded even if the perk is toggled a
    -- moment later.
    for family in pairs(DAILY_FAMILIES) do
        local reported = math.floor(tonumber(data[family .. "UsedDay"]) or -1)
        if reported >= 0 and reported > (conjUsedDay[family] or -1) then
            conjUsedDay[family] = reported
        end
    end

    local granted = {}
    for _, family in ipairs({ "undead", "daedra", "ward", "tether" }) do
        local requested = tier(data[family .. "Tier"], #FAMILIES[family])
        local allowed = dailyGate(family, requested, currentDay)
        reconcileFamily(spells, family, allowed)
        local heldKey = allowed >= 1 and FAMILIES[family][allowed] or nil
        conjHeldKey[family] = heldKey
        granted[family] = heldKey and conjRecords[heldKey] or nil
    end

    -- Tell the player which record ids it now holds, so it can watch for them
    -- being cast without having to guess from effect ids.
    if type(player.sendEvent) == "function" then
        player:sendEvent("SkillPerkSystem_BasePack_Conjuration_Granted", granted)
    end
end

subsystems.conjuration = {
    eventHandlers = {
        SkillPerkSystem_BasePack_Conjuration_SetGrants = onSetGrants,
    },
    engineHandlers = {
        onSave = function()
            return {
                conjRecords = conjRecords,
                conjIssued = conjIssued,
                conjHeldKey = conjHeldKey,
                conjUsedDay = conjUsedDay,
            }
        end,
        onLoad = function(data)
            conjRecords = {}
            conjIssued = {}
            conjHeldKey = {}
            conjUsedDay = {}
            local savedHeld = type(data) == "table" and data.conjHeldKey or nil
            if type(savedHeld) == "table" then
                for family, key in pairs(savedHeld) do
                    if FAMILIES[family] ~= nil and GRANTS[key] ~= nil then conjHeldKey[family] = key end
                end
            end
            local savedUsed = type(data) == "table" and data.conjUsedDay or nil
            if type(savedUsed) == "table" then
                for family, day in pairs(savedUsed) do
                    if DAILY_FAMILIES[family] and type(day) == "number" then conjUsedDay[family] = day end
                end
            end
            local saved = type(data) == "table" and data.conjRecords or nil
            if type(saved) == "table" then
                for key, recordId in pairs(saved) do
                    if type(key) == "string" and type(recordId) == "string" and GRANTS[key] ~= nil then
                        conjRecords[key] = recordId
                        conjIssued[recordId] = FAMILY_OF_KEY[key]
                    end
                end
            end
            local savedIssued = type(data) == "table" and data.conjIssued or nil
            if type(savedIssued) == "table" then
                for recordId, family in pairs(savedIssued) do
                    if type(recordId) == "string" and FAMILIES[family] ~= nil then
                        conjIssued[recordId] = family
                    end
                end
            end
        end,
    },
}

end

-- 5d. destruction global handling
do
local core = require("openmw.core")
local types = require("openmw.types")
local world = require("openmw.world")
local Actor = types.Actor

local LOG_TAG = "[SkillPerkSystem_BasePack][Destruction][Global]"
local function log(message) print(LOG_TAG .. " " .. tostring(message)) end

local function destrEffectId(name, fallback)
    local ok, value = pcall(function() return core.magic.EFFECT_TYPE[name] end)
    if ok and value ~= nil then return value end
    return fallback
end

-- ---- Arcane Reservoir: maximum magicka, granted as an Ability -------------
local reservoirRecordId = nil

local function ensureReservoirRecord()
    if reservoirRecordId ~= nil then
        return reservoirRecordId
    end
    local okDraft, draft = pcall(core.magic.spells.createRecordDraft, {
        name = "Arcane Reservoir",
        type = core.magic.SPELL_TYPE.Ability,
        cost = 0,
        isAutocalc = false,
        effects = {
            {
                id = destrEffectId("FortifyMagicka", "fortifymagicka"),
                magnitudeMin = 25, magnitudeMax = 25, duration = 1,
                area = 0, range = core.magic.RANGE.Self,
            },
        },
    })
    if not okDraft or draft == nil then
        log("Arcane Reservoir draft failed: " .. tostring(draft))
        return nil
    end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then
        log("Arcane Reservoir record creation failed: " .. tostring(record))
        return nil
    end
    reservoirRecordId = record.id
    log("created Arcane Reservoir record=" .. tostring(record.id))
    return reservoirRecordId
end

local function onSetGrants(data)
    local player = type(data) == "table" and data.player or nil
    if not validPlayerObject(player) then
        return
    end
    local okSpells, spells = pcall(Actor.spells, player)
    if not okSpells or spells == nil then
        return
    end
    local wanted = math.floor(tonumber(data.reservoirTier) or 0) >= 1
    if wanted and ensureReservoirRecord() == nil then
        return
    end
    if reservoirRecordId == nil then
        return
    end
    -- Acting without asking whether it is held: the engine does not reliably
    -- report holdings for dynamically created records.
    if wanted then
        pcall(function() spells:add(reservoirRecordId) end)
    else
        pcall(function() spells:remove(reservoirRecordId) end)
    end
end

-- ---- Rider state, shared with the actor-target script --------------------
local riderState = {
    playerId = nil,
    searingHeat = false,
    bitingCold = false,
    stormChannel = false,
    sunderingRuin = false,
    witheringCurse = false,
    annihilationMastery = false,
}

local function ridersActive()
    return type(riderState.playerId) == "string" and riderState.playerId ~= ""
        and (riderState.searingHeat or riderState.bitingCold or riderState.stormChannel
            or riderState.sunderingRuin or riderState.witheringCurse
            or riderState.annihilationMastery)
end

local attachLogged = 0

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        if attachLogged < 20 then
            attachLogged = attachLogged + 1
            log("sending rider state to " .. tostring(actor.recordId))
        end
        actor:sendEvent("SkillPerkSystem_BasePack_Destruction_RiderRefresh", riderState)
    end
end

local function refreshWatchers()
    onTargetWatcherProviderStateChanged("destruction", ridersActive())
end

local function onSetRiders(data)
    if type(data) ~= "table" then
        return
    end
    log("rider state received from player; active=" .. tostring(data.playerId ~= nil))
    riderState = {
        playerId = type(data.playerId) == "string" and data.playerId or nil,
        searingHeat = data.searingHeat == true,
        bitingCold = data.bitingCold == true,
        stormChannel = data.stormChannel == true,
        sunderingRuin = data.sunderingRuin == true,
        witheringCurse = data.witheringCurse == true,
        annihilationMastery = data.annihilationMastery == true,
    }
    refreshWatchers()
    log("riders active=" .. tostring(ridersActive()) .. "; watcher refresh requested")
    sendTargetWatcherStateToAttached(targetWatcher.providers["destruction"])
end

registerTargetWatcherProvider("destruction", {
    isActive = ridersActive,
    sendState = sendState,
})

-- ---- Rider effects ------------------------------------------------------
--
-- Records are cached by shape (effect plus rounded magnitude and duration) so
-- a burning tick of a given strength reuses one record instead of minting a
-- new one per cast.
local riderRecords = {}

local function riderRecord(name, effectName, effectFallback, magnitude, duration, affectedSkill, affectedAttribute)
    magnitude = math.max(1, math.floor(tonumber(magnitude) or 0))
    duration = math.max(1, math.floor(tonumber(duration) or 0))
    local key = table.concat({
        effectName, magnitude, duration,
        tostring(affectedSkill or ""), tostring(affectedAttribute or ""),
    }, "|")
    local cached = riderRecords[key]
    if cached ~= nil then
        return cached
    end

    local effect = {
        id = destrEffectId(effectName, effectFallback),
        magnitudeMin = magnitude, magnitudeMax = magnitude,
        duration = duration, area = 0, range = core.magic.RANGE.Target,
    }
    if affectedSkill ~= nil then effect.affectedSkill = affectedSkill end
    if affectedAttribute ~= nil then effect.affectedAttribute = affectedAttribute end

    local okDraft, draft = pcall(core.magic.spells.createRecordDraft, {
        name = name,
        type = core.magic.SPELL_TYPE.Spell,
        cost = 0,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = { effect },
    })
    if not okDraft or draft == nil then
        log("rider draft failed (" .. key .. "): " .. tostring(draft))
        return nil
    end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then
        log("rider record creation failed (" .. key .. "): " .. tostring(record))
        return nil
    end
    riderRecords[key] = record.id
    return record.id
end

local function applyRider(target, caster, recordId)
    if recordId == nil or target == nil then
        return
    end
    if type(target.isValid) == "function" and not target:isValid() then
        return
    end
    local ok, err = pcall(function()
        Actor.activeSpells(target):add({
            id = recordId,
            effects = { 0 },
            caster = caster,
            stackable = true,
            ignoreSpellAbsorption = true,
            ignoreReflect = true,
            ignoreResistances = false,
        })
    end)
    if not ok then
        log("rider application failed: " .. tostring(err))
    end
end

-- The target script has classified an incoming hit and asked for the riders
-- that go with it. Everything it can ask for is bounded by the rider state.
local ridersLogged = 0

local function onApplyRiders(data)
    if type(data) ~= "table" then
        return
    end
    local target = data.target
    local caster = world.players[1]
    if target == nil or caster == nil or caster.id ~= riderState.playerId then
        return
    end

    -- Mirrors the target-side probe: shows that a classified hit made it here
    -- and what it asked for, so a break between the two sides is visible.
    if ridersLogged < 12 then
        ridersLogged = ridersLogged + 1
        log(string.format("rider request burn=%s slow=%s magickaBurn=%s sunder=%s weakness=%s",
            tostring(data.burnPerSecond), tostring(data.slowMagnitude),
            tostring(data.magickaBurn), tostring(data.sunderSkill), tostring(data.weaknessEffect)))
    end

    if riderState.searingHeat then
        local burn = tonumber(data.burnPerSecond) or 0
        if burn > 0 then
            applyRider(target, caster, riderRecord("Searing Heat", "FireDamage", "firedamage",
                burn, tonumber(data.burnSeconds) or 6))
        end
    end
    if riderState.bitingCold then
        -- Slowing an actor means draining Speed; there is no "slow" effect.
        local slow = tonumber(data.slowMagnitude) or 0
        if slow > 0 then
            applyRider(target, caster, riderRecord("Biting Cold", "DrainAttribute", "drainattribute",
                slow, tonumber(data.slowSeconds) or 8, nil, "speed"))
        end
    end
    if riderState.stormChannel then
        local burn = tonumber(data.magickaBurn) or 0
        if burn > 0 then
            applyRider(target, caster, riderRecord("Storm Channel", "DamageMagicka", "damagemagicka",
                burn, 1))
        end
    end
    if riderState.sunderingRuin and type(data.sunderSkill) == "string" then
        applyRider(target, caster, riderRecord("Sundering Ruin", "DrainSkill", "drainskill",
            tonumber(data.sunderMagnitude) or 15, tonumber(data.sunderSeconds) or 20, data.sunderSkill))
    end
    if riderState.annihilationMastery and type(data.weaknessEffect) == "string" then
        applyRider(target, caster, riderRecord("Annihilation Mastery", data.weaknessEffect,
            data.weaknessEffect:lower(), tonumber(data.weaknessMagnitude) or 10,
            tonumber(data.weaknessSeconds) or 8))
    end
end

-- Withering Curse: the target worked out what its Drain effects took, and the
-- player script pays it back.
local function onWitheringReturn(data)
    if type(data) ~= "table" or not riderState.witheringCurse then
        return
    end
    local player = world.players[1]
    if player == nil or player.id ~= riderState.playerId then
        return
    end
    if type(player.sendEvent) == "function" then
        player:sendEvent("SkillPerkSystem_BasePack_Destruction_WitheringReturn", {
            health = tonumber(data.health) or 0,
            fatigue = tonumber(data.fatigue) or 0,
            magicka = tonumber(data.magicka) or 0,
        })
    end
    if type(data.fortifySkill) == "string" or type(data.fortifyAttribute) == "string" then
        local recordId = riderRecord("Withering Curse", "FortifySkill", "fortifyskill",
            tonumber(data.fortifyMagnitude) or 10, tonumber(data.fortifySeconds) or 20,
            data.fortifySkill, nil)
        if type(data.fortifyAttribute) == "string" then
            recordId = riderRecord("Withering Curse", "FortifyAttribute", "fortifyattribute",
                tonumber(data.fortifyMagnitude) or 10, tonumber(data.fortifySeconds) or 20,
                nil, data.fortifyAttribute)
        end
        applyRider(player, player, recordId)
    end
end

-- Answers the console diagnostic: reports what the global side believes and,
-- crucially, how many actors the watcher has actually attached the target
-- script to, which is the stage that cannot be seen from the player.
local function onDiagnose()
    log("---- diagnostic ----")
    log("rider caster=" .. tostring(riderState.playerId)
        .. " fire=" .. tostring(riderState.searingHeat)
        .. " frost=" .. tostring(riderState.bitingCold)
        .. " shock=" .. tostring(riderState.stormChannel)
        .. " sunder=" .. tostring(riderState.sunderingRuin)
        .. " wither=" .. tostring(riderState.witheringCurse)
        .. " weakness=" .. tostring(riderState.annihilationMastery))
    log("ridersActive=" .. tostring(ridersActive()))

    local attached, withScript = 0, 0
    for actor in pairs(targetWatcher.attachedTargets) do
        attached = attached + 1
        local ok, has = pcall(function() return actor:hasScript(BASEPACK_ACTOR_TARGET_SCRIPT) end)
        if ok and has then withScript = withScript + 1 end
    end
    log("watcher attachedTargets=" .. attached .. " still carrying the target script=" .. withScript)

    local nearbyActors = 0
    for _, actor in ipairs(world.activeActors) do
        nearbyActors = nearbyActors + 1
    end
    log("active actors in world=" .. nearbyActors)

    -- Push state out again so any attached target re-reports.
    refreshWatchers()
    sendTargetWatcherStateToAttached(targetWatcher.providers["destruction"])
end

-- A successful Destruction cast: forward the notice to every attached target
-- so each opens its short active-spell scan window.
local castNoticeLogged = 0

local function onCastNotice(data)
    local player = type(data) == "table" and data.player or nil
    if player == nil or player.id ~= riderState.playerId then
        return
    end
    if castNoticeLogged < 8 then
        castNoticeLogged = castNoticeLogged + 1
        log("broadcasting cast notice for " .. tostring(data.spellId))
    end
    for actor in pairs(targetWatcher.attachedTargets) do
        if isValidTargetWatcherActor(actor) and actor:hasScript(BASEPACK_ACTOR_TARGET_SCRIPT) then
            actor:sendEvent("SkillPerkSystem_BasePack_Destruction_CastNotice", { spellId = data.spellId })
        end
    end
end

-- A freshly attached target asks for its state, because the push sent when the
-- watcher attached it arrived before the script existed.
local function onRequestState(data)
    local target = type(data) == "table" and data.target or nil
    if target == nil then
        return
    end
    sendState(target)
end

subsystems.destruction = {
    eventHandlers = {
        SkillPerkSystem_BasePack_Destruction_RequestState = onRequestState,
        SkillPerkSystem_BasePack_Destruction_CastNotice = onCastNotice,
        SkillPerkSystem_BasePack_Destruction_Diagnose = onDiagnose,
        SkillPerkSystem_BasePack_Destruction_SetGrants = onSetGrants,
        SkillPerkSystem_BasePack_Destruction_SetRiders = onSetRiders,
        SkillPerkSystem_BasePack_Destruction_ApplyRiders = onApplyRiders,
        SkillPerkSystem_BasePack_Destruction_Withering = onWitheringReturn,
    },
    engineHandlers = {
        onSave = function()
            return { reservoirRecordId = reservoirRecordId, riderRecords = riderRecords }
        end,
        onLoad = function(data)
            reservoirRecordId = type(data) == "table" and type(data.reservoirRecordId) == "string"
                and data.reservoirRecordId or nil
            riderRecords = {}
            local saved = type(data) == "table" and data.riderRecords or nil
            if type(saved) == "table" then
                for key, recordId in pairs(saved) do
                    if type(key) == "string" and type(recordId) == "string" then
                        riderRecords[key] = recordId
                    end
                end
            end
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
    openPalmEnabled = false,
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
    return handToHandState.openPalmEnabled
        or handToHandState.ironKnucklesEnabled
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
        openPalmEnabled = data.openPalmEnabled == true,
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
    SkillPerkSystem_BasePack_IngredientLoreApply = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_IngredientLoreApply", data) end,
    SkillPerkSystem_BasePack_AlchemyRefundIngredient = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_AlchemyRefundIngredient", data) end,
    SkillPerkSystem_BasePack_DualDistillationCoatRequest = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationCoatRequest", data) end,
    SkillPerkSystem_BasePack_DualDistillationRestoreCoating = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationRestoreCoating", data) end,
    SkillPerkSystem_BasePack_DualDistillationClearCoating = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationClearCoating", data) end,
    SkillPerkSystem_BasePack_DualDistillationHitRequest = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationHitRequest", data) end,
    SkillPerkSystem_BasePack_DualDistillationConvertPoisons = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationConvertPoisons", data) end,
    SkillPerkSystem_BasePack_DualDistillationDrinkPoison = function(data) dispatchEvent("alchemy", "SkillPerkSystem_BasePack_DualDistillationDrinkPoison", data) end,

    SkillPerkSystem_ShortBladeState = function(data) dispatchEvent("shortblade", "SkillPerkSystem_ShortBladeState", data) end,
    SkillPerkSystem_SneakCritState = function(data) dispatchEvent("sneakcrit", "SkillPerkSystem_SneakCritState", data) end,
    SkillPerkSystem_BasePack_OneWithShadow_Set = function(data) dispatchEvent("sneakcrit", "SkillPerkSystem_BasePack_OneWithShadow_Set", data) end,
    SkillPerkSystem_BasePack_Conjuration_SetGrants = function(data) dispatchEvent("conjuration", "SkillPerkSystem_BasePack_Conjuration_SetGrants", data) end,
    SkillPerkSystem_BasePack_Destruction_SetGrants = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_SetGrants", data) end,
    SkillPerkSystem_BasePack_Destruction_SetRiders = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_SetRiders", data) end,
    SkillPerkSystem_BasePack_Destruction_ApplyRiders = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_ApplyRiders", data) end,
    SkillPerkSystem_BasePack_Destruction_Withering = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_Withering", data) end,
    SkillPerkSystem_BasePack_Destruction_Diagnose = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_Diagnose", data) end,
    SkillPerkSystem_BasePack_Destruction_RequestState = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_RequestState", data) end,
    SkillPerkSystem_BasePack_Destruction_CastNotice = function(data) dispatchEvent("destruction", "SkillPerkSystem_BasePack_Destruction_CastNotice", data) end,
    SkillPerkSystem_CloseMeasureTriggered = function(data) dispatchEvent("shortblade", "SkillPerkSystem_CloseMeasureTriggered", data) end,
    SkillPerkSystem_MasterOfKnivesTriggered = function(data) dispatchEvent("shortblade", "SkillPerkSystem_MasterOfKnivesTriggered", data) end,
    SkillPerkSystem_AxeKindlingGripState = function(data) dispatchEvent("axe", "SkillPerkSystem_AxeKindlingGripState", data) end,
    SkillPerkSystem_MarksmanSteadyDrawState = function(data) dispatchEvent("axe", "SkillPerkSystem_MarksmanSteadyDrawState", data) end,
    SkillPerkSystem_SpearPointControlState = function(data) dispatchEvent("spear", "SkillPerkSystem_SpearPointControlState", data) end,
    SkillPerkSystem_HandToHandState = function(data) dispatchEvent("handtohand", "SkillPerkSystem_HandToHandState", data) end,
    SkillPerkSystem_HeavyArmorState = function(data) dispatchEvent("heavyarmor", "SkillPerkSystem_HeavyArmorState", data) end,
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

-- Alchemy restricted global bridges (Ingredient Lore, Careful Measure, and Dual Distillation)
local function __basepack_initAlchemyGlobal()
local core = require("openmw.core")
local types = require("openmw.types")
local world = require("openmw.world")
local Actor = types.Actor
local INGREDIENT_LORE_TIERS = {
    { minimumAlchemy = 80, magnitude = 8, duration = 12 },
    { minimumAlchemy = 60, magnitude = 6, duration = 8 },
    { minimumAlchemy = 40, magnitude = 4, duration = 5 },
    { minimumAlchemy = 0, magnitude = 2, duration = 3 },
}
local LORE_RESULT_EVENT = "SkillPerkSystem_BasePack_IngredientLoreResult"
local REFUND_RESULT_EVENT = "SkillPerkSystem_BasePack_AlchemyRefundResult"
local LOG_TAG = "[SkillPerkSystem_BasePack][Alchemy][Global]"
local ingredientLoreSpellCache = {}

local function log(message) print(LOG_TAG .. " " .. tostring(message)) end
local function validPlayer(player)
    if player == nil or type(player.sendEvent) ~= "function" then return false end
    if type(player.isValid) == "function" and not player:isValid() then return false end
    for _, candidate in pairs(world.players or {}) do if candidate == player then return true end end
    return false
end
local function ingredientRecord(recordId)
    if type(recordId) ~= "string" or recordId == "" then return nil end
    local ok, record = pcall(types.Ingredient.record, recordId)
    return ok and record or nil
end
local function spellRecord(recordId)
    if type(recordId) ~= "string" or recordId == "" then return nil end
    local ok, record = pcall(function() return core.magic.spells.records[recordId] end)
    return ok and record or nil
end
local function sendResult(player, eventName, result)
    if player ~= nil and type(player.sendEvent) == "function" then player:sendEvent(eventName, result) end
end
local function failLore(data, reason)
    log("Ingredient Lore rejected: " .. tostring(reason))
    sendResult(data and data.player, LORE_RESULT_EVENT, {
        requestId = data and data.requestId, success = false,
        ingredientRecordId = data and data.ingredientRecordId,
        sourceEffectIndex = data and data.sourceEffectIndex, failureReason = reason,
    })
end
local function effectRecord(effectId)
    if type(effectId) ~= "string" or effectId == "" then return nil end
    local ok, record = pcall(function() return core.magic.effects.records[effectId] end)
    return ok and record or nil
end
local function validatedTierIndex(player)
    local modified = 0
    local ok = pcall(function() modified = tonumber(types.NPC.stats.skills.alchemy(player).modified) or 0 end)
    if not ok then return nil end
    for index, tier in ipairs(INGREDIENT_LORE_TIERS) do
        if modified >= tier.minimumAlchemy then return index end
    end
    return #INGREDIENT_LORE_TIERS
end
local function normalizeEffect(source, tier)
    local effectId = source and source.id
    local magic = effectRecord(effectId)
    if magic == nil then return nil, "invalid magic effect" end
    local magnitude = tier.magnitude
    local duration = tier.duration
    if magic.hasMagnitude == false then magnitude = 1 end
    if magic.hasDuration == false or magic.isAppliedOnce == true then duration = 1 end
    local affectedAttribute = source.affectedAttribute
    local affectedSkill = source.affectedSkill
    return {
        id = effectId, affectedAttribute = affectedAttribute, affectedSkill = affectedSkill,
        magnitudeMin = magnitude, magnitudeMax = magnitude, duration = duration, area = 0,
        range = core.magic.RANGE.Self,
    }, magic
end
local function signatureFor(effect)
    return table.concat({ tostring(effect.id or ""), tostring(effect.affectedAttribute or ""),
        tostring(effect.affectedSkill or ""), tostring(effect.magnitudeMin or 0),
        tostring(effect.duration or 0) }, "|")
end
local function createSpell(effect, magic)
    if type(core.magic.spells.createRecordDraft) ~= "function" or type(world.createRecord) ~= "function" then
        return nil, "dynamic Spell records unavailable"
    end
    local name = "Ingredient Lore: " .. tostring(magic.name or effect.id)
    local okDraft, draft = pcall(core.magic.spells.createRecordDraft, {
        name = name,
        type = core.magic.SPELL_TYPE.Spell,
        cost = 0,
        effects = { effect },
        alwaysSucceedFlag = true,
        isAutocalc = false,
        starterSpellFlag = false,
    })
    if not okDraft then return nil, "Spell draft failed: " .. tostring(draft) end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then return nil, "Spell creation failed: " .. tostring(record) end
    return record
end
local function onIngredientLoreApply(data)
    if type(data) ~= "table" or not validPlayer(data.player) then return failLore(data, "invalid player") end
    local ingredient = ingredientRecord(data.ingredientRecordId)
    if ingredient == nil or ingredient.effects == nil then return failLore(data, "invalid Ingredient record") end
    local sourceIndex = math.floor(tonumber(data.sourceEffectIndex) or -1)
    if sourceIndex < 0 then return failLore(data, "invalid effect index") end
    local source = ingredient.effects[sourceIndex + 1]
    if source == nil then return failLore(data, "effect index out of range") end
    local requestedTierIndex = math.floor(tonumber(data.powerTier) or 0)
    local tierIndex = validatedTierIndex(data.player)
    if tierIndex == nil or INGREDIENT_LORE_TIERS[requestedTierIndex] == nil then
        return failLore(data, "invalid power tier")
    end
    if requestedTierIndex ~= tierIndex then
        log(string.format("power tier corrected requested=%s validated=%s", tostring(requestedTierIndex), tostring(tierIndex)))
    end
    local tier = INGREDIENT_LORE_TIERS[tierIndex]
    local effect, magicOrReason = normalizeEffect(source, tier)
    if effect == nil then return failLore(data, magicOrReason) end
    local magic = magicOrReason
    local signature = signatureFor(effect)
    local recordId = ingredientLoreSpellCache[signature]
    local record = recordId and spellRecord(recordId) or nil
    local cached = record ~= nil
    log("signature=" .. signature .. " cache " .. (cached and "hit" or "miss"))
    if recordId ~= nil and record == nil then
        log("stale cache record=" .. tostring(recordId)); ingredientLoreSpellCache[signature] = nil
    end
    if record == nil then
        local reason
        record, reason = createSpell(effect, magic)
        if record == nil then return failLore(data, reason) end
        recordId = record.id
        ingredientLoreSpellCache[signature] = recordId
        log("created Spell record=" .. tostring(recordId))
    end
    local ok, reason = pcall(function()
        Actor.activeSpells(data.player):add({
            id = recordId,
            effects = { 0 },
            caster = data.player,
            stackable = true,
            ignoreSpellAbsorption = true,
            ignoreReflect = true,
            ignoreResistances = false,
        })
    end)
    if not ok then return failLore(data, "application failed: " .. tostring(reason)) end
    log("application success ingredient=" .. tostring(data.ingredientRecordId))
    sendResult(data.player, LORE_RESULT_EVENT, {
        requestId = data.requestId, success = true, ingredientRecordId = data.ingredientRecordId,
        sourceEffectIndex = sourceIndex, effectId = effect.id,
        effectName = magic.name or effect.id, cached = cached,
        newlyCreated = not cached, generatedSpellRecordId = recordId,
    })
end
local function onRefundIngredient(data)
    local result = { requestId = type(data) == "table" and data.requestId or nil, success = false,
        ingredientRecordId = type(data) == "table" and data.ingredientRecordId or nil }
    if type(data) ~= "table" or not validPlayer(data.player) then result.failureReason = "invalid player"
    elseif data.reason ~= "careful_measure" then result.failureReason = "invalid reason"
    elseif tonumber(data.count) ~= 1 then result.failureReason = "count must equal one"
    else
        local ingredient = ingredientRecord(data.ingredientRecordId)
        if ingredient == nil then result.failureReason = "invalid Ingredient record"
        else
            local ok, created = pcall(world.createObject, data.ingredientRecordId, 1)
            if ok and created ~= nil then
                local moved, moveReason = pcall(function() created:moveInto(types.Actor.inventory(data.player)) end)
                if moved then
                    result.success = true; result.ingredientName = ingredient.name
                    log("refunded ingredient=" .. tostring(data.ingredientRecordId))
                else result.failureReason = "inventory delivery failed: " .. tostring(moveReason) end
            else result.failureReason = "item creation failed" end
        end
    end
    if not result.success then log("Careful Measure delivery rejected: " .. tostring(result.failureReason)) end
    sendResult(type(data) == "table" and data.player or nil, REFUND_RESULT_EVENT, result)
end
local COAT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationCoatResult"
local HIT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationHitResult"
local CONVERT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationConvertResult"
local PREPARATION_MODE_POTION = "potion"
local PREPARATION_MODE_POISON = "poison"
local poisonRecordCache = {}
local poisonRegistry = {}
local coating = nil
local coatingSerial = 0
local drinkBypass = nil
local itemUsageRegistered = false

local function validObject(object)
    if object == nil then return false end
    if type(object.isValid) == "function" then
        local ok, valid = pcall(object.isValid, object)
        return ok and valid
    end
    return true
end

local function potionRecord(recordId)
    if type(recordId) ~= "string" or recordId == "" then return nil end
    local ok, record = pcall(types.Potion.record, recordId)
    return ok and record or nil
end

local function harmfulPotion(recordId)
    local record = potionRecord(recordId)
    if record == nil then return nil, {}, {} end
    local indices, names = {}, {}
    for index, effect in ipairs(record.effects or {}) do
        local magic = effectRecord(effect.id)
        if magic ~= nil and magic.harmful == true then
            indices[#indices + 1] = index - 1
            names[#names + 1] = magic.name or effect.id
        end
    end
    return record, indices, names
end

local function inventoryPotion(player, recordId, exactObject)
    local ok, items = pcall(function() return Actor.inventory(player):getAll(types.Potion) end)
    if not ok then return nil, 0 end
    local count, matched = 0, nil
    for _, item in pairs(items or {}) do
        if validObject(item) and item.recordId == recordId then
            count = count + math.max(0, math.floor(tonumber(item.count) or 1))
            if exactObject == nil or item == exactObject then matched = item end
        end
    end
    return matched, count
end

local function poisonNameFor(sourceRecord)
    local name = tostring(sourceRecord.name or "Mixture")
    if name:sub(1, 7) == "Poison:" then return name end
    return "Poison: " .. name
end

-- Perk tuning for the upper Alchemy tree. Multipliers are applied to the source
-- record's effects when the refined record is generated, so a given source plus
-- perk combination always produces the same record (see refinementSignature).
local CONCENTRATED_DRAUGHT_MAGNITUDE_MULTIPLIER = 1.25
local LINGERING_TOXINS_DURATION_MULTIPLIER = 1.5
local CRUCIBLE_DURATION_MULTIPLIER = 1.25
local MASTER_DISTILLATION_BONUS_CHANCE = 0.25
local MAX_BREW_REFINE_COUNT = 100

local refinedRegistry = {}

local function effectIsHarmful(effectId)
    local magic = effectRecord(effectId)
    return magic ~= nil and magic.harmful == true
end

-- Scale a value by a multiplier, guaranteeing the change is visible in game:
-- a 1.25x multiplier on a magnitude of 1 must still reach 2, not round back to 1.
local function scaledValue(value, multiplier)
    local number = tonumber(value)
    if number == nil or number <= 0 then return value end
    return math.max(number + 1, math.floor(number * multiplier + 0.5))
end

local function normalizedPerkFlags(perks)
    perks = type(perks) == "table" and perks or {}
    return {
        concentratedDraught = perks.concentratedDraught == true,
        lingeringToxins = perks.lingeringToxins == true,
        crucible = perks.crucible == true,
        masterDistillation = perks.masterDistillation == true,
    }
end

-- Describes how a source record's effects are rewritten for a given mode and
-- perk set. Keyed into the record cache so two perk combinations never share a
-- generated record.
local function refinementPlan(mode, perks)
    local isPoison = mode == PREPARATION_MODE_POISON
    local plan = {
        isPoison = isPoison,
        dropHarmful = perks.crucible and not isPoison,
        dropBeneficial = perks.crucible and isPoison,
        boostBeneficialMagnitude = perks.concentratedDraught and not isPoison,
        harmfulDurationMultiplier = 1,
        beneficialDurationMultiplier = 1,
    }

    if isPoison then
        -- Lingering Toxins and the Crucible both lengthen a poison's harmful
        -- effects; investing in both stacks multiplicatively.
        if perks.lingeringToxins then
            plan.harmfulDurationMultiplier = plan.harmfulDurationMultiplier * LINGERING_TOXINS_DURATION_MULTIPLIER
        end
        if perks.crucible then
            plan.harmfulDurationMultiplier = plan.harmfulDurationMultiplier * CRUCIBLE_DURATION_MULTIPLIER
        end
    elseif perks.crucible then
        plan.beneficialDurationMultiplier = CRUCIBLE_DURATION_MULTIPLIER
    end

    plan.changesEffects = plan.dropHarmful or plan.dropBeneficial or plan.boostBeneficialMagnitude
        or plan.harmfulDurationMultiplier ~= 1 or plan.beneficialDurationMultiplier ~= 1
    return plan
end

local function refinementSignature(mode, perks, plan)
    if not plan.changesEffects then return tostring(mode) end
    return table.concat({
        tostring(mode),
        perks.concentratedDraught and "cd" or "-",
        perks.lingeringToxins and "lt" or "-",
        perks.crucible and "pc" or "-",
    }, "|")
end

-- Returns the rewritten effect list, or nil when the source should be used
-- unchanged. Never returns an empty list: a product with no effects would be
-- strictly worse than the mixture it came from.
local function refinedEffects(sourceRecord, plan)
    if not plan.changesEffects then return nil end

    local out = {}
    local changed = false
    for _, effect in ipairs(sourceRecord.effects or {}) do
        local harmful = effectIsHarmful(effect.id)
        if (harmful and plan.dropHarmful) or (not harmful and plan.dropBeneficial) then
            changed = true
        else
            local magic = effectRecord(effect.id)
            local copy = {
                id = effect.id,
                affectedAttribute = effect.affectedAttribute,
                affectedSkill = effect.affectedSkill,
                magnitudeMin = effect.magnitudeMin,
                magnitudeMax = effect.magnitudeMax,
                duration = effect.duration,
                area = effect.area,
                range = effect.range,
            }

            if plan.boostBeneficialMagnitude and not harmful
                    and magic ~= nil and magic.hasMagnitude ~= false then
                copy.magnitudeMin = scaledValue(copy.magnitudeMin, CONCENTRATED_DRAUGHT_MAGNITUDE_MULTIPLIER)
                copy.magnitudeMax = scaledValue(copy.magnitudeMax, CONCENTRATED_DRAUGHT_MAGNITUDE_MULTIPLIER)
                changed = true
            end

            local durationMultiplier = harmful and plan.harmfulDurationMultiplier
                or plan.beneficialDurationMultiplier
            if durationMultiplier ~= 1 and magic ~= nil
                    and magic.hasDuration ~= false and magic.isAppliedOnce ~= true then
                copy.duration = scaledValue(copy.duration, durationMultiplier)
                changed = true
            end

            out[#out + 1] = copy
        end
    end

    if not changed or #out == 0 then return nil end
    return out
end

local function generatedProduct(sourceRecordId, sourceRecord, mode, plan, signature)
    local isPoison = plan.isPoison
    local effects = refinedEffects(sourceRecord, plan)

    -- A potion with nothing to rewrite keeps its own record; only poisons need a
    -- distinct record so they can be recognised as coatings.
    if not isPoison and effects == nil then return sourceRecord, false end

    local cacheKey = sourceRecordId .. "|" .. signature
    local cachedId = poisonRecordCache[cacheKey]
    local cached = potionRecord(cachedId)
    local name = isPoison and poisonNameFor(sourceRecord) or tostring(sourceRecord.name or "Mixture")
    if cached ~= nil then
        if isPoison then
            poisonRegistry[cachedId] = {
                sourcePotionRecordId = sourceRecordId,
                poisonName = cached.name or name,
            }
        end
        refinedRegistry[cachedId] = true
        log("refined record cache hit source=" .. sourceRecordId .. " key=" .. cacheKey .. " generated=" .. cachedId)
        return cached, true
    end
    if cachedId ~= nil then
        poisonRecordCache[cacheKey] = nil
        poisonRegistry[cachedId] = nil
        refinedRegistry[cachedId] = nil
    end

    log("refined record cache miss source=" .. sourceRecordId .. " key=" .. cacheKey)
    local draftTable = { template = sourceRecord, name = name }
    if effects ~= nil then draftTable.effects = effects end
    local okDraft, draft = pcall(types.Potion.createRecordDraft, draftTable)
    if not okDraft or draft == nil then return nil, false, "Potion draft creation failed: " .. tostring(draft) end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then return nil, false, "Potion record creation failed: " .. tostring(record) end

    poisonRecordCache[cacheKey] = record.id
    if isPoison then
        poisonRegistry[record.id] = {
            sourcePotionRecordId = sourceRecordId,
            poisonName = record.name or name,
        }
    end
    refinedRegistry[record.id] = true
    log("created refined record=" .. tostring(record.id) .. " effectsRewritten=" .. tostring(effects ~= nil))
    return record, true
end

local function sendConversionResult(player, result)
    sendResult(player, CONVERT_RESULT_EVENT, result)
end

-- Master Distillation: each dose brewed can leave behind a "distillate" -- a
-- single-effect potion drawn from the ingredients that went into the brew,
-- rather than a copy of the full product. Distillate records are cached by
-- effect signature and marked in refinedRegistry so they cannot be refined
-- or converted again.
local distillateRecordCache = {}

local function distillateEffectPool(consumedIngredients)
    local pool = {}
    if type(consumedIngredients) ~= "table" then return pool end
    for index, recordId in ipairs(consumedIngredients) do
        if index > 32 then break end
        local ingredient = ingredientRecord(recordId)
        if ingredient ~= nil and type(ingredient.effects) == "table" then
            for _, source in ipairs(ingredient.effects) do
                if effectRecord(source and source.id) ~= nil then
                    pool[#pool + 1] = source
                end
            end
        end
    end
    return pool
end

local function distillateRecord(player, source, templateRecord)
    local tierIndex = validatedTierIndex(player)
    local tier = tierIndex ~= nil and INGREDIENT_LORE_TIERS[tierIndex] or nil
    if tier == nil then return nil end
    local effect, magic = normalizeEffect(source, tier)
    if effect == nil then return nil end

    local signature = signatureFor(effect)
    local cachedId = distillateRecordCache[signature]
    local cached = potionRecord(cachedId)
    if cached ~= nil then
        refinedRegistry[cachedId] = true
        return cached
    end
    if cachedId ~= nil then distillateRecordCache[signature] = nil end

    local okDraft, draft = pcall(types.Potion.createRecordDraft, {
        template = templateRecord,
        name = "Distillate: " .. tostring(magic.name or effect.id),
        effects = { effect },
    })
    if not okDraft or draft == nil then
        log("distillate draft failed: " .. tostring(draft))
        return nil
    end
    local okCreate, record = pcall(world.createRecord, draft)
    if not okCreate or record == nil then
        log("distillate record creation failed: " .. tostring(record))
        return nil
    end
    distillateRecordCache[signature] = record.id
    refinedRegistry[record.id] = true
    log("created distillate record=" .. tostring(record.id))
    return record
end

-- Each dose is rolled independently so a large batch does not become
-- all-or-nothing; every successful roll picks its own effect from the pool.
local function grantDistillates(player, effectPool, doses, templateRecord)
    if doses < 1 or #effectPool == 0 then return 0 end
    local inventory = Actor.inventory(player)
    local granted = 0
    for _ = 1, doses do
        if math.random() < MASTER_DISTILLATION_BONUS_CHANCE then
            local source = effectPool[math.random(#effectPool)]
            local record = distillateRecord(player, source, templateRecord)
            if record ~= nil then
                local okCreate, bonus = pcall(world.createObject, record.id, 1)
                if okCreate and bonus ~= nil then
                    local delivered = pcall(function() bonus:moveInto(inventory) end)
                    if delivered then
                        granted = granted + 1
                    else
                        pcall(bonus.remove, bonus)
                    end
                end
            end
        end
    end
    if granted > 0 then log("Master Distillation distillates=" .. granted) end
    return granted
end

-- Handles both halves of the upper Alchemy tree: rewriting freshly brewed
-- mixtures according to the player's perks, and (for Dual Distillation) turning
-- them into weapon poisons.
local function refineBrew(data)
    local player = type(data) == "table" and data.player or nil
    local sourceId = type(data) == "table" and data.sourcePotionRecordId or nil
    local requested = tonumber(type(data) == "table" and data.count or nil)
    local mode = type(data) == "table" and data.mode or PREPARATION_MODE_POISON
    if mode ~= PREPARATION_MODE_POTION then mode = PREPARATION_MODE_POISON end
    local perks = normalizedPerkFlags(type(data) == "table" and data.perks or nil)
    local consumedIngredients = type(data) == "table" and data.consumedIngredients or nil
    local isPoison = mode == PREPARATION_MODE_POISON

    local result = {
        requestId = type(data) == "table" and data.requestId or nil,
        success = false,
        mode = mode,
        sourcePotionRecordId = sourceId,
        requestedCount = requested,
        convertedCount = 0,
        bonusCount = 0,
    }

    local source, harmful = harmfulPotion(sourceId)
    local available = 0
    if validPlayer(player) then local _; _, available = inventoryPotion(player, sourceId) end

    local failure
    if not validPlayer(player) then failure = "invalid player"
    elseif source == nil then failure = "invalid source Potion"
    elseif refinedRegistry[sourceId] ~= nil or poisonRegistry[sourceId] ~= nil then
        failure = "generated products cannot be refined again"
    elseif isPoison and #harmful == 0 then failure = "source Potion has no harmful effects"
    elseif requested == nil or requested ~= math.floor(requested) or requested < 1 then failure = "invalid refine count"
    elseif requested > MAX_BREW_REFINE_COUNT then failure = "refine count exceeds safety limit"
    elseif requested > available then failure = "insufficient source Potion quantity" end
    if failure ~= nil then
        result.failureReason = failure
        log("refine failure source=" .. tostring(sourceId) .. " mode=" .. mode .. " reason=" .. failure)
        return sendConversionResult(player, result)
    end

    local plan = refinementPlan(mode, perks)
    local signature = refinementSignature(mode, perks, plan)
    local generated, isGenerated, generationFailure = generatedProduct(sourceId, source, mode, plan, signature)
    if generated == nil then
        result.failureReason = generationFailure
        log("refine failure source=" .. sourceId .. " reason=" .. tostring(generationFailure))
        return sendConversionResult(player, result)
    end

    result.poisonPotionRecordId = isPoison and generated.id or nil
    result.productRecordId = generated.id
    result.poisonName = generated.name
    result.productName = generated.name
    result.effectsRefined = isGenerated and generated.id ~= sourceId

    if not isGenerated then
        -- Nothing to swap: the brew keeps its own record. Master Distillation
        -- can still leave distillates behind.
        result.convertedCount = requested
        result.success = true
        if perks.masterDistillation then
            result.bonusCount = grantDistillates(player,
                distillateEffectPool(consumedIngredients), requested, source)
        end
        return sendConversionResult(player, result)
    end

    local inventory = Actor.inventory(player)
    for _ = 1, requested do
        local sourceObject = inventoryPotion(player, sourceId)
        if sourceObject == nil then result.failureReason = "source Potion disappeared"; break end
        local okCreate, productObject = pcall(world.createObject, generated.id, 1)
        if not okCreate or productObject == nil then result.failureReason = "product object creation failed"; break end
        local delivered, deliveryFailure = pcall(function() productObject:moveInto(inventory) end)
        if not delivered then
            pcall(productObject.remove, productObject)
            result.failureReason = "generated product delivery failed: " .. tostring(deliveryFailure)
            break
        end
        local removed, removalFailure = pcall(sourceObject.remove, sourceObject, 1)
        if not removed then
            pcall(productObject.remove, productObject, 1)
            result.failureReason = "source Potion removal failed: " .. tostring(removalFailure)
            break
        end
        result.convertedCount = result.convertedCount + 1
        log("source Potion removed=" .. sourceId .. "; generated product delivered=" .. generated.id)
    end

    result.success = result.convertedCount > 0
    if result.convertedCount < requested then
        log("partial refine source=" .. sourceId .. " converted=" .. result.convertedCount .. "/" .. requested)
    end
    if result.success and perks.masterDistillation then
        result.bonusCount = grantDistillates(player,
            distillateEffectPool(consumedIngredients), result.convertedCount, source)
    end
    sendConversionResult(player, result)
end

local function watcherState(target)
    if type(target.sendEvent) ~= "function" then return end
    if coating ~= nil and coating.charges == 1 then
        target:sendEvent("SkillPerkSystem_BasePack_DualDistillationState", {
            active = true, playerId = coating.playerId, coatingId = coating.coatingId,
            weapon = coating.weapon, weaponRecordId = coating.weaponRecordId,
        })
    else
        target:sendEvent("SkillPerkSystem_BasePack_DualDistillationState", { active = false })
    end
end
registerTargetWatcherProvider("dual_distillation", {
    isActive = function() return coating ~= nil and coating.charges == 1 end,
    sendState = watcherState,
})

local function clearCoating(reason)
    if coating == nil then return end
    log("coating cleared reason=" .. tostring(reason))
    coating = nil
    onTargetWatcherProviderStateChanged("dual_distillation", false)
end

local function equippedRight(player)
    local ok, item = pcall(Actor.getEquipment, player, Actor.EQUIPMENT_SLOT.CarriedRight)
    return ok and item or nil
end

local function weaponName(weapon)
    local ok, record = pcall(types.Weapon.record, weapon)
    return ok and record and (record.name or weapon.recordId) or weapon.recordId
end

local function onCoat(data)
    local player = type(data) == "table" and data.player or nil
    local potion = type(data) == "table" and data.potion or nil
    local potionId = type(data) == "table" and data.potionRecordId or nil
    local weapon = type(data) == "table" and data.weapon or nil
    local result = { requestId = type(data) == "table" and data.requestId or nil, success = false }
    local record, harmful, harmfulNames = harmfulPotion(potionId)
    local exactPotion = validPlayer(player) and inventoryPotion(player, potionId, potion) or nil
    local failure
    if not validPlayer(player) then failure = "invalid player"
    elseif not validObject(weapon) or not types.Weapon.objectIsInstance(weapon) then failure = "invalid weapon"
    elseif equippedRight(player) ~= weapon then failure = "weapon is not equipped"
    elseif poisonRegistry[potionId] == nil then failure = "item is not a registered poison"
    elseif not validObject(potion) or exactPotion ~= potion then failure = "exact poison item is unavailable"
    elseif record == nil or #harmful == 0 then failure = "poison has no harmful effects"
    elseif coating ~= nil and data.replaceExisting ~= true then failure = "replacement was not approved" end
    if failure ~= nil then
        result.failureReason = failure
        log("coating request rejected=" .. failure)
        return sendResult(player, COAT_RESULT_EVENT, result)
    end
    local removed, removalFailure = pcall(potion.remove, potion, 1)
    if not removed then
        result.failureReason = "poison removal failed: " .. tostring(removalFailure)
        return sendResult(player, COAT_RESULT_EVENT, result)
    end
    local replaced = coating ~= nil
    coatingSerial = coatingSerial + 1
    local coatingId = tostring(player.id) .. ":dual:" .. tostring(coatingSerial)
    coating = {
        coatingId = coatingId, player = player, playerId = player.id,
        weapon = weapon, weaponRecordId = weapon.recordId, weaponName = weaponName(weapon),
        potionRecordId = potionId, potionName = record.name or potionId,
        harmfulEffectIndices = harmful, charges = 1, triggerInProgress = false,
    }
    log((replaced and "coating replaced=" or "coating created=") .. coatingId)
    onTargetWatcherProviderStateChanged("dual_distillation", true)
    sendResult(player, COAT_RESULT_EVENT, {
        requestId = result.requestId, success = true, coatingId = coatingId, weapon = weapon,
        weaponRecordId = weapon.recordId, weaponName = coating.weaponName,
        potionRecordId = potionId, potionName = coating.potionName, harmfulEffectNames = harmfulNames,
    })
end

local function onRestore(data)
    local player = type(data) == "table" and data.player or nil
    local saved = type(data) == "table" and data.coating or nil
    local weapon = type(data) == "table" and data.weapon or nil
    local record, harmful = harmfulPotion(saved and saved.potionRecordId)
    if not validPlayer(player) or type(saved) ~= "table" or not validObject(weapon)
            or not types.Weapon.objectIsInstance(weapon) or equippedRight(player) ~= weapon
            or weapon.recordId ~= saved.weaponRecordId or record == nil or #harmful == 0 then
        return sendResult(player, COAT_RESULT_EVENT, { success = false, restore = true,
            failureReason = "saved coating could not be restored" })
    end
    coating = {
        coatingId = saved.coatingId, player = player, playerId = player.id,
        weapon = weapon, weaponRecordId = weapon.recordId,
        weaponName = saved.weaponName or weaponName(weapon), potionRecordId = saved.potionRecordId,
        potionName = saved.potionName or record.name, harmfulEffectIndices = harmful,
        charges = 1, triggerInProgress = false,
    }
    log("coating restored=" .. tostring(coating.coatingId))
    onTargetWatcherProviderStateChanged("dual_distillation", true)
    sendResult(player, COAT_RESULT_EVENT, {
        success = true, restore = true, coatingId = coating.coatingId, weapon = weapon,
        weaponRecordId = weapon.recordId, weaponName = coating.weaponName,
        potionRecordId = coating.potionRecordId, potionName = coating.potionName,
    })
end

local function onClear(data)
    if type(data) == "table" and validPlayer(data.player)
            and (data.coatingId == nil or coating == nil or coating.coatingId == data.coatingId) then
        clearCoating(data.reason or "player request")
    end
end

local function onHit(data)
    local current = coating
    local reason
    if current == nil then reason = "no active coating"
    elseif type(data) ~= "table" or data.coatingId ~= current.coatingId then reason = "coating mismatch"
    elseif data.attacker ~= current.player then reason = "attacker mismatch"
    elseif data.weapon ~= current.weapon then reason = "weapon mismatch"
    elseif not validObject(data.target) or not Actor.objectIsInstance(data.target) or Actor.isDead(data.target) then reason = "invalid target"
    elseif current.charges ~= 1 or current.triggerInProgress then reason = "charge unavailable" end
    if reason ~= nil then log("poison hit rejected=" .. reason); return end
    local record, harmful = harmfulPotion(current.potionRecordId)
    if record == nil or #harmful == 0 then log("poison hit rejected=invalid Potion"); return end
    current.triggerInProgress = true
    local ok, failure = pcall(function()
        Actor.activeSpells(data.target):add({
            id = current.potionRecordId, effects = harmful, caster = current.player,
            stackable = true, name = "Weapon Poison: " .. current.potionName,
            ignoreSpellAbsorption = true, ignoreReflect = true, ignoreResistances = false,
        })
    end)
    if not ok then current.triggerInProgress = false; log("poison application failed=" .. tostring(failure)); return end
    current.charges = 0
    local player, coatingId, name = current.player, current.coatingId, current.potionName
    local targetName = data.target.recordId
    pcall(function() targetName = Actor.record(data.target).name end)
    coating = nil
    onTargetWatcherProviderStateChanged("dual_distillation", false)
    log("poison application success; coating charge consumed")
    sendResult(player, HIT_RESULT_EVENT, { success = true, coatingId = coatingId,
        potionName = name, targetName = targetName })
end

local function drinkPoison(data)
    local player = type(data) == "table" and data.player or nil
    local potion = type(data) == "table" and data.potion or nil
    local potionId = potion and potion.recordId or nil
    local exact = validPlayer(player) and inventoryPotion(player, potionId, potion) or nil
    if not validPlayer(player) or poisonRegistry[potionId] == nil or not validObject(potion) or exact ~= potion then
        log("drink poison validation failure")
        return
    end
    drinkBypass = { player = player, potion = potion, expiresAt = core.getRealTime() + 1.0 }
    log("drink bypass activated=" .. potionId)
    core.sendGlobalEvent("UseItem", { object = potion, actor = player })
end

local function registerItemUsageHandlers()
    if itemUsageRegistered then return end
    local itemUsage = require("openmw.interfaces").ItemUsage
    if itemUsage == nil or type(itemUsage.addHandlerForType) ~= "function" then return end
    itemUsage.addHandlerForType(types.Apparatus, function(item, actor)
        if validObject(item) and actor ~= nil and type(actor.sendEvent) == "function" then
            actor:sendEvent("SkillPerkSystem_RecordAlchemyApparatus", { item = item, recordId = item.recordId })
            log("apparatus captured=" .. tostring(item.recordId))
        end
    end)
    itemUsage.addHandlerForType(types.Potion, function(potion, actor)
        if poisonRegistry[potion and potion.recordId] == nil or not validPlayer(actor) then return end
        if drinkBypass ~= nil and core.getRealTime() > drinkBypass.expiresAt then drinkBypass = nil end
        if drinkBypass ~= nil and drinkBypass.player == actor and drinkBypass.potion == potion then
            drinkBypass = nil
            log("drink bypass consumed=" .. tostring(potion.recordId))
            return
        end
        if validObject(potion) and actor ~= nil and type(actor.sendEvent) == "function" then
            actor:sendEvent("SkillPerkSystem_BasePack_DualDistillationPoisonUsed", {
                potion = potion, potionRecordId = potion.recordId,
            })
            log("registered poison Potion intercepted=" .. tostring(potion.recordId))
            return false
        end
    end)
    itemUsageRegistered = true
    log("registered Alchemy ItemUsage handlers")
end
registerItemUsageHandlers()
subsystems.alchemy = {
    eventHandlers = {
        SkillPerkSystem_BasePack_IngredientLoreApply = onIngredientLoreApply,
        SkillPerkSystem_BasePack_AlchemyRefundIngredient = onRefundIngredient,
        SkillPerkSystem_BasePack_DualDistillationCoatRequest = onCoat,
        SkillPerkSystem_BasePack_DualDistillationRestoreCoating = onRestore,
        SkillPerkSystem_BasePack_DualDistillationClearCoating = onClear,
        SkillPerkSystem_BasePack_DualDistillationHitRequest = onHit,
        SkillPerkSystem_BasePack_DualDistillationConvertPoisons = refineBrew,
        SkillPerkSystem_BasePack_AlchemyRefineBrew = refineBrew,
        SkillPerkSystem_BasePack_DualDistillationDrinkPoison = drinkPoison,
    },
    engineHandlers = {
        onSave = function()
            return {
                ingredientLoreSpellCache = ingredientLoreSpellCache,
                poisonRecordCache = poisonRecordCache,
                poisonRegistry = poisonRegistry,
                refinedRegistry = refinedRegistry,
                distillateRecordCache = distillateRecordCache,
            }
        end,
        onLoad = function(data)
            clearCoating("global load")
            ingredientLoreSpellCache = {}
            poisonRecordCache = {}
            poisonRegistry = {}
            refinedRegistry = {}
            distillateRecordCache = {}
            drinkBypass = nil
            local saved = type(data) == "table" and data.ingredientLoreSpellCache or nil
            if type(saved) == "table" then
                for signature, recordId in pairs(saved) do
                    if type(signature) == "string" and type(recordId) == "string" then
                        ingredientLoreSpellCache[signature] = recordId
                    end
                end
            end
            local savedCache = type(data) == "table" and data.poisonRecordCache or nil
            if type(savedCache) == "table" then
                for sourceId, generatedId in pairs(savedCache) do
                    if type(sourceId) == "string" and type(generatedId) == "string" then
                        poisonRecordCache[sourceId] = generatedId
                    end
                end
            end
            local savedDistillates = type(data) == "table" and data.distillateRecordCache or nil
            if type(savedDistillates) == "table" then
                for signature, recordId in pairs(savedDistillates) do
                    if type(signature) == "string" and type(recordId) == "string" then
                        distillateRecordCache[signature] = recordId
                    end
                end
            end
            local savedRefined = type(data) == "table" and data.refinedRegistry or nil
            if type(savedRefined) == "table" then
                for generatedId, flag in pairs(savedRefined) do
                    if type(generatedId) == "string" and flag == true then
                        refinedRegistry[generatedId] = true
                    end
                end
            end
            local savedRegistry = type(data) == "table" and data.poisonRegistry or nil
            if type(savedRegistry) == "table" then
                for generatedId, entry in pairs(savedRegistry) do
                    if type(generatedId) == "string" and type(entry) == "table"
                            and type(entry.sourcePotionRecordId) == "string" then
                        poisonRegistry[generatedId] = {
                            sourcePotionRecordId = entry.sourcePotionRecordId,
                            poisonName = type(entry.poisonName) == "string" and entry.poisonName or generatedId,
                        }
                    end
                end
            end
        end,
    },
}
end
__basepack_initAlchemyGlobal()

-- 14. combined engineHandlers
local engineOrder = {
    "alchemy",
    "security_global",
    "shared_target_watcher",
    "handtohand",
    "treasure_sense",
    "lucky_find",
    "unseen_hand",
    "heavyarmor",
    "shortblade",
    "sneakcrit",
    "conjuration",
    "destruction",
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
