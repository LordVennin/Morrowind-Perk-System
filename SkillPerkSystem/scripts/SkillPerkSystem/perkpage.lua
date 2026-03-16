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

local function keyDown(keyName)
    local ok, code = pcall(function()
        return input.KEY[keyName]
    end)
    return ok and code ~= nil and input.isKeyPressed(code)
end

local function anyKeyDown(names)
    for _, name in ipairs(names) do
        if keyDown(name) then
            return true
        end
    end
    return false
end

local menu = nil
local openedInterfaceForPerkMenu = false
local selectedSkillIndex = 1
local selectedPerkIndex = 1

local skillIDs = {}
local filteredPerkIDs = {}
local selectedTreeNodeID = nil
local treePanBySkill = {}
local isDraggingTree = false
local lastMousePos = nil

local SKILL_SELECTOR_WIDTH = 352
local SKILL_INDEX_WIDTH = 80
local SKILL_SELECTOR_ROW_WIDTH = 560

local buildLayout

local function getSkillRecordByID(skillID)
    local direct = core.stats.Skill.records[skillID]
    if direct ~= nil then
        return direct
    end

    for _, record in ipairs(core.stats.Skill.records) do
        if record.id == skillID then
            return record
        end
    end
    return nil
end

local function getSkillIDs()
    local out = {}
    for _, record in ipairs(core.stats.Skill.records) do
        table.insert(out, record.id)
    end
    table.sort(out)
    return out
end

local function getSkillLabel(skillID)
    local record = getSkillRecordByID(skillID)
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

local function getTreePan(skillID)
    if skillID == nil then
        return { x = 0, y = 0 }
    end
    local state = treePanBySkill[skillID]
    if state == nil then
        state = { x = 0, y = 0 }
        treePanBySkill[skillID] = state
    end
    return state
end

local function clampTreePan(pan)
    pan.x = math.max(-600, math.min(600, pan.x))
    pan.y = math.max(-600, math.min(600, pan.y))
end

local function findPerkIndexByID(perkID)
    for i, id in ipairs(filteredPerkIDs) do
        if id == perkID then
            return i
        end
    end
    return 0
end

local function updateFilteredPerks()
    local selectedSkillID = getSelectedSkillID()
    if selectedSkillID == nil then
        filteredPerkIDs = {}
        selectedTreeNodeID = nil
        return
    end

    if type(interfaces[MOD_NAME].loadSkillTree) == "function" then
        interfaces[MOD_NAME].loadSkillTree(selectedSkillID)
    end

    filteredPerkIDs = interfaces[MOD_NAME].getPerkIDsForSkill(selectedSkillID)
    table.sort(filteredPerkIDs)
    if selectedPerkIndex > #filteredPerkIDs then
        selectedPerkIndex = #filteredPerkIDs
    end
    if selectedPerkIndex < 0 then
        selectedPerkIndex = 0
    end

    if selectedTreeNodeID ~= nil and type(interfaces[MOD_NAME].getTreeNode) == "function" then
        local node = interfaces[MOD_NAME].getTreeNode(selectedTreeNodeID)
        if node == nil or node.skill ~= selectedSkillID then
            selectedTreeNodeID = nil
        end
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

