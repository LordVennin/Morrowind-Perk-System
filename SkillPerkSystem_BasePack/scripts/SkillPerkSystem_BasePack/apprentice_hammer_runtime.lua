local async = require("openmw.async")
local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")

local PERK_ID = "armorer_apprentice_hammer"
local MENU_NAME = "SkillPerkSystem_BasePack_ApprenticeHammerMenu"
local OVERREPAIR_USES_COST = 5
local DEFAULT_MULTIPLIER = 1.10

local defaultRepairPassthroughItem = nil
local menuElement = nil

local function isPerkOwnedAndEnabled(perkId)
    local playerApi = interfaces.SkillPerkSystemPlayer
    if type(playerApi) ~= "table" then
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
    return true
end

local function applyOverrepairToEquippedItems(multiplier)
    local slots = types.Actor.EQUIPMENT_SLOT
    if type(slots) ~= "table" then
        return false
    end

    local changedAny = false
    for _, slot in pairs(slots) do
        local okItem, item = pcall(types.Actor.getEquipment, pself, slot)
        if okItem and item ~= nil then
            if types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item) then
                changedAny = applyOverrepairToItem(item, multiplier) or changedAny
            end
        end
    end

    return changedAny
end

local function consumeRepairToolUses(item, usesToConsume)
    local currentCondition, itemData = getItemCondition(item)
    if type(currentCondition) ~= "number" or currentCondition < usesToConsume then
        return false
    end

    itemData.condition = currentCondition - usesToConsume
    return true
end

local function showMessage(text)
    ui.showMessage(text, { showInDialogue = false })
end

local function closeMenu()
    if menuElement ~= nil then
        menuElement:destroy()
        menuElement = nil
    end
end

local function runApprenticeOverrepair(item)
    if not consumeRepairToolUses(item, OVERREPAIR_USES_COST) then
        showMessage("Not enough hammer uses remaining (need 5).")
        return
    end

    if applyOverrepairToEquippedItems(DEFAULT_MULTIPLIER) then
        showMessage("Masterwork touch: fully-repaired equipped gear is now at 110% condition.")
        return
    end

    showMessage("No equipped weapon/armor qualifies. Items must be at 100% condition first.")
end

local function openDefaultRepairUi(item)
    defaultRepairPassthroughItem = item
    core.sendGlobalEvent("UseItem", {
        object = item,
        actor = pself,
    })
end

local function perkMenuOptions()
    local options = {
        {
            label = "Default Repair UI",
            action = function(item)
                openDefaultRepairUi(item)
            end,
        },
    }

    if isPerkOwnedAndEnabled("armorer_apprentice_hammer") then
        table.insert(options, {
            label = "Apprentice Hammer: Over-repair (5 uses)",
            action = function(item)
                runApprenticeOverrepair(item)
            end,
        })
    end

    if isPerkOwnedAndEnabled("armorer_temper_study") then
        table.insert(options, {
            label = "Temper Study (coming soon)",
            action = function()
                showMessage("Temper Study action is not implemented yet.")
            end,
        })
    end

    if isPerkOwnedAndEnabled("armorer_field_mender") then
        table.insert(options, {
            label = "Field Mender (coming soon)",
            action = function()
                showMessage("Field Mender action is not implemented yet.")
            end,
        })
    end

    return options
end

local function createButton(label, onSelect)
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
            size = util.vector2(520, 28),
        },
        content = ui.content({ textLayout }),
        events = {
            mousePress = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    textLayout.template = interfaces.MWUI.templates.textHeader
                    if menuElement ~= nil then
                        menuElement:update()
                    end
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    closeMenu()
                    onSelect()
                end
            end),
            focusGain = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textHeader
                if menuElement ~= nil then
                    menuElement:update()
                end
            end),
            focusLoss = async:callback(function()
                textLayout.template = interfaces.MWUI.templates.textNormal
                if menuElement ~= nil then
                    menuElement:update()
                end
            end),
        },
    }

    return buttonLayout
end

local function openPerkMenu(repairToolItem)
    closeMenu()

    local contentLayouts = {
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textHeader,
            props = {
                text = "Repair Tool Action",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
        {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = "Choose how to use this hammer.",
                textAlignH = ui.ALIGNMENT.Center,
            },
        },
    }

    for _, option in ipairs(perkMenuOptions()) do
        table.insert(contentLayouts, createButton(option.label, function()
            option.action(repairToolItem)
        end))
    end

    table.insert(contentLayouts, createButton("Cancel", function()
        showMessage("Repair canceled.")
    end))

    menuElement = ui.create({
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

local function registerItemUseHook()
    local itemUsage = interfaces.ItemUsage
    if type(itemUsage) ~= "table" or type(itemUsage.addHandlerForType) ~= "function" then
        return
    end

    itemUsage.addHandlerForType(types.Repair, function(repairItem, actor)
        if actor ~= pself then
            return
        end

        if repairItem ~= nil and repairItem == defaultRepairPassthroughItem then
            defaultRepairPassthroughItem = nil
            return
        end

        if not isPerkOwnedAndEnabled(PERK_ID) then
            return
        end

        openPerkMenu(repairItem)
        return false
    end)
end

registerItemUseHook()

return {
    eventHandlers = {},
    engineHandlers = {},
}
