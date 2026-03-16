local core = require("openmw.core")
local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")
local ambient = require("openmw.ambient")
local interfaces = require("openmw.interfaces")
local input = require("openmw.input")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local function resolveToggleKey()
    local keyName = tostring(settings.TOGGLE_UI_KEY or "p"):upper()
    local keyCode = input.KEY[keyName]
    if keyCode == nil then
        print("[" .. MOD_NAME .. "] Invalid TOGGLE_UI_KEY='" .. tostring(settings.TOGGLE_UI_KEY) .. "'; using P")
        keyCode = input.KEY.P
    end
    return keyCode
end

local TOGGLE_UI_KEY_CODE = resolveToggleKey()
local toggleKeyWasPressed = false

local menu = nil
local openedInterfaceForPerkMenu = false
local selectedSkillIndex = 1
local selectedPerkIndex = 1

local skillIDs = {}
local filteredPerkIDs = {}

local SKILL_SELECTOR_WIDTH = 352
local SKILL_INDEX_WIDTH = 80
local SKILL_SELECTOR_ROW_WIDTH = 560

local buildLayout

local function getSkillIDs()
    local out = {}
    for skillID, _ in pairs(core.stats.Skill.records) do
        table.insert(out, skillID)
    end
    table.sort(out)
    return out
end

local function getSkillLabel(skillID)
    local record = core.stats.Skill.records[skillID]
    if record ~= nil and type(record.name) == "string" and record.name ~= "" then
        return record.name
    end
    return tostring(skillID)
end

local function getShortSkillLabel(skillID)
    local label = getSkillLabel(skillID)
    if #label <= 6 then
        return label
    end
    return label:sub(1, 5) .. "..."
end

local function hasPerk(perkID)
    return interfaces[MOD_NAME .. "Player"].hasPerk(perkID)
end

local function getSelectedSkillID()
    return skillIDs[selectedSkillIndex]
end

local function updateFilteredPerks()
    local selectedSkillID = getSelectedSkillID()
    if selectedSkillID == nil then
        filteredPerkIDs = {}
        return
    end
    filteredPerkIDs = interfaces[MOD_NAME].getPerkIDsForSkill(selectedSkillID)
    table.sort(filteredPerkIDs)
    if selectedPerkIndex > #filteredPerkIDs then
        selectedPerkIndex = #filteredPerkIDs
    end
    if selectedPerkIndex < 0 then
        selectedPerkIndex = 0
    end
end

local function requirementSatisfied(perk)
    for _, requirement in ipairs(perk.requirements or {}) do
        if type(requirement.check) == "function" and not requirement.check() then
            return false
        end
    end
    return true
end

local function canPurchasePerk(perkID)
    local perk = interfaces[MOD_NAME].getPerks()[perkID]
    if perk == nil or hasPerk(perkID) then
        return false
    end
    if not requirementSatisfied(perk) then
        return false
    end
    return interfaces[MOD_NAME .. "Player"].availablePoints(perk.skill) >= perk.cost
end

local function createButton(label, onPress, enabled, size)
    local buttonTemplate = enabled and interfaces.MWUI.templates.boxButton or interfaces.MWUI.templates.boxDisabled
    local fontTemplate = enabled and interfaces.MWUI.templates.textNormal or interfaces.MWUI.templates.textDisabled

    local textLayout = {
        type = ui.TYPE.Text,
        template = fontTemplate,
        props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.Center,
            relativeSize = util.vector2(1, 1),
        }
    }

    local buttonLayout = {
        type = ui.TYPE.Container,
        template = buttonTemplate,
        props = {
            size = size or util.vector2(140, 28),
        },
        content = ui.content { textLayout }
    }

    if enabled then
        buttonLayout.events = {
            mousePress = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    ambient.playSound("Menu Click")
                    buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                    textLayout.template = interfaces.MWUI.templates.textHeader
                    if menu ~= nil then menu:update() end
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    buttonLayout.template = interfaces.MWUI.templates.boxButton
                    textLayout.template = interfaces.MWUI.templates.textNormal
                    if menu ~= nil then menu:update() end
                    onPress()
                end
            end),
            focusGain = async:callback(function()
                buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                textLayout.template = interfaces.MWUI.templates.textHeader
                if menu ~= nil then menu:update() end
            end),
            focusLoss = async:callback(function()
                buttonLayout.template = interfaces.MWUI.templates.boxButton
                textLayout.template = interfaces.MWUI.templates.textNormal
                if menu ~= nil then menu:update() end
            end),
        }
    end

    return buttonLayout
