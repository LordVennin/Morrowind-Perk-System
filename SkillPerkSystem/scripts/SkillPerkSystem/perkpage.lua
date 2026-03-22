local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")
local ambient = require("openmw.ambient")
local interfaces = require("openmw.interfaces")
local input = require("openmw.input")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local activeToggleKeyName = nil
local activeToggleKeyCode = input.KEY.P
local toggleKeyWasPressed = false
local suppressToggleUntilRelease = false

local function refreshToggleKeyBinding()
    local requestedKey = tostring(settings.getToggleUiKey and settings.getToggleUiKey() or settings.TOGGLE_UI_KEY or "p")
    local normalized = requestedKey:upper()

    if normalized == activeToggleKeyName then
        return
    end

    local keyCode = input.KEY[normalized]
    if keyCode == nil then
        print("[" .. MOD_NAME .. "] Invalid TOGGLE_UI_KEY='" .. tostring(requestedKey) .. "'; using P")
        normalized = "P"
        keyCode = input.KEY.P
    end

    activeToggleKeyName = normalized
    activeToggleKeyCode = keyCode
end

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
local lastKnownGlobalPoints = nil
local selectedSkillIndex = 1
local selectedPerkIndex = 1

local skillIDs = {}
local filteredPerkIDs = {}
local selectedTreeNodeID = nil
local treePanBySkill = {}
local treePanInitializedBySkill = {}
local isDraggingTree = false
local lastMousePos = nil
local apiUnavailableWarned = false
local optimisticPerkEffectEnabledByID = {}

local uiScale = 1

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function computeUiScale()
    local referenceWidth = tonumber(settings.PERK_UI_SCALE_REFERENCE_WIDTH) or 1920
    if referenceWidth <= 0 then
        referenceWidth = 1920
    end

    local scale = tonumber(settings.PERK_UI_SCALE_MULTIPLIER) or 1
    if settings.PERK_UI_AUTO_SCALE ~= false then
        local screenWidth = ui.screenSize().x
        scale = scale * (screenWidth / referenceWidth)
    end

    local minScale = tonumber(settings.PERK_UI_SCALE_MIN) or 0.75
    local maxScale = tonumber(settings.PERK_UI_SCALE_MAX) or 1.6
    if minScale > maxScale then
        minScale, maxScale = maxScale, minScale
    end
    return clamp(scale, minScale, maxScale)
end

local function px(value)
    return math.max(1, math.floor(value * uiScale + 0.5))
end

local function v2(x, y)
    return util.vector2(px(x), px(y))
end

local SKILL_SELECTOR_WIDTH = 352
local SKILL_INDEX_WIDTH = 92
local SKILL_SELECTOR_ROW_WIDTH = 560
local SKILL_SELECTOR_EDGE_PADDING = 4
local SKILL_SELECTOR_INNER_PADDING = 6
local SKILL_SELECTOR_CONTROL_SPACER = 12

local PERK_UI_LEFT_PANE_WIDTH = settings.PERK_UI_LEFT_PANE_WIDTH or 540
local PERK_UI_RIGHT_PANE_WIDTH = settings.PERK_UI_RIGHT_PANE_WIDTH or 408
local PERK_UI_SIDE_PADDING = settings.PERK_UI_SIDE_PADDING or 8
local PERK_UI_GUTTER_WIDTH = settings.PERK_UI_GUTTER_WIDTH or 16

local PERK_UI_CONTENT_HEIGHT = 510
local PERK_UI_BOTTOM_ROW_HEIGHT = 32
local PERK_UI_BOTTOM_ROW_SPACER_HEIGHT = 6
local PERK_UI_HEIGHT = 560
local PERK_UI_TOTAL_ROW_WIDTH = (PERK_UI_SIDE_PADDING * 2) + PERK_UI_LEFT_PANE_WIDTH + PERK_UI_GUTTER_WIDTH + PERK_UI_RIGHT_PANE_WIDTH
local PERK_UI_BODY_RIGHT_EXPANSION = settings.PERK_UI_BODY_RIGHT_EXPANSION or 18
local PERK_UI_BODY_WIDTH = PERK_UI_TOTAL_ROW_WIDTH

local TREE_VIEWPORT_WIDTH = PERK_UI_LEFT_PANE_WIDTH
local TREE_VIEWPORT_HEIGHT = PERK_UI_CONTENT_HEIGHT
local TREE_INNER_VIEWPORT_WIDTH = TREE_VIEWPORT_WIDTH - 20
local TREE_INNER_VIEWPORT_HEIGHT = TREE_VIEWPORT_HEIGHT - 42
local TREE_CANVAS_MARGIN = 140
local TREE_CONTENT_OFFSET_X = 240
local TREE_CONTENT_OFFSET_Y = 140

local function refreshLayoutMetrics()
    uiScale = computeUiScale()
    SKILL_SELECTOR_WIDTH = 352
    SKILL_INDEX_WIDTH = 92

    PERK_UI_LEFT_PANE_WIDTH = settings.PERK_UI_LEFT_PANE_WIDTH or 540
    local edgeCompensation = settings.PERK_UI_FRAME_EDGE_COMPENSATION or 10
    PERK_UI_RIGHT_PANE_WIDTH = (settings.PERK_UI_RIGHT_PANE_WIDTH or 408) + edgeCompensation
    PERK_UI_SIDE_PADDING = settings.PERK_UI_SIDE_PADDING or 8
    PERK_UI_GUTTER_WIDTH = settings.PERK_UI_GUTTER_WIDTH or 16
    SKILL_SELECTOR_ROW_WIDTH =
        (SKILL_SELECTOR_EDGE_PADDING * 2)
        + (44 * 2)
        + SKILL_SELECTOR_WIDTH
        + SKILL_INDEX_WIDTH
        + (SKILL_SELECTOR_INNER_PADDING * 2)
        + SKILL_SELECTOR_CONTROL_SPACER

    PERK_UI_CONTENT_HEIGHT = 510
    PERK_UI_BOTTOM_ROW_HEIGHT = 32
    PERK_UI_BOTTOM_ROW_SPACER_HEIGHT = 6
    PERK_UI_HEIGHT = 560
    PERK_UI_TOTAL_ROW_WIDTH = (PERK_UI_SIDE_PADDING * 2) + PERK_UI_LEFT_PANE_WIDTH + PERK_UI_GUTTER_WIDTH + PERK_UI_RIGHT_PANE_WIDTH
    PERK_UI_BODY_RIGHT_EXPANSION = settings.PERK_UI_BODY_RIGHT_EXPANSION or 18
    PERK_UI_BODY_WIDTH = PERK_UI_TOTAL_ROW_WIDTH + PERK_UI_BODY_RIGHT_EXPANSION

    TREE_VIEWPORT_WIDTH = PERK_UI_LEFT_PANE_WIDTH
    TREE_VIEWPORT_HEIGHT = PERK_UI_CONTENT_HEIGHT
    TREE_INNER_VIEWPORT_WIDTH = TREE_VIEWPORT_WIDTH - 4
    TREE_INNER_VIEWPORT_HEIGHT = TREE_VIEWPORT_HEIGHT - 42
    TREE_CANVAS_MARGIN = 140
    TREE_CONTENT_OFFSET_X = 240
    TREE_CONTENT_OFFSET_Y = 140
