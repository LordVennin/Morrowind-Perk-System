local async = require("openmw.async")
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")

local MENU_NAME = "SkillPerkSystem_BasePack_ApprenticeHammerMenu"
local OVERREPAIR_MENU_NAME = "SkillPerkSystem_BasePack_OverRepairMenu"
local OVERREPAIR_USES_COST = 5
local DEFAULT_MULTIPLIER = 1.10
local APPRENTICE_PERK_ID = "armorer_apprentice_hammer"
local LOG_TAG = "[SkillPerkSystem_BasePack][ApprenticeHammer][RepairMode]"

local rootMenuElement = nil
local subMenuElement = nil
local customMenuOpen = false
local suppressNextRepairIntercept = false
local pendingUseRepairTool = nil
local pendingUseRepairFrames = 0
local lastRepairTool = nil
local lastRepairToolRecordId = nil

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

local function getMaxCondition(item)
    if item == nil then return nil end
    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then return nil end

    if types.Weapon.objectIsInstance(item) then
        local record = types.Weapon.records[recordId]
        if type(record) == "table" then
            return tonumber(record.health or record.maxCondition)
        end
    elseif types.Armor.objectIsInstance(item) then
        local record = types.Armor.records[recordId]
        if type(record) == "table" then
            return tonumber(record.health or record.maxCondition)
        end
    end
    return nil
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
    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then return "Unknown Item" end

    if types.Weapon.objectIsInstance(item) then
        local record = types.Weapon.records[recordId]
        if type(record) == "table" and type(record.name) == "string" and record.name ~= "" then
            return record.name
        end
    elseif types.Armor.objectIsInstance(item) then
        local record = types.Armor.records[recordId]
        if type(record) == "table" and type(record.name) == "string" and record.name ~= "" then
            return record.name
        end
    end
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

local function addUniqueItem(out, seen, item)
    if item == nil or seen[item] then
        return false
    end
    seen[item] = true
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

local function consumeRepairToolUses(item, usesToConsume)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" or currentCondition < usesToConsume or itemData == nil then
        return false
    end
    itemData.condition = currentCondition - usesToConsume
    return true
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

local function applyOverrepairToItem(item, multiplier)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" then return false end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then return false end
    if not isAtNormalMaxCondition(currentCondition, maxCondition) then return false end
    if itemData == nil then return false end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then return false end

    itemData.condition = targetCondition
    return true, targetCondition
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
            local label = string.format(
                "%s (%d/%d)",
                entry.name,
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

                if not consumeRepairToolUses(currentRepairTool, OVERREPAIR_USES_COST) then
                    logDebug("overrepair failed: not enough tool uses")
                    showMessage("Not enough hammer uses remaining (need 5).")
                    return
                end

                local changed, targetCondition = applyOverrepairToItem(targetItem, DEFAULT_MULTIPLIER)
                if changed then
                    logDebug("overrepair success for " .. tostring(entry.recordId) .. " -> " .. tostring(targetCondition))
                    showMessage(string.format("%s is now at %d condition.", entry.name, targetCondition or 0))
                else
                    logDebug("overrepair failed: applyOverrepairToItem returned false for " .. tostring(entry.recordId))
                    showMessage("That item could not be over-repaired.")
                end
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
        createButton("Over Repair", function()
            openOverRepairMenu(repairToolItem or getActiveRepairTool())
        end, 560),
        createButton("Close", function()
            closeAllMenus()
            setInterfaceMode()
        end, 560),
    }

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

local function handleUiModeChanged(data)
    if type(data) ~= "table" then return end

    if data.newMode == "Repair" then
        if suppressNextRepairIntercept then
            suppressNextRepairIntercept = false
            return
        end

        if not apprenticeHammerEnabled() then
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