end

local function createBoxedButton(label, onPress, size, textOffsetY)
    local buttonSize = size or util.vector2(140, 28)
    local yOffset = math.max(0, math.floor(textOffsetY or 0))

    local textLayout = {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.Center,
            autoSize = false,
            size = util.vector2(buttonSize.x, buttonSize.y - yOffset),
        }
    }

    local buttonContent
    if yOffset > 0 then
        buttonContent = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = false,
                    autoSize = false,
                    size = buttonSize,
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        props = { size = util.vector2(1, yOffset) },
                    },
                    textLayout,
                },
            },
        }
    else
        buttonContent = ui.content { textLayout }
    end

    local buttonLayout = {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxButton,
        props = {
            size = buttonSize,
        },
        content = buttonContent
    }

    buttonLayout.events = {
        mousePress = async:callback(function(mouseEvent)
            if mouseEvent.button == 1 then
                ambient.playSound("Menu Click")
                textLayout.template = interfaces.MWUI.templates.textHeader
                if menu ~= nil then menu:update() end
            end
        end),
        mouseRelease = async:callback(function(mouseEvent)
            if mouseEvent.button == 1 then
                textLayout.template = interfaces.MWUI.templates.textNormal
                if menu ~= nil then menu:update() end
                onPress()
            end
        end),
        focusGain = async:callback(function()
            textLayout.template = interfaces.MWUI.templates.textHeader
            if menu ~= nil then menu:update() end
        end),
        focusLoss = async:callback(function()
            textLayout.template = interfaces.MWUI.templates.textNormal
            if menu ~= nil then menu:update() end
        end),
    }

    return buttonLayout
end

local function changeSelectedSkill(delta)
    if #skillIDs == 0 then
        return
    end

    selectedSkillIndex = selectedSkillIndex + delta
    if selectedSkillIndex < 1 then
        selectedSkillIndex = #skillIDs
    elseif selectedSkillIndex > #skillIDs then
        selectedSkillIndex = 1
    end

    selectedPerkIndex = 0
    updateFilteredPerks()

    if menu ~= nil then
        menu.layout = buildLayout()
        menu:update()
    end
end

local function buildSkillTabs()
    local count = #skillIDs
    if count == 0 then
        return {
            type = ui.TYPE.Flex,
            template = interfaces.MWUI.templates.borders,
            props = {
                horizontal = false,
                autoSize = true,
            },
            content = ui.content {},
        }
    end

    local skillID = getSelectedSkillID()
    local label = string.format("%s (%d)", getSkillLabel(skillID), interfaces[MOD_NAME .. "Player"].availablePoints(skillID))

    return {
        type = ui.TYPE.Flex,
        template = interfaces.MWUI.templates.borders,
        props = {
            horizontal = true,
            autoSize = false,
            size = util.vector2(SKILL_SELECTOR_ROW_WIDTH, 32),
        },
        content = ui.content {
            createBoxedButton("<", function()
                changeSelectedSkill(-1)
            end, util.vector2(44, 28), 3),
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(8, 1) },
            },
            {
                type = ui.TYPE.Container,
                template = interfaces.MWUI.templates.boxTransparentThick,
                props = {
                    autoSize = false,
                    size = util.vector2(SKILL_SELECTOR_WIDTH, 28),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Text,
                        template = interfaces.MWUI.templates.textNormal,
                        props = {
                            text = label,
                            textAlignH = ui.ALIGNMENT.Center,
                            textAlignV = ui.ALIGNMENT.Center,
                            autoSize = false,
                            size = util.vector2(SKILL_SELECTOR_WIDTH, 28),
                        },
                    },
                },
            },
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(8, 1) },
            },
            createBoxedButton(">", function()
                changeSelectedSkill(1)
            end, util.vector2(44, 28), 3),
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(12, 1) },
            },
            {
                type = ui.TYPE.Container,
                template = interfaces.MWUI.templates.boxTransparentThick,
                props = {
                    autoSize = false,
                    size = util.vector2(SKILL_INDEX_WIDTH, 28),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Text,
                        template = interfaces.MWUI.templates.textNormal,
                        props = {
                            text = string.format("%d/%d", selectedSkillIndex, count),
                            textAlignH = ui.ALIGNMENT.Center,
                            textAlignV = ui.ALIGNMENT.Center,
                            autoSize = false,
                            size = util.vector2(SKILL_INDEX_WIDTH, 28),
                        },
                    },
                },
            },
        },
    }
