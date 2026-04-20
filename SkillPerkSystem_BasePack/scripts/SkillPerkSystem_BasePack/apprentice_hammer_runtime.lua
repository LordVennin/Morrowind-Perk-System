local async = require("openmw.async")
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
local BASE_ROOT_MENU_Y = 0.62
local HEIGHT_ADJUST_FACTOR = 0.22
local ROOT_MENU_MIN_Y = 0.61
local ROOT_MENU_MAX_Y = 0.73
local SUB_MENU_Y_OFFSET = 0.045
local REFERENCE_SCREEN_HEIGHT = 1440
local ROOT_MENU_MIN_WIDTH = 300
local ROOT_MENU_MAX_WIDTH = 360
local ROOT_MENU_WIDTH_FACTOR = 0.18
local SUB_MENU_EXTRA_WIDTH = 80

local rootMenuElement = nil
local subMenuElement = nil
local customMenuOpen = false

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function getLayoutMetrics()
    local screenSize = ui.screenSize()
    local screenWidth = type(screenSize) == "table" and tonumber(screenSize.x) or 1920
    local screenHeight = type(screenSize) == "table" and tonumber(screenSize.y) or REFERENCE_SCREEN_HEIGHT

    local heightOffsetScale = (REFERENCE_SCREEN_HEIGHT - screenHeight) / REFERENCE_SCREEN_HEIGHT
    local rootMenuY = clamp(
        BASE_ROOT_MENU_Y + (heightOffsetScale * HEIGHT_ADJUST_FACTOR),
        ROOT_MENU_MIN_Y,
        ROOT_MENU_MAX_Y
    )
    local subMenuY = clamp(rootMenuY + SUB_MENU_Y_OFFSET, rootMenuY + 0.03, 0.78)

    local rootMenuWidth = math.floor(clamp(screenWidth * ROOT_MENU_WIDTH_FACTOR, ROOT_MENU_MIN_WIDTH, ROOT_MENU_MAX_WIDTH))
    local subMenuWidth = rootMenuWidth + SUB_MENU_EXTRA_WIDTH

    return {
        rootMenuY = rootMenuY,
        subMenuY = subMenuY,
        rootMenuWidth = rootMenuWidth,
        subMenuWidth = subMenuWidth,
    }
end

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

local function getItemCondition(item)
    if item == nil then
        return nil
    end

    local itemData = types.Item.itemData(item)
    if itemData == nil or type(itemData.condition) ~= "number" then
        return nil
    end

    return itemData.condition, itemData
end

local function getMaxCondition(item)
    if item == nil then
        return nil
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end

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

local function getDisplayName(item)
    if item == nil then
        return "Unknown Item"
    end

    local recordId = item.recordId
    if type(recordId) ~= "string" or recordId == "" then
        return "Unknown Item"
    end

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

local function collectOverrepairCandidates()
    local out = {}
    if type(types.Actor.inventory) ~= "function" then
        logDebug("types.Actor.inventory unavailable")
        return out
    end

    local okInv, inventory = pcall(types.Actor.inventory, pself)
    if not okInv or inventory == nil then
        logDebug("failed to read player inventory")
        return out
    end

    for _, item in pairs(inventory) do
        if item ~= nil and (types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item)) then
            local currentCondition = getItemCondition(item)
            local maxCondition = getMaxCondition(item)
            if type(currentCondition) == "number" and type(maxCondition) == "number" and currentCondition == maxCondition then
                table.insert(out, {
                    item = item,
                    name = getDisplayName(item),
                    currentCondition = currentCondition,
                    maxCondition = maxCondition,
                })
            end
        end
    end

    table.sort(out, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    logDebug("overrepair candidates=" .. tostring(#out))
    return out
end

local function applyOverrepairToItem(item, multiplier)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" then
        return false
    end

    local maxCondition = getMaxCondition(item)
    if type(maxCondition) ~= "number" or maxCondition <= 0 then
        return false
    end

    if currentCondition < maxCondition then
        return false
    end

    local targetCondition = math.floor(maxCondition * multiplier + 0.5)
    if targetCondition <= currentCondition then
        return false
    end

    itemData.condition = targetCondition
    return true, targetCondition
end

local function getActiveRepairTool()
    local inventoryAccessor = types.Player ~= nil and types.Player.inventory or nil
    if type(inventoryAccessor) == "function" then
        local okInv, inventory = pcall(inventoryAccessor, pself)
        if okInv and inventory ~= nil and type(inventory.getAll) == "function" then
            local okAll, allTools = pcall(inventory.getAll, inventory, types.Repair)
            if okAll and type(allTools) == "table" and #allTools > 0 then
                return allTools[1]
            end
        end
    end

    if type(types.Actor.getEquipment) == "function" then
        for _, slot in pairs(types.Actor.EQUIPMENT_SLOT or {}) do
            local okItem, item = pcall(types.Actor.getEquipment, pself, slot)
            if okItem and item ~= nil and types.Repair.objectIsInstance(item) then
                return item
            end
        end
    end

    return nil
end

local function consumeRepairToolUses(item, usesToConsume)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" or currentCondition < usesToConsume then
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

    uiApi.setMode("Interface", {
        windows = { "Map", "Stats", "Magic", "Inventory" },
    })
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

    local buttonLayout = {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxButton,
        props = {
            size = util.vector2(width or 540, 28),
        },
        content = ui.content({ textLayout }),
        events = {
            mousePress = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    textLayout.template = interfaces.MWUI.templates.textHeader
                    if rootMenuElement ~= nil then
                        rootMenuElement:update()
                    end
                    if subMenuElement ~= nil then
                        subMenuElement:update()
                    end
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    onSelect()
                end
            end),
            focusGain = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textHeader
                if rootMenuElement ~= nil then
                    rootMenuElement:update()
                end
                if subMenuElement ~= nil then
                    subMenuElement:update()
                end
            end),
            focusLoss = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textNormal
                if rootMenuElement ~= nil then
                    rootMenuElement:update()
                end
                if subMenuElement ~= nil then
                    subMenuElement:update()
                end
            end),
        },
    }

    return buttonLayout
