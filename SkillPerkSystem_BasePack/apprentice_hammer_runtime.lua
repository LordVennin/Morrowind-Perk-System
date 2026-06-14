local async = require("openmw.async")
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")

local MENU_NAME = "SkillPerkSystem_BasePack_ApprenticeHammerMenu"
local OVERREPAIR_MENU_NAME = "SkillPerkSystem_BasePack_OverRepairMenu"
local TEMPER_MENU_NAME = "SkillPerkSystem_BasePack_WeaponTemperMenu"
local OVERREPAIR_USES_COST = 5
local DEFAULT_MULTIPLIER = 1.10
local TEMPER_STORAGE_SECTION_ID = "SkillPerkSystem_BasePack_WeaponTemper"
local TEMPERED_WEAPONS_KEY = "temperedWeapons"
local TEMPER_REQUEST_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Request"
local TEMPER_RESULT_EVENT = "SkillPerkSystem_BasePack_WeaponTemper_Result"
local FIELD_MENDER_PERK_ID = "armorer_field_mender"
local APPRENTICE_PERK_ID = "armorer_apprentice_hammer"
local LOG_TAG = "[SkillPerkSystem_BasePack][ApprenticeHammer][RepairMode]"
local OVERREPAIR_REQUEST_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairRequest"
local OVERREPAIR_RESULT_EVENT = "SkillPerkSystem_BasePack_ApprenticeHammer_OverrepairResult"
local CAREFUL_REPAIRS_SUPPRESS_EVENT = "SkillPerkSystem_BasePack_CarefulRepairs_SuppressRepairToolDrops"

local rootMenuElement = nil
local subMenuElement = nil
local customMenuOpen = false
local suppressNextRepairIntercept = false
local pendingUseRepairTool = nil
local pendingUseRepairFrames = 0
local lastRepairTool = nil
local lastRepairToolRecordId = nil

local temperStorage = storage.globalSection(TEMPER_STORAGE_SECTION_ID)
local temperedWeaponCache = {}