end

local function buildPerkPane()
    local perksCol = {}
    for i, perkID in ipairs(filteredPerkIDs) do
        local perk = interfaces[MOD_NAME].getPerks()[perkID]
        local owned = hasPerk(perkID) and " [owned]" or ""
        local isSelected = i == selectedPerkIndex
        table.insert(perksCol, {
            type = ui.TYPE.Text,
            template = isSelected and interfaces.MWUI.templates.textHeader or interfaces.MWUI.templates.textNormal,
            events = {
                mouseClick = async:callback(function()
                    selectedPerkIndex = i
                    menu.layout = buildLayout()
                    menu:update()
                end),
            },
            props = {
                text = string.format("%s (cost %d)%s", perkID, perk.cost, owned),
            }
        })
    end

    local selectedSkillID = getSelectedSkillID()
    local skillRecord = selectedSkillID ~= nil and core.stats.Skill.records[selectedSkillID] or nil
    local skillName = selectedSkillID ~= nil and getSkillLabel(selectedSkillID) or "Unknown Skill"
    local skillDescription = "No description available."
    if skillRecord ~= nil and type(skillRecord.description) == "string" and skillRecord.description ~= "" then
        skillDescription = skillRecord.description
    end

    local selectedPerkID = selectedPerkIndex > 0 and filteredPerkIDs[selectedPerkIndex] or nil

    local function wrapTextLines(text, maxChars)
        local lines = {}

        for paragraph in tostring(text or ""):gmatch("[^\n]+") do
            local line = ""
            for word in paragraph:gmatch("%S+") do
                local candidate = (line == "") and word or (line .. " " .. word)
                if #candidate > maxChars and line ~= "" then
                    table.insert(lines, line)
                    line = word
                else
                    line = candidate
                end
            end
            if line ~= "" then
                table.insert(lines, line)
            end
        end

        if #lines == 0 then
            table.insert(lines, "")
        end
        return lines
    end

    local perkDetail
    if selectedPerkID == nil then
        local detailRows = {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = util.vector2(374, 32),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                    {
                        type = ui.TYPE.Container,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            autoSize = false,
                            size = util.vector2(230, 28),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Text,
                                template = interfaces.MWUI.templates.textHeader,
                                props = {
                                    text = skillName,
                                    autoSize = false,
                                    size = util.vector2(230, 28),
                                    textAlignH = ui.ALIGNMENT.Center,
                                    textAlignV = ui.ALIGNMENT.Center,
                                },
                            },
                        },
                    },
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                },
            },
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(1, 12) },
            },
        }

        for _, line in ipairs(wrapTextLines(skillDescription, 40)) do
            table.insert(detailRows, {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = util.vector2(374, 20),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                    {
                        type = ui.TYPE.Text,
                        template = interfaces.MWUI.templates.textNormal,
                        props = {
                            text = line,
                            textAlignH = ui.ALIGNMENT.Center,
                        },
                    },
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                },
            })
        end

        perkDetail = {
            type = ui.TYPE.Flex,
            props = {
                horizontal = false,
                autoSize = false,
                size = util.vector2(374, 360),
            },
            content = ui.content(detailRows),
        }
    else
        local selectedPerk = interfaces[MOD_NAME].getPerks()[selectedPerkID]
        local owned = hasPerk(selectedPerkID)
        local status = owned and "Owned" or (canPurchasePerk(selectedPerkID) and "Available" or "Unavailable")
        perkDetail = {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = string.format("%s\nSkill: %s\nCost: %d\nStatus: %s", selectedPerkID, selectedPerk.skill, selectedPerk.cost, status),
                autoSize = false,
                size = util.vector2(374, 360),
            },
        }
    end

    return {
        type = ui.TYPE.Flex,
        template = interfaces.MWUI.templates.borders,
        props = {
            horizontal = false,
            size = util.vector2(980, 560),
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = util.vector2(960, 510),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                    {
                        type = ui.TYPE.Flex,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            horizontal = false,
                            autoSize = false,
                            size = util.vector2(540, 510),
                        },
                        content = ui.content(perksCol),
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = util.vector2(16, 1) },
                    },
                    {
                        type = ui.TYPE.Flex,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            horizontal = false,
                            autoSize = false,
                            size = util.vector2(390, 510),
                        },
                        content = ui.content { perkDetail },
                    },
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                }
            },
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(1, 6) },
            },
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = util.vector2(960, 32),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                    {
                        type = ui.TYPE.Container,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            autoSize = true,
                        },
                        content = ui.content {
                            createBoxedButton("Exit", function()
                                pself:sendEvent(MOD_NAME .. "closePerkUI")
                            end, util.vector2(64, 28)),
                        },
                    },
                }
            }
        }
    }
