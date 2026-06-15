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
        overrepairFailure(player, "target_not_at_normal_max", "That item is no longer eligible.", recordId)
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

local function forwardTumblerSenseFailure(data)
    if type(data) ~= "table" then
        return
    end

    local player = data.player
    if player == nil or type(player.sendEvent) ~= "function" then
        return
    end

    local probe = normalizeFailureProbe(data)
    player:sendEvent(TUMBLER_SENSE_FAILURE_EVENT, {
        source = TUMBLER_SENSE_FAILURE_SOURCE,
        probe = probe,
    })

    print(string.format(
        "[SkillPerkSystem_BasePack][TumblerSenseBridge] forwarded failure source=%s mode=%s",
        TUMBLER_SENSE_FAILURE_SOURCE,
        probe and "probe" or "lockpick"
    ))
end

if type(steadyHandsEffect) == "table" and type(steadyHandsEffect.registerRuntimeHooks) == "function" then
    steadyHandsEffect.registerRuntimeHooks()
end

return {
    eventHandlers = {
        [MODIFY_SECURITY_TOOL_CONDITION_EVENT] = writeToolCondition,
        [MODIFY_REPAIR_TOOL_CONDITION_EVENT] = modifyRepairToolCondition,
        [APPRENTICE_HAMMER_OVERREPAIR_REQUEST_EVENT] = applyApprenticeHammerOverrepair,
        [WEAPON_TEMPER_REQUEST_EVENT] = applyWeaponTemper,
        [ARMOR_REFIT_REQUEST_EVENT] = applyArmorRefit,
        [MASTERWORK_REQUEST_EVENT] = applyMasterwork,
        [DRAIN_LOCKPICK_EVENT] = forwardTumblerSenseFailure,
    },
}