end

local buildLayout

local function getSkillIDs()
    local modApi = interfaces[MOD_NAME]
    local out = {}
    if modApi ~= nil and type(modApi.getTabIDs) == "function" then
        for _, tabID in ipairs(modApi.getTabIDs() or {}) do
            table.insert(out, tabID)
        end
    end
    table.sort(out)
    return out
end

local function getSkillLabel(skillID)
    local modApi = interfaces[MOD_NAME]
    if modApi ~= nil and type(modApi.getTabLabel) == "function" then
        local label = modApi.getTabLabel(skillID)
        if type(label) == "string" and label ~= "" then
            return label
        end
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

local function getModApi()
    local modApi = interfaces[MOD_NAME]
    if modApi == nil and not apiUnavailableWarned then
        apiUnavailableWarned = true
        print("[" .. MOD_NAME .. "] SkillPerkSystem API unavailable")
    end
    return modApi
end

local function hasPerk(perkID)
    return interfaces[MOD_NAME .. "Player"].hasPerk(perkID)
end

local function isPerkEffectEnabled(perkID)
    local playerApi = interfaces[MOD_NAME .. "Player"]
    if playerApi == nil or type(playerApi.isPerkEffectEnabled) ~= "function" then
        return hasPerk(perkID)
    end
    return playerApi.isPerkEffectEnabled(perkID)
end

local function getPerkEffectEnabledForUI(perkID)
    local optimisticEnabled = optimisticPerkEffectEnabledByID[perkID]
    if optimisticEnabled ~= nil then
        local actualEnabled = isPerkEffectEnabled(perkID)
        if actualEnabled == optimisticEnabled then
            optimisticPerkEffectEnabledByID[perkID] = nil
        end
        return optimisticEnabled
    end
    return isPerkEffectEnabled(perkID)
end

local function getSelectedSkillID()
    return skillIDs[selectedSkillIndex]
end

local function getCurrentGlobalPoints(skillID)
    local playerApi = interfaces[MOD_NAME .. "Player"]
    if playerApi == nil then
        return 0
    end

    if type(playerApi.globalAvailablePoints) == "function" then
        local points = playerApi.globalAvailablePoints()
        if type(points) == "number" then
            return math.max(0, math.floor(points))
        end
    end

    if type(playerApi.availablePoints) == "function" then
        local points = playerApi.availablePoints(skillID)
        if type(points) == "number" then
            return math.max(0, math.floor(points))
        end
    end

    return 0
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

local function ensureTreePanInitialized(skillID, treeNodes)
    if skillID == nil or treePanInitializedBySkill[skillID] then
        return
    end
    if treeNodes == nil or #treeNodes == 0 then
        return
    end

    local minX, maxX = treeNodes[1].x, treeNodes[1].x
    local minY, maxY = treeNodes[1].y, treeNodes[1].y
    for i = 2, #treeNodes do
        local node = treeNodes[i]
        minX = math.min(minX, node.x)
        maxX = math.max(maxX, node.x)
        minY = math.min(minY, node.y)
        maxY = math.max(maxY, node.y)
    end

    local pan = getTreePan(skillID)
    pan.x = math.floor((minX + maxX) / 2)
    pan.y = -math.floor((minY + maxY) / 2)
    local maxPan = px(600)
    pan.x = math.max(-maxPan, math.min(maxPan, pan.x))
    pan.y = math.max(-maxPan, math.min(maxPan, pan.y))
    treePanInitializedBySkill[skillID] = true
end

local function clampTreePan(pan)
    local maxPan = px(600)
    pan.x = math.max(-maxPan, math.min(maxPan, pan.x))
    pan.y = math.max(-maxPan, math.min(maxPan, pan.y))
end

local function updateTreePanBounds(skillID, treeNodes)
    if skillID == nil or treeNodes == nil or #treeNodes == 0 then
        return
    end

    local minX, maxX = treeNodes[1].x, treeNodes[1].x
    local minY, maxY = treeNodes[1].y, treeNodes[1].y
    for i = 2, #treeNodes do
        local node = treeNodes[i]
        minX = math.min(minX, node.x)
        maxX = math.max(maxX, node.x)
        minY = math.min(minY, node.y)
        maxY = math.max(maxY, node.y)
    end

    local pan = getTreePan(skillID)
    local halfViewportX = math.floor(TREE_INNER_VIEWPORT_WIDTH / 2)
    local halfViewportY = math.floor(TREE_INNER_VIEWPORT_HEIGHT / 2)
    local edgeSlackX = math.max(40, halfViewportX - TREE_CANVAS_MARGIN)
    local edgeSlackY = math.max(40, halfViewportY - TREE_CANVAS_MARGIN)

    local minPanX = minX - edgeSlackX
    local maxPanX = maxX + edgeSlackX
    local minPanY = -maxY - edgeSlackY
    local maxPanY = -minY + edgeSlackY

    if minPanX > maxPanX then
        minPanX, maxPanX = maxPanX, minPanX
    end
    if minPanY > maxPanY then
        minPanY, maxPanY = maxPanY, minPanY
    end

    pan.x = math.max(minPanX, math.min(maxPanX, pan.x))
    pan.y = math.max(minPanY, math.min(maxPanY, pan.y))
    clampTreePan(pan)
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
    local modApi = interfaces[MOD_NAME]
    if modApi == nil then
        if not apiUnavailableWarned then
            apiUnavailableWarned = true
            print("[" .. MOD_NAME .. "] SkillPerkSystem API unavailable")
        end
        filteredPerkIDs = {}
        selectedTreeNodeID = nil
        return
    end

    local selectedSkillID = getSelectedSkillID()
    if selectedSkillID == nil then
        filteredPerkIDs = {}
        selectedTreeNodeID = nil
        return
    end

    if type(modApi.getPerkIDsForTab) == "function" then
        filteredPerkIDs = modApi.getPerkIDsForTab(selectedSkillID) or {}
    elseif type(modApi.getPerkIDsForSkill) == "function" then
        filteredPerkIDs = modApi.getPerkIDsForSkill(selectedSkillID) or {}
    else
        filteredPerkIDs = {}
    end
    table.sort(filteredPerkIDs)
    if selectedPerkIndex > #filteredPerkIDs then
        selectedPerkIndex = #filteredPerkIDs
    end
    if selectedPerkIndex < 0 then
        selectedPerkIndex = 0
    end

    if selectedTreeNodeID ~= nil and type(modApi.getTreeNode) == "function" then
        local node = modApi.getTreeNode(selectedTreeNodeID)
        if node == nil or node.tab ~= selectedSkillID then
            selectedTreeNodeID = nil
        end
    end
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