end

buildLayout = function()
    return {
        layer = "Windows",
        name = "SkillPerkSystemMenu",
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Container,
                        template = interfaces.MWUI.templates.boxTransparentThick,
                        props = {
                            autoSize = false,
                            size = util.vector2(980, 30),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Text,
                                template = interfaces.MWUI.templates.textHeader,
                                props = {
                                    text = "Skill Perks",
                                    autoSize = false,
                                    size = util.vector2(980, 30),
                                    textAlignH = ui.ALIGNMENT.Center,
                                    textAlignV = ui.ALIGNMENT.Center,
                                },
                            },
                        },
                    },
                    {
                        type = ui.TYPE.Flex,
                        props = {
                            horizontal = true,
                            autoSize = false,
                            size = util.vector2(980, 32),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Widget,
                                external = { grow = 1 },
                            },
                            buildSkillTabs(),
                            {
                                type = ui.TYPE.Widget,
                                external = { grow = 1 },
                            },
                        },
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = util.vector2(1, 10) },
                    },
                    buildPerkPane(),
                }
            }
        }
    }
end

local function showMenu()
    if menu ~= nil then
        return
    end
    skillIDs = getSkillIDs()
    selectedSkillIndex = math.max(1, math.min(selectedSkillIndex, #skillIDs))
    selectedPerkIndex = 0
    updateFilteredPerks()

    -- Use an isolated interface mode so the perk page has cursor/UI input without
    -- auto-opening vanilla interface windows (inventory/map/magic panes).
    interfaces.UI.setMode("Interface", { windows = {} })
    local interfaceModeOpened = true

    local ok, createdOrError = pcall(function()
        return ui.create(buildLayout())
    end)

    if not ok then
        print("[" .. MOD_NAME .. "] Failed to create perk UI: " .. tostring(createdOrError))
        if interfaceModeOpened then
            interfaces.UI.removeMode("Interface")
        end
        return
    end

    menu = createdOrError
    openedInterfaceForPerkMenu = true
end

local function closeMenu()
    if menu ~= nil then
        menu:destroy()
        menu = nil
    end

    if openedInterfaceForPerkMenu then
        interfaces.UI.removeMode("Interface")
        openedInterfaceForPerkMenu = false
    end
end

local function toggleMenu()
    if menu == nil then
        showMenu()
    else
        closeMenu()
    end
end

local function normalizeConsoleArgs(mode, command)
    if type(mode) == "table" then
        command = mode.command
        mode = mode.mode
    elseif command == nil and type(mode) == "string" then
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

    if lower == "skillperksui" or lower == "lua skillperksui" or lowerWithMode == "lua skillperksui" then
        toggleMenu()
    end
end

local function onFrame(dt)
    local isPressed = input.isKeyPressed(TOGGLE_UI_KEY_CODE)
    if isPressed and not toggleKeyWasPressed then
        toggleMenu()
    end
    toggleKeyWasPressed = isPressed
end

return {
    eventHandlers = {
        [MOD_NAME .. "togglePerkUI"] = toggleMenu,
        [MOD_NAME .. "showPerkUI"] = showMenu,
        [MOD_NAME .. "closePerkUI"] = closeMenu,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onFrame = onFrame,
    }
}