local function logDebug(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function isPerkOwnedAndEnabled(perkId)
    local playerApi = interfaces.SkillPerkSystemPlayer
    if playerApi == nil then
        logDebug("interfaces.SkillPerkSystemPlayer unavailable")
        return false
    end
    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(perkId) then
        return false
    end
    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(perkId) then
        return false
    end
    return true
end

local function apprenticeHammerEnabled()
    return isPerkOwnedAndEnabled(APPRENTICE_PERK_ID)
end

local function weaponTemperEnabled()
    return isPerkOwnedAndEnabled(FIELD_MENDER_PERK_ID)
end

local function anyRepairToolActionEnabled()
    return apprenticeHammerEnabled() or weaponTemperEnabled()
end

local function showMessage(text)
    ui.showMessage(text, { showInDialogue = false })
end

local function closeRootMenu()
    if rootMenuElement ~= nil then
        rootMenuElement:destroy()
        rootMenuElement = nil
    end
end

local function closeSubMenu()
    if subMenuElement ~= nil then
        subMenuElement:destroy()
        subMenuElement = nil
    end
end

local function closeAllMenus()
    closeSubMenu()
    closeRootMenu()
    customMenuOpen = false
end

local function sequenceToArray(seq)
    if seq == nil then
        return {}
    end

    local out = {}
    local okLen, len = pcall(function()
        return #seq
    end)

    if okLen and type(len) == "number" then
        for i = 1, len do
            out[#out + 1] = seq[i]
        end
        return out
    end

    local okPairs, err = pcall(function()
        for _, item in pairs(seq) do
            out[#out + 1] = item
        end
    end)

    if not okPairs then
        logDebug("sequenceToArray failed: " .. tostring(err))
    end

    return out
end

local function getActorObject()
    return pself.object or pself
end

local function getPlayerInventory()
    local okInv, inventory = pcall(types.Actor.inventory, getActorObject())
    if not okInv or inventory == nil then
        logDebug("types.Actor.inventory failed")
        return nil
    end
    return inventory
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

local function getMaxCondition(item)
    local record = getEquipmentRecord(item)
    return tonumber(safeGetRecordField(record, "health") or safeGetRecordField(record, "maxCondition"))
end

local function getItemCondition(item)
    if item == nil then return nil end
    local itemData = types.Item.itemData(item)
    if itemData ~= nil and type(itemData.condition) == "number" then
        return itemData.condition, itemData
    end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) == "number" then
        return maxCondition, itemData
    end

    return nil, itemData
end

local function getDisplayName(item)
    if item == nil then return "Unknown Item" end

    local record = getEquipmentRecord(item)
    local recordName = safeGetRecordField(record, "name")
    if type(recordName) == "string" and recordName ~= "" then
        return recordName
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then return "Unknown Item" end
    return recordId
end

local function getAllInventoryItems()
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll()
    end)
    if not okAll or items == nil then
        logDebug("inventory:getAll() failed")
        return {}
    end
    return sequenceToArray(items)
end

local function getAllInventoryItemsOfType(typeObject)
    local inventory = getPlayerInventory()
    if inventory == nil then
        return {}
    end

    local okAll, items = pcall(function()
        return inventory:getAll(typeObject)
    end)
    if okAll and items ~= nil then
        return sequenceToArray(items)
    end

    local fallback = {}
    for _, item in ipairs(getAllInventoryItems()) do
        if item ~= nil and typeObject.objectIsInstance(item) then
            fallback[#fallback + 1] = item
        end
    end
    return fallback
end

local function isRepairableEquipmentItem(item)
    return item ~= nil and (types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item))
end

local function getItemKey(item)
    if item == nil then return nil end

    local okId, objectId = pcall(function()
        return item.id
    end)
    if okId and objectId ~= nil then
        return objectId
    end

    return item
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

local function addUniqueItem(out, seen, item)
    local key = getItemKey(item)
    if item == nil or key == nil or seen[key] then
        return false
    end
    seen[key] = true
    out[#out + 1] = item
    return true
end

local function getEquippedRepairableEquipmentItems(seen)
    local out = {}
    local weaponCount = 0
    local armorCount = 0

    if type(types.Actor.getEquipment) ~= "function" then
        return out, weaponCount, armorCount
    end

    for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
        local okItem, item = pcall(types.Actor.getEquipment, getActorObject(), slot)
        if okItem and item ~= nil then
            local isWeapon = types.Weapon.objectIsInstance(item)
            local isArmor = types.Armor.objectIsInstance(item)
            if isWeapon or isArmor then
                if isWeapon then weaponCount = weaponCount + 1 end
                if isArmor then armorCount = armorCount + 1 end
                addUniqueItem(out, seen, item)
            end
        end
    end

    return out, weaponCount, armorCount
end

local function getRepairableEquipmentItems()
    local out = {}
    local seen = {}
    local weaponItems = getAllInventoryItemsOfType(types.Weapon)
    local armorItems = getAllInventoryItemsOfType(types.Armor)

    logDebug("inventory typed weapons=" .. tostring(#weaponItems))
    for _, item in ipairs(weaponItems) do
        addUniqueItem(out, seen, item)
    end

    logDebug("inventory typed armor=" .. tostring(#armorItems))
    for _, item in ipairs(armorItems) do
        addUniqueItem(out, seen, item)
    end

    local equippedItems, equippedWeapons, equippedArmor = getEquippedRepairableEquipmentItems(seen)
    logDebug("equipment weapons=" .. tostring(equippedWeapons) .. " armor=" .. tostring(equippedArmor) .. " uniqueAdded=" .. tostring(#equippedItems))
    for _, item in ipairs(equippedItems) do
        out[#out + 1] = item
    end

    return out, #weaponItems, #armorItems, equippedWeapons, equippedArmor
end

local function getTemperedWeaponRecords()
    local records = temperStorage:get(TEMPERED_WEAPONS_KEY)
    if type(records) ~= "table" then
        return {}
    end
    return records
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

local function getTemperedWeaponInfo(recordId, displayName)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local cached = temperedWeaponCache[recordId]
    if type(cached) == "table" then
        return cached
    end

    local records = getTemperedWeaponRecords()
    local entry = records[recordId]
    if type(entry) == "table" then
        temperedWeaponCache[recordId] = entry
        return entry
    end

    local byName = records.byGeneratedName
    if type(byName) == "table" and type(displayName) == "string" then
        entry = byName[displayName]
        if type(entry) == "table" then
            temperedWeaponCache[recordId] = entry
            return entry
        end
    end

    local inferredMode = inferTemperModeFromName(displayName)
    if inferredMode ~= nil then
        return { mode = inferredMode, inferred = true }
    end

    return nil
end

local function formatTemperMode(mode)
    if mode == "honed" then
        return "Honed"
    elseif mode == "hardened" then
        return "Hardened"
    end
    return "Tempered"
end

local function collectWeaponTemperCandidates()
    local out = {}
    local seen = {}
    for _, item in ipairs(getAllInventoryItemsOfType(types.Weapon)) do
        if item ~= nil and addUniqueItem(out, seen, item) then
            -- Added by addUniqueItem.
        end
    end

    table.sort(out, function(a, b)
        return string.lower(getDisplayName(a)) < string.lower(getDisplayName(b))
    end)
    return out
end

local function isAtNormalMaxCondition(currentCondition, maxCondition)
    if type(currentCondition) ~= "number" or type(maxCondition) ~= "number" then
        return false
    end

    local currentRounded = math.floor(currentCondition + 0.5)
    local maxRounded = math.floor(maxCondition + 0.5)
    return currentRounded == maxRounded
end

local function getOverrepairEligibility(item)
    if not isRepairableEquipmentItem(item) then
        return false, "not_weapon_or_armor"
    end

    local currentCondition, itemData = getItemCondition(item)
    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        return false, "missing_max_condition", currentCondition, maxCondition, itemData
    end
    if type(currentCondition) ~= "number" then
        return false, "missing_current_condition", currentCondition, maxCondition, itemData
    end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then
        if currentCondition > maxCondition then
            return false, "already_overrepaired", currentCondition, maxCondition, itemData
        end
        return false, "not_at_normal_max", currentCondition, maxCondition, itemData
    end

    return true, "eligible", currentCondition, maxCondition, itemData
end

local function findRepairToolByRecordId(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    local inventory = getPlayerInventory()
    if inventory ~= nil and type(inventory.find) == "function" then
        local okFind, item = pcall(function()
            return inventory:find(recordId)
        end)
        if okFind and item ~= nil then
            return item
        end
    end

    for _, item in ipairs(getAllInventoryItemsOfType(types.Repair)) do
        if item ~= nil and item.recordId == recordId then
            return item
        end
    end
    return nil
end

local function getActiveRepairTool()
    if lastRepairTool ~= nil then
        return lastRepairTool
    end

    if lastRepairToolRecordId ~= nil then
        local cachedItem = findRepairToolByRecordId(lastRepairToolRecordId)
        if cachedItem ~= nil then
            return cachedItem
        end
    end

    local repairTools = getAllInventoryItemsOfType(types.Repair)
    if #repairTools > 0 then
        return repairTools[1]
    end

    if type(types.Actor.getEquipment) == "function" then
        for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
            local okItem, item = pcall(types.Actor.getEquipment, getActorObject(), slot)
            if okItem and item ~= nil and types.Repair.objectIsInstance(item) then
                return item
            end
        end
    end
    return nil
end

local function hasRepairToolUses(item, usesRequired)
    local currentCondition, itemData = getItemCondition(item)
    return type(currentCondition) == "number" and currentCondition >= usesRequired and itemData ~= nil
end

local function setInterfaceMode()
    local uiApi = interfaces.UI
    if uiApi == nil or type(uiApi.setMode) ~= "function" then
        logDebug("interfaces.UI.setMode unavailable for Interface")
        return
    end
    uiApi.setMode("Interface", { windows = { "Map", "Stats", "Magic", "Inventory" } })
end

local function createButton(label, onSelect, width)
    local textLayout = {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.Center,
            relativeSize = util.vector2(1, 1),
        },
    }

    local innerButton = {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxButton,
        props = { size = util.vector2(width or 560, 28) },
        content = ui.content({ textLayout }),
    }

    return {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = { autoSize = true },
        content = ui.content({ innerButton }),
        events = {
            mousePress = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    textLayout.template = interfaces.MWUI.templates.textHeader
                    if rootMenuElement ~= nil then rootMenuElement:update() end
                    if subMenuElement ~= nil then subMenuElement:update() end
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then onSelect() end
            end),
            focusGain = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textHeader
                if rootMenuElement ~= nil then rootMenuElement:update() end
                if subMenuElement ~= nil then subMenuElement:update() end
            end),
            focusLoss = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textNormal
                if rootMenuElement ~= nil then rootMenuElement:update() end
                if subMenuElement ~= nil then subMenuElement:update() end
            end),
        },
    }
end

local function requestBaseRepairUi(repairToolItem)
    repairToolItem = repairToolItem or getActiveRepairTool()
    if repairToolItem == nil then
        showMessage("No repair tool found.")
        return
    end

    lastRepairTool = repairToolItem
    lastRepairToolRecordId = repairToolItem.recordId
    logDebug("requestBaseRepairUi using " .. tostring(lastRepairToolRecordId))
    suppressNextRepairIntercept = true
    pendingUseRepairTool = repairToolItem
    pendingUseRepairFrames = 1
    closeAllMenus()
    setInterfaceMode()
end

local function collectOverrepairCandidates()
    local out = {}
    local inventory = getPlayerInventory()
    if inventory ~= nil then
        local okResolved, resolved = pcall(function() return inventory:isResolved() end)
        if okResolved then
            logDebug("inventory resolved=" .. tostring(resolved))
        end
    end

    local allItems = getRepairableEquipmentItems()
    local weaponSeen = 0
    local armorSeen = 0

    for _, item in ipairs(allItems) do
        local isWeapon = item ~= nil and types.Weapon.objectIsInstance(item)
        local isArmor = item ~= nil and types.Armor.objectIsInstance(item)

        if isWeapon then weaponSeen = weaponSeen + 1 end
        if isArmor then armorSeen = armorSeen + 1 end

        local eligible, reason, currentCondition, maxCondition, itemData = getOverrepairEligibility(item)
        if eligible then
            out[#out + 1] = {
                item = item,
                recordId = item.recordId,
                name = getDisplayName(item),
                currentCondition = currentCondition,
                maxCondition = maxCondition,
                count = getObjectCount(item),
            }
        else
            logDebug(string.format(
                "overrepair reject id=%s current=%s max=%s itemData=%s reason=%s",
                tostring(item and item.recordId),
                tostring(currentCondition),
                tostring(maxCondition),
                tostring(itemData ~= nil),
                tostring(reason)
            ))
        end
    end

    table.sort(out, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
    logDebug("collectOverrepairCandidates scanned weapons=" .. tostring(weaponSeen) .. " armor=" .. tostring(armorSeen) .. " eligible=" .. tostring(#out))
    return out
end

local function computeOverrepairTargetCondition(item, multiplier)
    local currentCondition = getItemCondition(item)
    if type(currentCondition) ~= "number" then return nil end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then return nil end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then return nil end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then return nil end

    return targetCondition
end

local function findEligibleItemByRecordId(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

    for _, item in ipairs(getRepairableEquipmentItems()) do
        if item ~= nil and item.recordId == recordId then
            local eligible = getOverrepairEligibility(item)
            if eligible then
                return item
            end
        end
    end

    return nil
end

local function openOverRepairMenu(repairToolItem)
    closeSubMenu()

    local candidates = collectOverrepairCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Over Repair", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Select a fully repaired weapon or armor piece.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "No eligible items at full durability.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, entry in ipairs(candidates) do
            local countLabel = ""
            if type(entry.count) == "number" and entry.count > 1 then
                countLabel = " x" .. tostring(entry.count)
            end
            local label = string.format(
                "%s%s (%d/%d)",
                entry.name,
                countLabel,
                math.floor(entry.currentCondition + 0.5),
                math.floor(entry.maxCondition + 0.5)
            )
            table.insert(contentLayouts, createButton(label, function()
                closeAllMenus()
                local currentRepairTool = getActiveRepairTool()
                if currentRepairTool == nil then
                    logDebug("overrepair failed: no repair tool")
                    showMessage("No repair tool found.")
                    return
                end

                local targetItem = nil
                local entryItemEligible = getOverrepairEligibility(entry.item)
                if entryItemEligible then
                    targetItem = entry.item
                else
                    targetItem = findEligibleItemByRecordId(entry.recordId)
                end
                if targetItem == nil then
                    logDebug("overrepair failed: target item missing for " .. tostring(entry.recordId))
                    showMessage("That item is no longer eligible.")
                    return
                end

                if not hasRepairToolUses(currentRepairTool, OVERREPAIR_USES_COST) then
                    logDebug("overrepair failed: not enough tool uses")
                    showMessage("Not enough hammer uses remaining (need 5).")
                    return
                end

                local targetCondition = computeOverrepairTargetCondition(targetItem, DEFAULT_MULTIPLIER)
                if targetCondition == nil then
                    logDebug("overrepair failed: target no longer eligible for " .. tostring(entry.recordId))
                    showMessage("That item is no longer eligible.")
                    return
                end

                local playerObject = getActorObject()
                if playerObject ~= nil and type(playerObject.sendEvent) == "function" then
                    playerObject:sendEvent(CAREFUL_REPAIRS_SUPPRESS_EVENT, {
                        amount = OVERREPAIR_USES_COST,
                        source = "apprentice_hammer_overrepair",
                    })
                end
                core.sendGlobalEvent(OVERREPAIR_REQUEST_EVENT, {
                    player = playerObject,
                    repairTool = currentRepairTool,
                    targetItem = targetItem,
                    targetName = entry.name,
                    usesCost = OVERREPAIR_USES_COST,
                    multiplier = DEFAULT_MULTIPLIER,
                    expectedTargetCondition = targetCondition,
                })
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = OVERREPAIR_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function sendTemperRequest(item, mode)
    if item == nil or type(mode) ~= "string" then
        showMessage("That weapon is no longer eligible.")
        return
    end

    closeAllMenus()
    core.sendGlobalEvent(TEMPER_REQUEST_EVENT, {
        player = getActorObject(),
        targetItem = item,
        mode = mode,
        targetName = getDisplayName(item),
    })
end

local openTemperWeaponMenu

local function openTemperModeMenu(entry)
    closeSubMenu()

    local recordId = entry.item ~= nil and entry.item.recordId or entry.recordId
    local temperInfo = getTemperedWeaponInfo(recordId, entry.name)
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = entry.name, textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if temperInfo ~= nil then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "This weapon is " .. formatTemperMode(temperInfo.mode) .. ".", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Restore Original", function()
            sendTemperRequest(entry.item, "restore")
        end, 620))
    else
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose one temper. Unenchanted tempered weapons cannot be enchanted afterward.", textAlignH = ui.ALIGNMENT.Center },
        })
        table.insert(contentLayouts, createButton("Hone: +damage, -weight, -durability", function()
            sendTemperRequest(entry.item, "honed")
        end, 620))
        table.insert(contentLayouts, createButton("Harden: +durability, +weight, -damage", function()
            sendTemperRequest(entry.item, "hardened")
        end, 620))
    end

    table.insert(contentLayouts, createButton("Back", function()
        openTemperWeaponMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = TEMPER_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

openTemperWeaponMenu = function()
    closeSubMenu()

    local candidates = collectWeaponTemperCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Hone or Harden", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Select a weapon to temper or restore.", textAlignH = ui.ALIGNMENT.Center },
        },
    }

    if #candidates == 0 then
        table.insert(contentLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "No weapons found in your inventory.", textAlignH = ui.ALIGNMENT.Center },
        })
    else
        for _, item in ipairs(candidates) do
            local recordId = item.recordId
            local currentCondition = getItemCondition(item)
            local maxCondition = getMaxCondition(item)
            local modeLabel = ""
            local temperInfo = getTemperedWeaponInfo(recordId, getDisplayName(item))
            if temperInfo ~= nil then
                modeLabel = " [" .. formatTemperMode(temperInfo.mode) .. "]"
            end
            local conditionLabel = ""
            if type(currentCondition) == "number" and type(maxCondition) == "number" then
                conditionLabel = string.format(" (%d/%d)", math.floor(currentCondition + 0.5), math.floor(maxCondition + 0.5))
            end
            local count = getObjectCount(item)
            local countLabel = count > 1 and (" x" .. tostring(count)) or ""
            local entry = {
                item = item,
                recordId = recordId,
                name = getDisplayName(item),
            }
            table.insert(contentLayouts, createButton(entry.name .. countLabel .. modeLabel .. conditionLabel, function()
                openTemperModeMenu(entry)
            end, 620))
        end
    end

    table.insert(contentLayouts, createButton("Back", function()
        closeSubMenu()
    end, 620))

    subMenuElement = ui.create({
        layer = "Windows",
        name = TEMPER_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function openRepairMenu()
    closeAllMenus()
    customMenuOpen = true

    local repairToolItem = getActiveRepairTool()
    if repairToolItem ~= nil then
        lastRepairTool = repairToolItem
        lastRepairToolRecordId = repairToolItem.recordId
        logDebug("openRepairMenu captured " .. tostring(lastRepairToolRecordId))
    else
        logDebug("openRepairMenu captured nil repair tool")
    end

    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Repair Tool Action", textAlignH = ui.ALIGNMENT.Center },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose how to use this repair tool.", textAlignH = ui.ALIGNMENT.Center },
        },
        createButton("Repair", function()
            requestBaseRepairUi(repairToolItem or getActiveRepairTool())
        end, 560),
    }

    if apprenticeHammerEnabled() then
        table.insert(contentLayouts, createButton("Over Repair", function()
            openOverRepairMenu(repairToolItem or getActiveRepairTool())
        end, 560))
    end

    if weaponTemperEnabled() then
        table.insert(contentLayouts, createButton("Hone / Harden", function()
            openTemperWeaponMenu()
        end, 560))
    end

    table.insert(contentLayouts, createButton("Close", function()
        closeAllMenus()
        setInterfaceMode()
    end, 560))

    rootMenuElement = ui.create({
        layer = "Windows",
        name = MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
end

local function onRecordRepairTool(data)
    if type(data) ~= "table" or data.item == nil then
        logDebug("SkillPerkSystem_RecordRepairTool received invalid data")
        return
    end

    lastRepairTool = data.item
    lastRepairToolRecordId = data.recordId or data.item.recordId
    logDebug("recorded repair tool " .. tostring(lastRepairToolRecordId))
end

local function onTemperResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        if data.mode == "restore" and type(data.restoredRecordId) == "string" then
            temperedWeaponCache[data.restoredRecordId] = nil
        elseif type(data.recordId) == "string" and data.recordId ~= "" then
            temperedWeaponCache[data.recordId] = {
                originalRecordId = data.originalRecordId,
                originalName = data.originalName,
                generatedRecordId = data.recordId,
                generatedName = data.generatedName,
                mode = data.mode,
            }
        end
        showMessage(tostring(data.message or "Weapon tempering complete."))
    else
        showMessage(tostring(data.message or "That weapon could not be tempered."))
    end
end

local function onOverrepairResult(data)
    if type(data) ~= "table" then
        return
    end

    if data.success then
        logDebug("overrepair success for " .. tostring(data.recordId) .. " -> " .. tostring(data.targetCondition))
        showMessage(string.format("%s is now at %d condition.", tostring(data.name or "Item"), tonumber(data.targetCondition) or 0))
    else
        logDebug("overrepair failed in global handler reason=" .. tostring(data.reason) .. " recordId=" .. tostring(data.recordId))
        showMessage(tostring(data.message or "That item could not be over-repaired."))
    end
end

local function handleUiModeChanged(data)
    if type(data) ~= "table" then return end

    if data.newMode == "Repair" then
        if suppressNextRepairIntercept then
            suppressNextRepairIntercept = false
            return
        end

        if not anyRepairToolActionEnabled() then
            closeAllMenus()
            return
        end

        openRepairMenu()
        setInterfaceMode()
        return
    end

    if data.newMode == nil or data.newMode == "MainMenu" then
        closeAllMenus()
    end
end

local function tryPendingRepairUse()
    if pendingUseRepairFrames <= 0 or pendingUseRepairTool == nil then return end

    pendingUseRepairFrames = pendingUseRepairFrames - 1
    if pendingUseRepairFrames > 0 then return end

    logDebug("triggering UseItem for " .. tostring(pendingUseRepairTool.recordId))
    core.sendGlobalEvent("UseItem", {
        object = pendingUseRepairTool,
        actor = pself,
    })
    pendingUseRepairTool = nil
end

return {
    eventHandlers = {
        UiModeChanged = handleUiModeChanged,
        SkillPerkSystem_RecordRepairTool = onRecordRepairTool,
        [OVERREPAIR_RESULT_EVENT] = onOverrepairResult,
        [TEMPER_RESULT_EVENT] = onTemperResult,
    },
    engineHandlers = {
        onLoad = function()
            logDebug("onLoad")
        end,
        onFrame = function()
            tryPendingRepairUse()
        end,
    },
}