local function isRequirementMet(requirement)
    local check = getRequirementCheck(requirement)
    if check == nil then
        return true
    end
    return check()
end

local function getRequirementLabel(requirement, index)
    if type(requirement) == "table" and type(requirement.label) == "string" and requirement.label ~= "" then
        return requirement.label
    end
    return "Requirement " .. tostring(index)
end

local function requirementSatisfied(perk)
    for _, requirement in ipairs(perk.requirements or {}) do
        if not isRequirementMet(requirement) then
            return false
        end
    end
    return true
end

local function getParentRequirementLabel(parentID)
    local modApi = getModApi()
    if modApi ~= nil and type(modApi.getTreeNode) == "function" then
        local parentNode = modApi.getTreeNode(parentID)
        if parentNode ~= nil and type(parentNode.title) == "string" and parentNode.title ~= "" then
            return string.format("Parent perk: %s", parentNode.title)
        end
    end
    return string.format("Parent perk: %s", tostring(parentID))
end

local function getMissingParentPerks(perkID)
    local modApi = getModApi()
    if modApi == nil or type(modApi.getTreeNode) ~= "function" then
        return {}
    end

    local node = modApi.getTreeNode(perkID)
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
    local modApi = getModApi()
    local perks = modApi ~= nil and type(modApi.getPerks) == "function" and modApi.getPerks() or {}
    local perk = perks[perkID]
    if perk == nil or hasPerk(perkID) then
        return false
    end
    if not requirementSatisfied(perk) then
        return false
    end
    if #getMissingParentPerks(perkID) > 0 then
        return false
    end
    local playerApi = interfaces[MOD_NAME .. "Player"]
    local available = type(playerApi.globalAvailablePoints) == "function" and playerApi.globalAvailablePoints() or playerApi.availablePoints(perk.tab)
    return available >= perk.cost
end

local function createButton(label, onPress, enabled, size)
    local buttonTemplate = interfaces.MWUI.templates.boxTransparentThick
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
            size = size or v2(140, 28),
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
                    buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
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
                buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                textLayout.template = interfaces.MWUI.templates.textNormal
                if menu ~= nil then menu:update() end
            end),
        }
    end

    return buttonLayout
end

local function createBoxedButton(label, onPress, size, textOffsetY, textTemplate)
    local buttonSize = size or v2(140, 28)
    local yOffset = math.max(0, math.floor(textOffsetY or 0))
    local idleTextTemplate = textTemplate or interfaces.MWUI.templates.textNormal

    local textLayout = {
        type = ui.TYPE.Text,
        template = idleTextTemplate,
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
                        props = { size = v2(1, yOffset) },
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
                textLayout.template = idleTextTemplate
                if menu ~= nil then menu:update() end
                onPress()
            end
        end),
        focusGain = async:callback(function()
            textLayout.template = interfaces.MWUI.templates.textHeader
            if menu ~= nil then menu:update() end
        end),
        focusLoss = async:callback(function()
            textLayout.template = idleTextTemplate
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
    local label = getSkillLabel(skillID)

    return {
        type = ui.TYPE.Flex,
        template = interfaces.MWUI.templates.borders,
        props = {
            horizontal = true,
            autoSize = false,
            size = v2(SKILL_SELECTOR_ROW_WIDTH, 32),
        },
        content = ui.content {
            {
                type = ui.TYPE.Widget,
                props = { size = v2(SKILL_SELECTOR_EDGE_PADDING, 1) },
            },
            createBoxedButton("<", function()
                changeSelectedSkill(-1)
            end, v2(44, 28), px(3)),
            {
                type = ui.TYPE.Widget,
                props = { size = v2(SKILL_SELECTOR_INNER_PADDING, 1) },
            },
            {
                type = ui.TYPE.Container,
                template = interfaces.MWUI.templates.boxTransparentThick,
                props = {
                    autoSize = false,
                    size = v2(SKILL_SELECTOR_WIDTH, 28),
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
                            size = v2(SKILL_SELECTOR_WIDTH, 28),
                        },
                    },
                },
            },
            {
                type = ui.TYPE.Widget,
                props = { size = v2(SKILL_SELECTOR_INNER_PADDING, 1) },
            },
            createBoxedButton(">", function()
                changeSelectedSkill(1)
            end, v2(44, 28), px(3)),
            {
                type = ui.TYPE.Widget,
                props = { size = v2(SKILL_SELECTOR_CONTROL_SPACER, 1) },
            },
            {
                type = ui.TYPE.Container,
                template = interfaces.MWUI.templates.boxTransparentThick,
                props = {
                    autoSize = false,
                    size = v2(SKILL_INDEX_WIDTH, 28),
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
                            size = v2(SKILL_INDEX_WIDTH, 28),
                        },
                    },
                },
            },
            {
                type = ui.TYPE.Widget,
                props = { size = v2(SKILL_SELECTOR_EDGE_PADDING, 1) },
            },
        },
    }
end

local function buildGlobalPointsDisplay()
    local pointsValue = tostring(getCurrentGlobalPoints(getSelectedSkillID()))
    local boxWidth = 84
    local boxHeight = 24

    return {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            autoSize = false,
            size = v2(boxWidth, boxHeight),
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = v2(boxWidth, boxHeight),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(6, 1) },
                    },
                    {
                        type = ui.TYPE.Flex,
                        props = {
                            horizontal = false,
                            autoSize = false,
                            size = v2(16, boxHeight),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Widget,
                                props = { size = v2(1, 3) },
                            },
                            {
                                type = ui.TYPE.Image,
                                props = {
                                    autoSize = false,
                                    size = v2(16, 16),
                                    resource = ui.texture { path = "icons/tx_goldicon.dds" },
                                },
                            },
                        },
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(6, 1) },
                    },
                    {
                        type = ui.TYPE.Text,
                        template = interfaces.MWUI.templates.textNormal,
                        props = {
                            text = pointsValue,
                            textAlignH = ui.ALIGNMENT.Center,
                            textAlignV = ui.ALIGNMENT.Center,
                            autoSize = false,
                            size = v2(50, boxHeight),
                        },
                    },
                },
            },
        },
    }
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