local function canPurchasePerk(perkID)
    local perk = interfaces[MOD_NAME].getPerks()[perkID]
    if perk == nil or hasPerk(perkID) then
        return false
    end
    if not requirementSatisfied(perk) then
        return false
    end
    if #getMissingParentPerks(perkID) > 0 then
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
    selectedTreeNodeID = nil
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
    local treeViewportContent = nil
    local selectedSkillID = getSelectedSkillID()
    local treeNodes = type(interfaces[MOD_NAME].getTreeNodesForSkill) == "function"
        and interfaces[MOD_NAME].getTreeNodesForSkill(selectedSkillID)
        or {}

    if #treeNodes > 0 then
        local pan = getTreePan(selectedSkillID)
        local offsetX = 240
        local offsetY = 140
        local treeCanvasContent = {
            {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textDisabled,
                props = {
                    position = util.vector2(8, 8),
                    text = string.format("Tree view (Drag + WASD/Arrows): x=%d y=%d", math.floor(pan.x), math.floor(pan.y)),
                },
            },
        }

        for _, node in ipairs(treeNodes) do
            local perkIndex = findPerkIndexByID(node.id)
            local isSelected = selectedTreeNodeID == node.id or (selectedTreeNodeID == nil and perkIndex > 0 and perkIndex == selectedPerkIndex)
            local title = node.title or node.id
            local nodeLabel = title
            if perkIndex > 0 and hasPerk(node.id) then
                nodeLabel = nodeLabel .. " [owned]"
            elseif perkIndex == 0 then
                nodeLabel = nodeLabel .. " [node]"
            end

            local nodeButton = createBoxedButton(nodeLabel, function()
                selectedTreeNodeID = node.id
                selectedPerkIndex = perkIndex
                menu.layout = buildLayout()
                menu:update()
            end, util.vector2(isSelected and 190 or 180, 24))
            nodeButton.props.position = util.vector2(node.x - pan.x + offsetX, node.y - pan.y + offsetY)

            table.insert(treeCanvasContent, nodeButton)

            if #node.requires > 0 then
                table.insert(treeCanvasContent, {
                    type = ui.TYPE.Text,
                    template = interfaces.MWUI.templates.textDisabled,
                    props = {
                        position = util.vector2(node.x - pan.x + offsetX + 8, node.y - pan.y + offsetY + 26),
                        text = "requires: " .. table.concat(node.requires, ", "),
                    },
                })
            end
        end

        treeViewportContent = {
            type = ui.TYPE.Container,
            props = {
                autoSize = false,
                size = util.vector2(540, 510),
                clip = true,
            },
            content = ui.content {
                {
                    type = ui.TYPE.Widget,
                    props = {
                        autoSize = false,
                        size = util.vector2(2200, 2200),
                        position = util.vector2(-800, -800),
                    },
                    content = ui.content(treeCanvasContent),
                },
            },
        }
    else
        for i, perkID in ipairs(filteredPerkIDs) do
            local perk = interfaces[MOD_NAME].getPerks()[perkID]
            local owned = hasPerk(perkID) and " [owned]" or ""
            local isSelected = i == selectedPerkIndex
            table.insert(perksCol, {
                type = ui.TYPE.Text,
                template = isSelected and interfaces.MWUI.templates.textHeader or interfaces.MWUI.templates.textNormal,
                events = {
                    mouseClick = async:callback(function()
                        selectedTreeNodeID = nil
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
    end

    local skillRecord = selectedSkillID ~= nil and getSkillRecordByID(selectedSkillID) or nil
    local skillName = selectedSkillID ~= nil and getSkillLabel(selectedSkillID) or "Unknown Skill"
    local skillDescription = "No description available."
    if skillRecord ~= nil and type(skillRecord.description) == "string" and skillRecord.description ~= "" then
        skillDescription = skillRecord.description
    end

    local selectedPerkID = selectedPerkIndex > 0 and filteredPerkIDs[selectedPerkIndex] or nil
    if selectedPerkID == nil and selectedTreeNodeID ~= nil then
        selectedPerkID = selectedTreeNodeID
    end

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
        if selectedPerk ~= nil then
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
        else
            local node = type(interfaces[MOD_NAME].getTreeNode) == "function" and interfaces[MOD_NAME].getTreeNode(selectedPerkID) or nil
            local nodeReqs = (node ~= nil and #node.requires > 0) and table.concat(node.requires, ", ") or "None"
            local nodeTitle = (node ~= nil and node.title) or selectedPerkID
            local nodeDescription = (node ~= nil and node.description) or "Tree node defined but no registered perk found yet."
            perkDetail = {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textNormal,
                props = {
                    text = string.format("%s\nNode ID: %s\nRequires: %s\n\n%s", nodeTitle, selectedPerkID, nodeReqs, nodeDescription),
                    autoSize = false,
                    size = util.vector2(374, 360),
                },
            }
        end
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
                        events = #treeNodes > 0 and {
                            mousePress = async:callback(function(mouseEvent)
                                if mouseEvent.button ~= 1 then
                                    return
                                end
                                isDraggingTree = true
                                lastMousePos = mouseEvent.position
                            end),
                            mouseMove = async:callback(function(mouseEvent)
                                if not isDraggingTree or lastMousePos == nil then
                                    return
                                end
                                local selectedSkillIDForPan = getSelectedSkillID()
                                local dragPan = getTreePan(selectedSkillIDForPan)
                                local delta = mouseEvent.position - lastMousePos
                                dragPan.x = dragPan.x - delta.x
                                dragPan.y = dragPan.y - delta.y
                                clampTreePan(dragPan)
                                lastMousePos = mouseEvent.position
                                menu.layout = buildLayout()
                                menu:update()
                            end),
                            mouseRelease = async:callback(function(mouseEvent)
                                if mouseEvent.button == 1 then
                                    isDraggingTree = false
                                    lastMousePos = nil
                                end
                            end),
                            focusLoss = async:callback(function()
                                isDraggingTree = false
                                lastMousePos = nil
                            end),
                        } or nil,
                        content = ui.content(treeViewportContent ~= nil and { treeViewportContent } or perksCol),
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
    local topHeaderFillTiles = {}
    for _ = 1, 49 do
        table.insert(topHeaderFillTiles, {
            type = ui.TYPE.Image,
            props = {
                resource = ui.texture { path = "textures\\menu_head_block_middle.dds" },
                size = util.vector2(20, 30),
            },
        })
    end

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
                                type = ui.TYPE.Flex,
                                props = {
                                    horizontal = true,
                                    autoSize = false,
                                    size = util.vector2(980, 30),
                                },
                                content = ui.content(topHeaderFillTiles),
                            },
                            {
                                type = ui.TYPE.Flex,
                                props = {
                                    horizontal = true,
                                    autoSize = false,
                                    size = util.vector2(980, 30),
                                },
                                content = ui.content {
                                    {
                                        type = ui.TYPE.Widget,
                                        external = { grow = 1 },
                                    },
                                    {
                                        type = ui.TYPE.Container,
                                        template = interfaces.MWUI.templates.boxTransparentThick,
                                        props = {
                                            autoSize = false,
                                            size = util.vector2(180, 24),
                                        },
                                        content = ui.content {
                                            {
                                                type = ui.TYPE.Text,
                                                template = interfaces.MWUI.templates.textHeader,
                                                props = {
                                                    text = "Skill Perks",
                                                    autoSize = false,
                                                    size = util.vector2(180, 24),
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
    selectedTreeNodeID = nil
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
    isDraggingTree = false
    lastMousePos = nil

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
    if menu ~= nil then
        local selectedSkillID = getSelectedSkillID()
        local treeNodes = type(interfaces[MOD_NAME].getTreeNodesForSkill) == "function"
            and interfaces[MOD_NAME].getTreeNodesForSkill(selectedSkillID)
            or {}

        if #treeNodes > 0 then
            local pan = getTreePan(selectedSkillID)
            local panDelta = 320 * dt
            local moved = false

            if anyKeyDown({"LeftArrow", "Left", "A"}) then
                pan.x = pan.x - panDelta
                moved = true
            end
            if anyKeyDown({"RightArrow", "Right", "D"}) then
                pan.x = pan.x + panDelta
                moved = true
            end
            if anyKeyDown({"UpArrow", "Up", "W"}) then
                pan.y = pan.y - panDelta
                moved = true
            end
            if anyKeyDown({"DownArrow", "Down", "S"}) then
                pan.y = pan.y + panDelta
                moved = true
            end

            if moved then
                clampTreePan(pan)
                menu.layout = buildLayout()
                menu:update()
            end
        end
    end

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