end

local function createOptionsFrame(options, width)
    local framedOptions = {}
    for _, option in ipairs(options) do
        table.insert(framedOptions, option)
    end

    return {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = false,
                    autoSize = true,
                    arrange = ui.ALIGNMENT.Center,
                    padding = util.vector2(6, 6),
                    externalPadding = util.vector2(2, 2),
                    size = util.vector2(width or 540, -1),
                },
                content = ui.content(framedOptions),
            },
        }),
    }
end

local function openOverRepairMenu(repairToolItem)
    logDebug("openOverRepairMenu")
    closeSubMenu()
    local layoutMetrics = getLayoutMetrics()

    local candidates = collectOverrepairCandidates()
    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = {
                text = "Over Repair",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = "Select a fully repaired weapon or armor piece.",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
    }

    local optionLayouts = {}

    if #candidates == 0 then
        table.insert(optionLayouts, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = "No eligible items at full durability.",
                textAlignH = ui.ALIGNMENT.Center,
            },
        })
    else
        for _, entry in ipairs(candidates) do
            local label = string.format("%s (%d/%d)", entry.name, entry.currentCondition, entry.maxCondition)
            table.insert(optionLayouts, createButton(label, function()
                closeAllMenus()
                if repairToolItem == nil then
                    showMessage("No repair tool found.")
                    return
                end
                if not consumeRepairToolUses(repairToolItem, OVERREPAIR_USES_COST) then
                    showMessage("Not enough hammer uses remaining (need 5).")
                    return
                end

                local changed, targetCondition = applyOverrepairToItem(entry.item, DEFAULT_MULTIPLIER)
                if changed then
                    showMessage(string.format("%s is now at %d condition.", entry.name, targetCondition or 0))
                else
                    showMessage("That item could not be over-repaired.")
                end
            end, layoutMetrics.subMenuWidth))
        end
    end

    table.insert(optionLayouts, createButton("Back", function()
        closeSubMenu()
    end, layoutMetrics.subMenuWidth))
    table.insert(contentLayouts, createOptionsFrame(optionLayouts, layoutMetrics.subMenuWidth))

    subMenuElement = ui.create({
        layer = "Modal",
        name = OVERREPAIR_MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0),
            relativePosition = util.vector2(0.5, layoutMetrics.subMenuY),
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

local function openRepairExtensionMenu()
    logDebug("openRepairExtensionMenu")
    closeAllMenus()
    customMenuOpen = true

    local repairToolItem = getActiveRepairTool()
    local layoutMetrics = getLayoutMetrics()

    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = {
                text = "Repair Extensions",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = "Perk actions and custom submenus.",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
    }

    local optionLayouts = {
        createButton("Over Repair", function()
            openOverRepairMenu(repairToolItem)
        end, layoutMetrics.rootMenuWidth),
    }

    if isPerkOwnedAndEnabled("armorer_temper_study") then
        table.insert(optionLayouts, createButton("Temper Study (coming soon)", function()
            showMessage("Temper Study action is not implemented yet.")
        end, layoutMetrics.rootMenuWidth))
    end

    if isPerkOwnedAndEnabled("armorer_field_mender") then
        table.insert(optionLayouts, createButton("Field Mender (coming soon)", function()
            showMessage("Field Mender action is not implemented yet.")
        end, layoutMetrics.rootMenuWidth))
    end

    table.insert(contentLayouts, createOptionsFrame(optionLayouts, layoutMetrics.rootMenuWidth))

    rootMenuElement = ui.create({
        layer = "Modal",
        name = MENU_NAME,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0),
            relativePosition = util.vector2(0.5, layoutMetrics.rootMenuY),
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

local function handleUiModeChanged(data)
    if type(data) ~= "table" then
        return
    end

    logDebug(string.format(
        "UiModeChanged old=%s new=%s apprentice=%s customMenuOpen=%s",
        tostring(data.oldMode),
        tostring(data.newMode),
        tostring(apprenticeHammerEnabled()),
        tostring(customMenuOpen)
    ))

    if data.newMode == "Repair" then

        if not apprenticeHammerEnabled() then
            closeAllMenus()
            return
        end

        openRepairExtensionMenu()
        return
    end

    if data.oldMode == "Repair" and data.newMode ~= "Repair" then
        closeAllMenus()
    end

    if data.newMode == nil or data.newMode == "MainMenu" then
        closeAllMenus()
    end
end

return {
    eventHandlers = {
        UiModeChanged = handleUiModeChanged,
    },
    engineHandlers = {
        onLoad = function()
            logDebug("onLoad")
        end,
    },
}