local function truncateLabel(text, maxChars)
    local source = tostring(text or "")
    local limit = math.max(4, math.floor(tonumber(maxChars) or 0))
    if #source <= limit then
        return source
    end
    return source:sub(1, limit - 3) .. "..."
end

local function buildMultilineTextRows(lines, rowWidth, rowHeight, maxVisibleRows)
    local rows = {}
    local visibleRows = math.max(1, tonumber(maxVisibleRows) or 1)
    local rowLimit = math.min(#lines, visibleRows)
    for index = 1, rowLimit do
        table.insert(rows, {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                text = lines[index],
                autoSize = false,
                size = v2(rowWidth, rowHeight),
                textAlignH = ui.ALIGNMENT.Start,
                textAlignV = ui.ALIGNMENT.Start,
            },
        })
    end
    return rows
end

local function estimateWrapMaxChars(usableTextWidth, minChars)
    local safeMinChars = math.max(20, tonumber(minChars) or 20)
    local usablePixelWidth = math.max(1, px(tonumber(usableTextWidth) or 0))
    local estimatedChars = math.floor((usablePixelWidth + px(6)) / math.max(1, px(6)))
    return math.max(safeMinChars, estimatedChars)
end

local function buildPerkDetailPane(selectedPerkID, selectedPerk, node, skillName, skillDescription, rightPaneWidth, showFullPerkDetails)
    local contentWidth = math.max(220, rightPaneWidth - 14)
    local titleWidth = math.min(contentWidth, px(252))
    local contentHeight = PERK_UI_CONTENT_HEIGHT
    local outerPad = math.max(px(4), math.floor(contentHeight * 0.012))
    local sectionGap = math.max(px(4), math.floor(contentHeight * 0.014))
    local topRowHeight = math.max(px(24), math.floor(contentHeight * 0.052))
    local twoColumnHeight = math.max(px(130), math.floor(contentHeight * 0.305))
    local unlockAnchorReserveHeight = px(42)
    local descriptionSectionHeight = math.max(
        px(132),
        contentHeight - (outerPad + topRowHeight + sectionGap + twoColumnHeight + sectionGap + unlockAnchorReserveHeight)
    )
    local leftColumnWidth = math.floor(contentWidth * 0.6)
    local rightColumnWidth = contentWidth - leftColumnWidth - sectionGap
    local requirementInset = math.max(px(4), math.floor(contentWidth * 0.012))
    local requirementRowHeight = math.max(px(20), math.floor(twoColumnHeight * 0.12))
    local requirementRowGap = math.max(px(2), math.floor(twoColumnHeight * 0.022))
    local descriptionHeight = descriptionSectionHeight
    local compactControlHeight = math.max(px(24), requirementRowHeight)
    local rightBoxGap = requirementRowGap
    local descriptionTextWidth = contentWidth - (requirementInset * 4)
    local descriptionWrapMaxChars = estimateWrapMaxChars(descriptionTextWidth, 20)
    local descriptionLineHeight = math.max(px(16), math.floor(contentHeight * 0.032))

    local title = selectedPerkID or skillName or "Perk Details"
    local descriptionText = skillDescription or "Perks registered under this tab."
    local cost = 0
    local owned = false
    local effectEnabled = false
    local canUnlock = false

    if node ~= nil and type(node.title) == "string" and node.title ~= "" then
        title = node.title
    end

    if selectedPerk ~= nil then
        cost = selectedPerk.cost or 0
        owned = hasPerk(selectedPerkID)
        effectEnabled = owned and getPerkEffectEnabledForUI(selectedPerkID)
        canUnlock = canPurchasePerk(selectedPerkID)
    end

    if node ~= nil and type(node.description) == "string" and node.description ~= "" then
        descriptionText = node.description
    elseif selectedPerk ~= nil then
        descriptionText = string.format("Perk ID: %s\nTab: %s", tostring(selectedPerkID), tostring(selectedPerk.tab))
    end

    if not showFullPerkDetails then
        local compactDescriptionHeight = math.max(px(150), math.floor(contentHeight * 0.36))
        local compactDescriptionLines = wrapTextLines(skillDescription, descriptionWrapMaxChars)
        local compactVisibleRows = math.max(1, math.floor((compactDescriptionHeight - (outerPad * 2)) / descriptionLineHeight))
        local compactDescriptionRows = buildMultilineTextRows(
            compactDescriptionLines,
            descriptionTextWidth,
            descriptionLineHeight,
            compactVisibleRows
        )

        return {
            type = ui.TYPE.Flex,
            props = {
                horizontal = false,
                autoSize = false,
                size = v2(rightPaneWidth, contentHeight),
            },
            content = ui.content {
                {
                    type = ui.TYPE.Widget,
                    external = { grow = 1 },
                },
                {
                    type = ui.TYPE.Flex,
                    props = {
                        horizontal = true,
                        autoSize = false,
                        size = v2(contentWidth, topRowHeight),
                    },
                    content = ui.content {
                        { type = ui.TYPE.Widget, external = { grow = 1 } },
                        {
                            type = ui.TYPE.Container,
                            template = interfaces.MWUI.templates.boxSolidThick,
                            props = { autoSize = false, size = v2(titleWidth, topRowHeight) },
                            content = ui.content {
                                {
                                    type = ui.TYPE.Text,
                                    template = interfaces.MWUI.templates.textHeader,
                                    props = {
                                        text = skillName,
                                        autoSize = false,
                                        size = v2(titleWidth, topRowHeight),
                                        textAlignH = ui.ALIGNMENT.Center,
                                        textAlignV = ui.ALIGNMENT.Center,
                                    },
                                },
                            },
                        },
                        { type = ui.TYPE.Widget, external = { grow = 1 } },
                    },
                },
                {
                    type = ui.TYPE.Widget,
                    props = { size = v2(1, sectionGap) },
                },
                {
                    type = ui.TYPE.Flex,
                    props = {
                        horizontal = true,
                        autoSize = false,
                        size = v2(contentWidth, compactDescriptionHeight),
                    },
                    content = ui.content {
                        { type = ui.TYPE.Widget, external = { grow = 1 } },
                        {
                            type = ui.TYPE.Container,
                            template = interfaces.MWUI.templates.borders,
                            props = {
                                autoSize = false,
                                size = v2(contentWidth - (requirementInset * 2), compactDescriptionHeight),
                                clip = true,
                            },
                            content = ui.content {
                                {
                                    type = ui.TYPE.Flex,
                                    props = {
                                        horizontal = false,
                                        autoSize = false,
                                        size = v2(descriptionTextWidth, compactDescriptionHeight - (outerPad * 2)),
                                        position = v2(requirementInset, outerPad),
                                        arrange = ui.ALIGNMENT.Start,
                                    },
                                    content = ui.content(compactDescriptionRows),
                                },
                            },
                        },
                        { type = ui.TYPE.Widget, external = { grow = 1 } },
                    },
                },
                {
                    type = ui.TYPE.Widget,
                    external = { grow = 1 },
                },
            },
        }
    end

    local requirementRows = {}

    if node ~= nil and type(node.requires) == "table" then
        for _, parentID in ipairs(node.requires) do
            local parentOwned = hasPerk(parentID)
            table.insert(requirementRows, {
                label = getParentRequirementLabel(parentID),
                met = parentOwned,
            })
        end
    end

    if selectedPerk ~= nil and type(selectedPerk.requirements) == "table" and #selectedPerk.requirements > 0 then
        for index, requirement in ipairs(selectedPerk.requirements) do
            local requirementMet = isRequirementMet(requirement)
            table.insert(requirementRows, {
                label = getRequirementLabel(requirement, index),
                met = requirementMet,
            })
        end
    end

    if #requirementRows == 0 then
        table.insert(requirementRows, {
            label = "No requirements",
            met = true,
        })
    end

    local requirementContent = {
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, 4) },
        },
        {
            type = ui.TYPE.Container,
            template = interfaces.MWUI.templates.borders,
            props = {
                autoSize = false,
                size = v2(leftColumnWidth - (requirementInset * 2), requirementRowHeight),
            },
            content = ui.content {
                {
                    type = ui.TYPE.Text,
                    template = interfaces.MWUI.templates.textHeader,
                    props = {
                        text = "Requirements",
                        autoSize = false,
                        size = v2(leftColumnWidth - (requirementInset * 2), requirementRowHeight),
                        textAlignH = ui.ALIGNMENT.Center,
                        textAlignV = ui.ALIGNMENT.Center,
                    },
                },
            },
        },
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, requirementRowGap) },
        },
    }

    for _, req in ipairs(requirementRows) do
        table.insert(requirementContent, {
            type = ui.TYPE.Container,
            template = interfaces.MWUI.templates.borders,
            props = {
                autoSize = false,
                size = v2(leftColumnWidth - (requirementInset * 2), requirementRowHeight),
            },
            content = ui.content {
                {
                    type = ui.TYPE.Flex,
                    props = {
                        horizontal = true,
                        autoSize = false,
                        size = v2(leftColumnWidth - (requirementInset * 2), requirementRowHeight),
                    },
                    content = ui.content {
                        {
                            type = ui.TYPE.Widget,
                            props = { size = v2(requirementInset, 1) },
                        },
                        {
                            type = ui.TYPE.Text,
                            template = interfaces.MWUI.templates.textNormal,
                            props = {
                                text = req.label,
                            },
                        },
                        {
                            type = ui.TYPE.Widget,
                            external = { grow = 1 },
                        },
                        {
                            type = ui.TYPE.Widget,
                            props = { size = v2(requirementInset, 1) },
                        },
                    },
                },
            },
        })
        table.insert(requirementContent, {
            type = ui.TYPE.Widget,
            props = { size = v2(1, requirementRowGap) },
        })
    end

    local unlockLabel = "No Perk Selected"
    local unlockEnabled = false
    local showUnlockButton = false
    if selectedPerk ~= nil then
        if canUnlock then
            unlockLabel = "Unlock Perk"
            unlockEnabled = true
            showUnlockButton = true
        else
            showUnlockButton = false
        end
    end

    local unlockButton = nil
    if showUnlockButton then
        unlockButton = createButton(unlockLabel, function()
            if selectedPerkID ~= nil then
                pself:sendEvent(MOD_NAME .. "addPerk", { perkID = selectedPerkID })
                menu.layout = buildLayout()
                menu:update()
            end
        end, unlockEnabled, v2(104, 24))
    end

    local toggleButton = nil
    if selectedPerk ~= nil and owned then
        local toggleLabel = effectEnabled and "Disable" or "Enable"
        toggleButton = createButton(toggleLabel, function()
            if selectedPerkID ~= nil and owned then
                local nextEffectEnabled = not effectEnabled
                optimisticPerkEffectEnabledByID[selectedPerkID] = nextEffectEnabled
                pself:sendEvent(MOD_NAME .. "togglePerkEffect", { perkID = selectedPerkID, enabled = nextEffectEnabled })
                menu.layout = buildLayout()
                menu:update()
            end
        end, true, v2(rightColumnWidth - 12, compactControlHeight - 2))
    end

    local toggleButtonContent = ui.content {
        {
            type = ui.TYPE.Widget,
            external = { grow = 1 },
        },
    }
    if toggleButton ~= nil then
        toggleButtonContent = ui.content {
            {
                type = ui.TYPE.Widget,
                external = { grow = 1 },
            },
            {
                type = ui.TYPE.Flex,
                props = { horizontal = false, autoSize = false, size = v2(rightColumnWidth, compactControlHeight) },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        external = { grow = 1 },
                    },
                    {
                        type = ui.TYPE.Flex,
                        props = { horizontal = true, autoSize = false, size = v2(rightColumnWidth, compactControlHeight - 2) },
                        content = ui.content {
                            {
                                type = ui.TYPE.Widget,
                                external = { grow = 1 },
                            },
                            toggleButton,
                            {
                                type = ui.TYPE.Widget,
                                external = { grow = 1 },
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
                external = { grow = 1 },
            },
        }
    end

    local rightColumnContent = {
        {
            type = ui.TYPE.Container,
            template = interfaces.MWUI.templates.borders,
            props = { autoSize = false, size = v2(rightColumnWidth, compactControlHeight) },
            content = ui.content {
                {
                    type = ui.TYPE.Text,
                    template = interfaces.MWUI.templates.textNormal,
                    props = {
                        text = string.format("Cost: %d", cost),
                        autoSize = false,
                        size = v2(rightColumnWidth, compactControlHeight),
                        textAlignH = ui.ALIGNMENT.Center,
                        textAlignV = ui.ALIGNMENT.Center,
                    },
                },
            },
        },
    }

    if owned then
        table.insert(rightColumnContent, {
            type = ui.TYPE.Widget,
            props = { size = v2(1, rightBoxGap) },
        })
        table.insert(rightColumnContent, {
            type = ui.TYPE.Container,
            template = interfaces.MWUI.templates.borders,
            props = { autoSize = false, size = v2(rightColumnWidth, compactControlHeight) },
            content = ui.content {
                {
                    type = ui.TYPE.Flex,
                    props = { horizontal = true, autoSize = false, size = v2(rightColumnWidth, compactControlHeight) },
                    content = toggleButtonContent,
                },
            },
        })
    end

    table.insert(rightColumnContent, {
        type = ui.TYPE.Widget,
        external = { grow = 1 },
    })

    local descriptionLines = wrapTextLines(descriptionText, descriptionWrapMaxChars)
    local fullVisibleRows = math.max(1, math.floor((descriptionHeight - (outerPad * 2)) / descriptionLineHeight))
    local descriptionRows = buildMultilineTextRows(descriptionLines, descriptionTextWidth, descriptionLineHeight, fullVisibleRows)

    local detailContent = {
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, outerPad) },
        },
        {
            type = ui.TYPE.Flex,
            props = {
                horizontal = true,
                autoSize = false,
                size = v2(contentWidth, topRowHeight),
            },
            content = ui.content {
                { type = ui.TYPE.Widget, external = { grow = 1 } },
                {
                    type = ui.TYPE.Container,
                    template = interfaces.MWUI.templates.boxSolidThick,
                    props = { autoSize = false, size = v2(titleWidth, topRowHeight) },
                    content = ui.content {
                        {
                            type = ui.TYPE.Text,
                            template = interfaces.MWUI.templates.textHeader,
                            props = {
                                text = title,
                                autoSize = false,
                                size = v2(titleWidth, topRowHeight),
                                textAlignH = ui.ALIGNMENT.Center,
                                textAlignV = ui.ALIGNMENT.Center,
                            },
                        },
                    },
                },
                { type = ui.TYPE.Widget, external = { grow = 1 } },
            },
        },
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, sectionGap) },
        },
        {
            type = ui.TYPE.Flex,
            props = {
                horizontal = true,
                autoSize = false,
                size = v2(contentWidth, twoColumnHeight),
            },
            content = ui.content {
                {
                    type = ui.TYPE.Container,
                    template = interfaces.MWUI.templates.borders,
                    props = {
                        autoSize = false,
                        size = v2(leftColumnWidth, twoColumnHeight),
                    },
                    content = ui.content {
                        {
                            type = ui.TYPE.Flex,
                            props = { horizontal = false, autoSize = false, size = v2(leftColumnWidth, twoColumnHeight) },
                            content = ui.content(requirementContent),
                        },
                    },
                },
                {
                    type = ui.TYPE.Widget,
                    props = { size = v2(sectionGap, 1) },
                },
                {
                    type = ui.TYPE.Flex,
                    props = { horizontal = false, autoSize = false, size = v2(rightColumnWidth, twoColumnHeight) },
                    content = ui.content(rightColumnContent),
                },
            },
        },
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, sectionGap) },
        },
        {
            type = ui.TYPE.Container,
            props = { autoSize = false, size = v2(contentWidth, descriptionSectionHeight) },
            content = ui.content {
                {
                    type = ui.TYPE.Container,
                    template = interfaces.MWUI.templates.borders,
                    props = {
                        autoSize = false,
                        size = v2(contentWidth - (requirementInset * 2), descriptionHeight),
                        position = v2(requirementInset, 0),
                        clip = true,
                    },
                    content = ui.content {
                        {
                            type = ui.TYPE.Flex,
                            props = {
                                horizontal = false,
                                autoSize = false,
                                size = v2(descriptionTextWidth, descriptionHeight - (outerPad * 2)),
                                position = v2(requirementInset, outerPad),
                                arrange = ui.ALIGNMENT.Start,
                            },
                            content = ui.content(descriptionRows),
                        },
                    },
                },
            },
        },
        {
            type = ui.TYPE.Widget,
            props = { size = v2(1, math.max(px(2), unlockAnchorReserveHeight - outerPad)) },
        },
    }

    local rootContent = {
        {
            type = ui.TYPE.Flex,
            props = {
                horizontal = false,
                autoSize = false,
                size = v2(rightPaneWidth, contentHeight),
            },
            content = ui.content(detailContent),
        },
    }

    if unlockButton ~= nil then
        table.insert(rootContent, {
            type = ui.TYPE.Container,
            props = {
                autoSize = false,
                size = v2(112, 28),
                position = v2(px(10), contentHeight - px(38)),
            },
            content = ui.content { unlockButton },
        })
    end

    return {
        type = ui.TYPE.Container,
        props = {
            autoSize = false,
            size = v2(rightPaneWidth, contentHeight),
        },
        content = ui.content(rootContent),
    }
end
local function buildPerkPane()
    local perksCol = {}
    local treeViewportContent = nil
    local selectedSkillID = getSelectedSkillID()
    local modApi = getModApi()
    local perks = modApi ~= nil and type(modApi.getPerks) == "function" and modApi.getPerks() or {}
    local treeNodes = modApi ~= nil and type(modApi.getTreeNodesForTab) == "function"
        and modApi.getTreeNodesForTab(selectedSkillID)
        or {}

    if #treeNodes > 0 then
        ensureTreePanInitialized(selectedSkillID, treeNodes)
        local pan = getTreePan(selectedSkillID)
        local viewportSize = v2(TREE_INNER_VIEWPORT_WIDTH, TREE_INNER_VIEWPORT_HEIGHT)
        -- Keep tree node boxes/lines at a fixed pixel footprint so dense trees remain readable
        -- and scrolling doesn't feel overly zoomed on high-resolution displays.
        local nodeHeight = 24
        local lineThickness = 2
        local horizontalLineTexture = ui.texture { path = "textures/menu_thin_border_top.dds" }
        local verticalLineTexture = ui.texture { path = "textures/menu_thin_border_left.dds" }
        local treeOrigin = util.vector2(math.floor(viewportSize.x / 2), math.floor(viewportSize.y / 2))
        local nodeByID = {}

        for _, node in ipairs(treeNodes) do
            nodeByID[node.id] = node
        end

        local treePanLabel = string.format(
            "Tree view (Drag + WASD/Arrows): x=%d y=%d",
            math.floor(pan.x),
            math.floor(pan.y)
        )

        local treeHintRow = {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textDisabled,
            props = {
                text = treePanLabel,
            },
        }

        local treeHintSpacer = {
            type = ui.TYPE.Widget,
            props = { size = v2(1, PERK_UI_BOTTOM_ROW_SPACER_HEIGHT) },
        }

        table.insert(perksCol, treeHintRow)
        table.insert(perksCol, treeHintSpacer)

        local treeCanvasContent = {}

        local function toCanvasPos(node)
            return util.vector2(
                treeOrigin.x + node.x - pan.x,
                treeOrigin.y - node.y - pan.y
            )
        end

        local function addLine(x, y, w, h)
            if w <= 0 or h <= 0 then
                return
            end

            local width = math.max(lineThickness, math.floor(w))
            local height = math.max(lineThickness, math.floor(h))
            local horizontal = width >= height

            table.insert(treeCanvasContent, {
                type = ui.TYPE.Image,
                props = {
                    autoSize = false,
                    position = util.vector2(math.floor(x), math.floor(y)),
                    size = util.vector2(width, height),
                    resource = horizontal and horizontalLineTexture or verticalLineTexture,
                },
                userData = {
                    drawLayer = 0,
                },
            })
        end

        for _, node in ipairs(treeNodes) do
            local childPos = toCanvasPos(node)
            local childTopY = childPos.y - math.floor(nodeHeight / 2)
            for _, reqID in ipairs(node.requires or {}) do
                local parentNode = nodeByID[reqID]
                if parentNode ~= nil then
                    local parentPos = toCanvasPos(parentNode)
                    local parentBottomY = parentPos.y + math.floor(nodeHeight / 2)
                    local middleY = math.floor((parentBottomY + childTopY) / 2)

                    local startY = math.min(parentBottomY, middleY)
                    local vertical1Height = math.abs(middleY - parentBottomY)
                    addLine(parentPos.x, startY, lineThickness, vertical1Height)

                    local leftX = math.min(parentPos.x, childPos.x)
                    local horizontalWidth = math.abs(childPos.x - parentPos.x)
                    addLine(leftX, middleY, horizontalWidth, lineThickness)

                    local startY2 = math.min(middleY, childTopY)
                    local vertical2Height = math.abs(childTopY - middleY)
                    addLine(childPos.x, startY2, lineThickness, vertical2Height)
                end
            end
        end

        for _, node in ipairs(treeNodes) do
            local perkIndex = findPerkIndexByID(node.id)
            local isSelected = selectedTreeNodeID == node.id or (selectedTreeNodeID == nil and perkIndex > 0 and perkIndex == selectedPerkIndex)
            local owned = hasPerk(node.id)
            local title = node.title or node.id
            local nodeLabelMaxChars = settings.PERK_UI_TREE_NODE_MAX_LABEL_CHARS or 20
            local nodeLabel = truncateLabel(title, nodeLabelMaxChars)

            local buttonSize = util.vector2(isSelected and 174 or 162, 22)
            local borderPadding = 2
            local outerSize = util.vector2(buttonSize.x + borderPadding * 2, buttonSize.y + borderPadding * 2)
            local nodePos = toCanvasPos(node)

            local nodeButton = createBoxedButton(nodeLabel, function()
                selectedTreeNodeID = node.id
                selectedPerkIndex = perkIndex
                menu.layout = buildLayout()
                menu:update()
            end, buttonSize, 1, owned and interfaces.MWUI.templates.textHeader or interfaces.MWUI.templates.textNormal)
            nodeButton.template = owned and interfaces.MWUI.templates.boxSolid or interfaces.MWUI.templates.boxSolidThick

            table.insert(treeCanvasContent, {
                type = ui.TYPE.Container,
                template = interfaces.MWUI.templates.borders,
                props = {
                    autoSize = false,
                    position = util.vector2(
                        math.floor(nodePos.x - outerSize.x / 2),
                        math.floor(nodePos.y - outerSize.y / 2)
                    ),
                    size = outerSize,
                },
                userData = {
                    drawLayer = 1,
                },
                content = ui.content { nodeButton },
            })
        end

        table.insert(perksCol, {
            type = ui.TYPE.Container,
            props = {
                autoSize = false,
                size = viewportSize,
                clip = true,
            },
            content = ui.content {
                {
                    type = ui.TYPE.Container,
                    props = {
                        autoSize = false,
                        relativeSize = util.vector2(1, 1),
                    },
                    content = ui.content(treeCanvasContent),
                },
            },
        })
    else
        activeTreeCanvasLayout = nil
        activeTreeCanvasSkillID = nil
        for i, perkID in ipairs(filteredPerkIDs) do
            local perk = perks[perkID]
            local owned = hasPerk(perkID)
            local isSelected = i == selectedPerkIndex
            if perk ~= nil then
                table.insert(perksCol, {
                    type = ui.TYPE.Text,
                    template = isSelected and interfaces.MWUI.templates.textHeader
                        or (owned and interfaces.MWUI.templates.textHeader or interfaces.MWUI.templates.textNormal),
                    events = {
                        mouseClick = async:callback(function()
                            selectedTreeNodeID = nil
                            selectedPerkIndex = i
                            menu.layout = buildLayout()
                            menu:update()
                        end),
                    },
                    props = {
                        text = string.format("%s (cost %d)", perkID, perk.cost),
                    }
                })
            end
        end
    end

    local skillName = selectedSkillID ~= nil and getSkillLabel(selectedSkillID) or "Unknown Tab"
    local skillDescription = "Perks registered under this tab."
    if modApi ~= nil and type(modApi.getTabDescription) == "function" then
        local description = modApi.getTabDescription(selectedSkillID)
        if type(description) == "string" and description ~= "" then
            skillDescription = description
        end
    end

    local selectedPerkID = selectedPerkIndex > 0 and filteredPerkIDs[selectedPerkIndex] or nil
    if selectedPerkID == nil and selectedTreeNodeID ~= nil then
        selectedPerkID = selectedTreeNodeID
    end

    local rightPaneWidth = PERK_UI_RIGHT_PANE_WIDTH + PERK_UI_BODY_RIGHT_EXPANSION
    local selectedPerk = selectedPerkID ~= nil and perks[selectedPerkID] or nil
    local selectedNode = selectedPerkID ~= nil and modApi ~= nil and type(modApi.getTreeNode) == "function"
        and modApi.getTreeNode(selectedPerkID)
        or nil

    local showFullPerkDetails = selectedTreeNodeID ~= nil or #treeNodes == 0
    local perkDetail = buildPerkDetailPane(selectedPerkID, selectedPerk, selectedNode, skillName, skillDescription, rightPaneWidth, showFullPerkDetails)

    return {
        type = ui.TYPE.Flex,
        template = interfaces.MWUI.templates.borders,
        props = {
            horizontal = false,
            size = v2(PERK_UI_BODY_WIDTH, PERK_UI_HEIGHT),
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = v2(PERK_UI_BODY_WIDTH, PERK_UI_CONTENT_HEIGHT),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(PERK_UI_SIDE_PADDING, 1) },
                    },
                    {
                        type = ui.TYPE.Flex,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            horizontal = false,
                            autoSize = false,
                            size = v2(PERK_UI_LEFT_PANE_WIDTH, PERK_UI_CONTENT_HEIGHT),
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
                        content = ui.content(perksCol),
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(PERK_UI_GUTTER_WIDTH, 1) },
                    },
                    {
                        type = ui.TYPE.Flex,
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            horizontal = false,
                            autoSize = false,
                            size = v2(rightPaneWidth, PERK_UI_CONTENT_HEIGHT),
                        },
                        content = ui.content { perkDetail },
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(PERK_UI_SIDE_PADDING, 1) },
                    },
                }
            },
            {
                type = ui.TYPE.Widget,
                props = { size = v2(1, PERK_UI_BOTTOM_ROW_SPACER_HEIGHT) },
            },
            {
                type = ui.TYPE.Flex,
                props = {
                    horizontal = true,
                    autoSize = false,
                    size = v2(PERK_UI_BODY_WIDTH, PERK_UI_BOTTOM_ROW_HEIGHT),
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
                            end, v2(64, 28)),
                        },
                    },
                    {
                        type = ui.TYPE.Widget,
                        props = { size = v2(8, 1) },
                    },
                }
            }
        }
    }
end

buildLayout = function()
    local menuWidth = PERK_UI_BODY_WIDTH
    local menuHeight = 30 + PERK_UI_BOTTOM_ROW_HEIGHT + 10 + PERK_UI_HEIGHT
    local topHeaderFillTiles = {}
    for _ = 1, math.max(1, math.ceil(menuWidth / 20)) do
        table.insert(topHeaderFillTiles, {
            type = ui.TYPE.Image,
            props = {
                resource = ui.texture { path = "textures\\menu_head_block_middle.dds" },
                size = v2(20, 30),
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
            autoSize = false,
            size = v2(menuWidth, menuHeight),
        },
        content = ui.content {
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = false,
                    size = v2(menuWidth, menuHeight),
                },
                content = ui.content {
                    {
                        type = ui.TYPE.Container,
                        template = interfaces.MWUI.templates.boxTransparentThick,
                        props = {
                            autoSize = false,
                            size = v2(menuWidth, 30),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Flex,
                                props = {
                                    horizontal = true,
                                    autoSize = false,
                                    size = v2(menuWidth, 30),
                                },
                                content = ui.content(topHeaderFillTiles),
                            },
                            {
                                type = ui.TYPE.Flex,
                                props = {
                                    horizontal = true,
                                    autoSize = false,
                                    size = v2(menuWidth, 30),
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
                                            size = v2(180, 24),
                                        },
                                        content = ui.content {
                                            {
                                                type = ui.TYPE.Text,
                                                template = interfaces.MWUI.templates.textHeader,
                                                props = {
                                                    text = "Skill Perks",
                                                    autoSize = false,
                                                    size = v2(180, 24),
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
                            size = v2(menuWidth, PERK_UI_BOTTOM_ROW_HEIGHT),
                        },
                        content = ui.content {
                            {
                                type = ui.TYPE.Widget,
                                props = { size = v2(PERK_UI_SIDE_PADDING, 1) },
                            },
                            buildGlobalPointsDisplay(),
                            {
                                type = ui.TYPE.Widget,
                                props = { size = v2(8, 1) },
                            },
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
                        props = { size = v2(1, 10) },
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
    refreshLayoutMetrics()
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
    lastKnownGlobalPoints = getCurrentGlobalPoints(getSelectedSkillID())
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
    optimisticPerkEffectEnabledByID = {}
    lastKnownGlobalPoints = nil
end

local function toggleMenu()
    if menu == nil then
        showMenu()
    else
        closeMenu()
    end
end

local function hasOpenMenuMode()
    local ok, mode = pcall(function()
        return interfaces.UI.getMode()
    end)
    if not ok then
        return false
    end
    return mode ~= nil and mode ~= ""
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

local function onUiModeChanged(data)
    if type(data) ~= "table" then
        return
    end

    -- If any non-nil mode just closed, wait until the toggle key is released
    -- before allowing the perk menu to open from keyboard input again.
    if data.oldMode ~= nil and data.newMode == nil then
        suppressToggleUntilRelease = true
    end
end

local function onFrame(dt)
    if menu ~= nil then
        local playerApi = interfaces[MOD_NAME .. "Player"]
        if playerApi ~= nil then
            local globalPoints = getCurrentGlobalPoints(getSelectedSkillID())

            if type(globalPoints) == "number" and globalPoints ~= lastKnownGlobalPoints then
                lastKnownGlobalPoints = globalPoints
                menu.layout = buildLayout()
                menu:update()
            end
        end

        local modApi = getModApi()
        local selectedSkillID = getSelectedSkillID()
        local treeNodes = modApi ~= nil and type(modApi.getTreeNodesForTab) == "function"
            and modApi.getTreeNodesForTab(selectedSkillID)
            or {}

        if #treeNodes > 0 then
            local pan = getTreePan(selectedSkillID)
            local panDelta = 320 * dt
            local moved = false
            updateTreePanBounds(selectedSkillID, treeNodes)
            local leftDown = anyKeyDown({"LeftArrow", "Left", "A"})
            local rightDown = anyKeyDown({"RightArrow", "Right", "D"})
            local upDown = anyKeyDown({"UpArrow", "Up", "W"})
            local downDown = anyKeyDown({"DownArrow", "Down", "S"})

            if leftDown or rightDown or upDown or downDown then
                print(string.format("[%s][DEBUG] onFrame keys L=%s R=%s U=%s D=%s dt=%.4f panDelta=%.2f", MOD_NAME, tostring(leftDown), tostring(rightDown), tostring(upDown), tostring(downDown), dt, panDelta))
            end

            if leftDown then
                pan.x = pan.x - panDelta
                moved = true
            end
            if rightDown then
                pan.x = pan.x + panDelta
                moved = true
            end
            if upDown then
                pan.y = pan.y - panDelta
                moved = true
            end
            if downDown then
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

    refreshToggleKeyBinding()
    local hasOpenMenuModeNow = hasOpenMenuMode()
    local isPressed = input.isKeyPressed(activeToggleKeyCode)
    if not isPressed then
        suppressToggleUntilRelease = false
    end
    if isPressed and not toggleKeyWasPressed then
        if menu ~= nil then
            toggleMenu()
        elseif not hasOpenMenuModeNow and not suppressToggleUntilRelease then
            toggleMenu()
        end
    end
    toggleKeyWasPressed = isPressed
    hadOpenMenuModeLastFrame = hasOpenMenuModeNow
end

return {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        [MOD_NAME .. "togglePerkUI"] = toggleMenu,
        [MOD_NAME .. "showPerkUI"] = showMenu,
        [MOD_NAME .. "closePerkUI"] = closeMenu,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onFrame = onFrame,
    }
}
