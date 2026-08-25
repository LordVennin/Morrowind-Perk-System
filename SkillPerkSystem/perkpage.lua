local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")
local ambient = require("openmw.ambient")
local interfaces = require("openmw.interfaces")
local input = require("openmw.input")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME
-- OpenMW only accepts built-in mode ids for UI.addMode/removeMode.
local PERK_UI_MODE_ID = "Journal"

local activeToggleKeyName = nil
local activeToggleKeyCode = input.KEY.P
local toggleKeyWasPressed = false
local suppressToggleUntilRelease = false
local ENABLE_UI_CLOSE_DEBUG_LOGS = true
local SUPPRESS_JOURNAL_SOUND_EFFECTS = true
local JOURNAL_OPEN_SOUND_SUPPRESSION_WINDOW_SECONDS = 0.35
local JOURNAL_CLOSE_SOUND_SUPPRESSION_WINDOW_SECONDS = 0.45

local TOGGLE_KEY_REFRESH_INTERVAL = 0.5
local toggleKeyRefreshTimer = TOGGLE_KEY_REFRESH_INTERVAL

-- Reads player settings storage, so run it on a slow cadence instead of once
-- per rendered frame.
local function refreshToggleKeyBindingThrottled(dt)
    toggleKeyRefreshTimer = toggleKeyRefreshTimer + (tonumber(dt) or 0)
    if toggleKeyRefreshTimer < TOGGLE_KEY_REFRESH_INTERVAL then
        return false
    end
    toggleKeyRefreshTimer = 0
    return true
end

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

local PAN_LEFT_KEYS = {"LeftArrow", "Left", "A"}
local PAN_RIGHT_KEYS = {"RightArrow", "Right", "D"}
local PAN_UP_KEYS = {"UpArrow", "Up", "W"}
local PAN_DOWN_KEYS = {"DownArrow", "Down", "S"}

local GLOBAL_POINTS_POLL_INTERVAL = 0.25
local globalPointsPollTimer = GLOBAL_POINTS_POLL_INTERVAL
-- The perk menu opens a paused UI mode, and onFrame receives dt == 0 while the
-- game is paused -- so UI timers advance by this nominal frame length whenever
-- dt is zero, or they would freeze exactly while the menu is on screen.
local PAUSED_FRAME_SECONDS = 1 / 60
-- Frames left before a rebuild forced by a perk purchase. The addPerk event is
-- delivered to the player script a frame after the click, so the click-time
-- rebuild is always stale; counting frames (not dt) survives the pause.
local pendingPerkStateRebuildFrames = 0

-- input.KEY lookups are constant; resolving them per key per frame allocated a
-- closure and a pcall each time. Resolve once and remember misses as false.
local resolvedKeyCodes = {}

local function keyCodeFor(keyName)
    local cached = resolvedKeyCodes[keyName]
    if cached == nil then
        local ok, code = pcall(function()
            return input.KEY[keyName]
        end)
        cached = (ok and code ~= nil) and code or false
        resolvedKeyCodes[keyName] = cached
    end
    return cached
end

local function keyDown(keyName)
    local code = keyCodeFor(keyName)
    return code ~= false and input.isKeyPressed(code)
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
local perkModeOwned = false
local interfaceDepthBeforeOpen = 0
local isClosingMenu = false
local didForceUiModeReset = false
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
local journalOpenSoundSuppressionRemaining = 0
local journalCloseSoundSuppressionRemaining = 0

local uiScale = 1

-- Live references into the current menu layout. Panning the tree mutates the
-- canvas container's position in place rather than rebuilding the whole menu,
-- so these are refreshed whenever buildPerkPane() runs.
local activeTreeCanvasLayout = nil
local activeTreeCanvasSkillID = nil
local activeTreePanLabelLayout = nil
-- Offset added to every canvas child so all coordinates are non-negative.
-- MyGUI crops children to their parent's rect, so a child at a negative
-- coordinate inside the canvas is culled outright; the canvas is therefore
-- sized to the full content bounds and moved as a whole instead.
local activeTreeCanvasShift = nil

-- ui.texture allocates a fresh resource handle per call, and the layout used to
-- be rebuilt on every pan frame. These paths are constant, so resolve once.
local cachedTexturesByPath = {}
local function cachedTexture(path)
    local texture = cachedTexturesByPath[path]
    if texture == nil then
        texture = ui.texture { path = path }
        cachedTexturesByPath[path] = texture
    end
    return texture
end

local function safeMenuUpdate()
    if menu == nil or type(menu.update) ~= "function" then
        return
    end

    local ok, err = pcall(menu.update, menu)
    if not ok then
        print("[" .. MOD_NAME .. "] menu:update skipped: " .. tostring(err))
    end
end

local function getCurrentUiMode()
    local ok, mode = pcall(function()
        return interfaces.UI.getMode()
    end)
    if not ok then
        return "<getMode-error>"
    end
    return tostring(mode)
end

local function getInterfaceModeDepthForLog()
    local uiModes = interfaces.UI.modes
    if type(uiModes) ~= "table" then
        return 0
    end
    local depth = 0
    for _, mode in pairs(uiModes) do
        if mode == PERK_UI_MODE_ID then
            depth = depth + 1
        end
    end
    return depth
end

local function logUiDebug(message)
    if not ENABLE_UI_CLOSE_DEBUG_LOGS then
        return
    end
    print(string.format(
        "[%s][UI-DEBUG] %s | mode=%s owned=%s beforeDepth=%s interfaceDepth=%s menu=%s closing=%s",
        MOD_NAME,
        message,
        getCurrentUiMode(),
        tostring(perkModeOwned),
        tostring(interfaceDepthBeforeOpen),
        tostring(getInterfaceModeDepthForLog()),
        tostring(menu ~= nil),
        tostring(isClosingMenu)
    ))
end

local function suppressJournalOpenUiSounds()
    if not SUPPRESS_JOURNAL_SOUND_EFFECTS then
        return
    end
    if PERK_UI_MODE_ID ~= "Journal" then
        return
    end

    pcall(function()
        ambient.stopSound("book open")
        ambient.stopSound("book page")
        ambient.stopSound("book page2")
    end)
end

local function suppressJournalCloseUiSounds()
    if not SUPPRESS_JOURNAL_SOUND_EFFECTS then
        return
    end
    if PERK_UI_MODE_ID ~= "Journal" then
        return
    end

    pcall(function()
        ambient.stopSound("book close")
        ambient.stopSound("book page")
        ambient.stopSound("book page2")
    end)
end

local function beginJournalOpenSoundSuppressionWindow()
    if not SUPPRESS_JOURNAL_SOUND_EFFECTS then
        return
    end
    if PERK_UI_MODE_ID ~= "Journal" then
        return
    end

    journalOpenSoundSuppressionRemaining = math.max(
        journalOpenSoundSuppressionRemaining or 0,
        JOURNAL_OPEN_SOUND_SUPPRESSION_WINDOW_SECONDS
    )
    suppressJournalOpenUiSounds()
end

local function beginJournalCloseSoundSuppressionWindow()
    if not SUPPRESS_JOURNAL_SOUND_EFFECTS then
        return
    end
    if PERK_UI_MODE_ID ~= "Journal" then
        return
    end

    journalCloseSoundSuppressionRemaining = math.max(
        journalCloseSoundSuppressionRemaining or 0,
        JOURNAL_CLOSE_SOUND_SUPPRESSION_WINDOW_SECONDS
    )
    suppressJournalCloseUiSounds()
end

-- Backward-compat shim:
-- Some existing callbacks/hot-reload states may still reference the old helper name.
-- Keep a safe alias so legacy call sites do not hard-error.
local function beginJournalSoundSuppressionWindow()
    beginJournalOpenSoundSuppressionWindow()
    beginJournalCloseSoundSuppressionWindow()
end
_G.beginJournalSoundSuppressionWindow = beginJournalSoundSuppressionWindow


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

-- Header fill strip: fresh layout tables each call (they are handed to
-- ui.content, so they are not shared between elements) but one shared texture.
local function headerFillTiles(count)
    local texture = cachedTexture("textures\\menu_head_block_middle.dds")
    local tiles = {}
    for _ = 1, count do
        table.insert(tiles, {
            type = ui.TYPE.Image,
            props = {
                resource = texture,
                size = v2(20, 30),
            },
        })
    end
    return tiles
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

local function countInterfaceModeDepth()
    local uiModes = interfaces.UI.modes
    if type(uiModes) ~= "table" then
        return 0
    end

    local function getModeId(entry)
        if type(entry) == "string" then
            return entry
        end
        if type(entry) == "table" then
            if type(entry.mode) == "string" then
                return entry.mode
            end
            if type(entry.id) == "string" then
                return entry.id
            end
            if type(entry.name) == "string" then
                return entry.name
            end
        end
        return nil
    end

    local depth = 0
    for key, value in pairs(uiModes) do
        if key == PERK_UI_MODE_ID and type(value) == "number" then
            depth = depth + value
        elseif key == PERK_UI_MODE_ID and value == true then
            depth = math.max(depth, 1)
        elseif getModeId(value) == PERK_UI_MODE_ID or getModeId(key) == PERK_UI_MODE_ID then
            depth = depth + 1
        end
    end
    return depth
end

local function releaseOwnedInterfaceMode(forceRelease, allowFallbackRemove)
    if not forceRelease and not perkModeOwned then
        return true
    end

    local currentDepth = countInterfaceModeDepth()
    if currentDepth <= interfaceDepthBeforeOpen then
        if not allowFallbackRemove then
            return true
        end
        interfaces.UI.removeMode(PERK_UI_MODE_ID)
        return countInterfaceModeDepth() <= interfaceDepthBeforeOpen
    end

    local targetDepth = math.max(interfaceDepthBeforeOpen, currentDepth - 1)
    local removedAny = false
    while currentDepth > targetDepth do
        interfaces.UI.removeMode(PERK_UI_MODE_ID)
        removedAny = true
        local updatedDepth = countInterfaceModeDepth()
        if updatedDepth >= currentDepth then
            break
        end
        currentDepth = updatedDepth
    end

    if not removedAny and allowFallbackRemove then
        interfaces.UI.removeMode(PERK_UI_MODE_ID)
    end

    return countInterfaceModeDepth() <= interfaceDepthBeforeOpen
end

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

local function treePanLabelText(pan)
    return string.format(
        "Tree view (Drag + WASD/Arrows): x=%d y=%d",
        math.floor(pan.x),
        math.floor(pan.y)
    )
end

local function treeCanvasPosition(pan, shift)
    return util.vector2(
        -math.floor(pan.x) - shift.x,
        -math.floor(pan.y) - shift.y
    )
end

-- Move the tree canvas to match the current pan without rebuilding the layout.
-- Returns false when there is no live canvas for the selected skill, in which
-- case the caller still needs a full rebuild.
local function applyTreePanOffset()
    if menu == nil or activeTreeCanvasLayout == nil then
        return false
    end

    local skillID = getSelectedSkillID()
    if skillID == nil or skillID ~= activeTreeCanvasSkillID then
        return false
    end

    if activeTreeCanvasShift == nil then
        return false
    end

    local pan = getTreePan(skillID)
    activeTreeCanvasLayout.props.position = treeCanvasPosition(pan, activeTreeCanvasShift)
    if activeTreePanLabelLayout ~= nil then
        activeTreePanLabelLayout.props.text = treePanLabelText(pan)
    end

    safeMenuUpdate()
    return true
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

local function getAnyParentRequirementLabel(parentIDs)
    local labels = {}
    for _, parentID in ipairs(parentIDs or {}) do
        local modApi = getModApi()
        local label = tostring(parentID)
        if modApi ~= nil and type(modApi.getTreeNode) == "function" then
            local parentNode = modApi.getTreeNode(parentID)
            if parentNode ~= nil and type(parentNode.title) == "string" and parentNode.title ~= "" then
                label = parentNode.title
            end
        end
        table.insert(labels, label)
    end
    return table.concat(labels, " or ")
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

    local requiresAny = node.requiresAny or {}
    if #requiresAny > 0 then
        local anyOwned = false
        for _, requiredID in ipairs(requiresAny) do
            if hasPerk(requiredID) then
                anyOwned = true
                break
            end
        end
        if not anyOwned then
            table.insert(missing, "ANY:" .. table.concat(requiresAny, "|"))
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
                    safeMenuUpdate()
                end
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 then
                    buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                    textLayout.template = interfaces.MWUI.templates.textNormal
                    safeMenuUpdate()
                    onPress()
                end
            end),
            focusGain = async:callback(function()
                buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                textLayout.template = interfaces.MWUI.templates.textHeader
                safeMenuUpdate()
            end),
            focusLoss = async:callback(function()
                buttonLayout.template = interfaces.MWUI.templates.boxTransparentThick
                textLayout.template = interfaces.MWUI.templates.textNormal
                safeMenuUpdate()
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
                safeMenuUpdate()
            end
        end),
        mouseRelease = async:callback(function(mouseEvent)
            if mouseEvent.button == 1 then
                textLayout.template = idleTextTemplate
                safeMenuUpdate()
                onPress()
            end
        end),
        focusGain = async:callback(function()
            textLayout.template = interfaces.MWUI.templates.textHeader
            safeMenuUpdate()
        end),
        focusLoss = async:callback(function()
            textLayout.template = idleTextTemplate
            safeMenuUpdate()
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
        safeMenuUpdate()
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
    local safeMaxChars = math.max(1, math.floor(tonumber(maxChars) or 1))

    local function flushWord(word)
        local remaining = tostring(word or "")
        while #remaining > safeMaxChars do
            table.insert(lines, remaining:sub(1, safeMaxChars - 1) .. "-")
            remaining = remaining:sub(safeMaxChars)
        end
        return remaining
    end

    for paragraph in tostring(text or ""):gmatch("[^\n]+") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            local normalizedWord = flushWord(word)
            local candidate = (line == "") and normalizedWord or (line .. " " .. normalizedWord)
            if #candidate > safeMaxChars and line ~= "" then
                table.insert(lines, line)
                line = normalizedWord
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
    local safeMinChars = math.max(4, tonumber(minChars) or 4)
    local usablePixelWidth = math.max(1, px(tonumber(usableTextWidth) or 0))
    local approxCharWidth = math.max(1, px(tonumber(settings.PERK_UI_WRAP_AVG_CHAR_WIDTH) or 8))
    local wrapWidthSafety = clamp(tonumber(settings.PERK_UI_WRAP_WIDTH_SAFETY) or 0.9, 0.6, 1.0)
    local safeWrapWidth = math.max(1, math.floor(usablePixelWidth * wrapWidthSafety))
    local estimatedChars = math.floor((safeWrapWidth + math.floor(approxCharWidth * 0.5)) / approxCharWidth)
    return math.max(safeMinChars, estimatedChars)
end

local function truncateToPixelWidth(text, pixelWidth, minChars)
    local maxChars = estimateWrapMaxChars(pixelWidth, minChars or 8)
    return truncateLabel(text, maxChars)
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
    local descriptionWrapMaxChars = estimateWrapMaxChars(descriptionTextWidth, 8)
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

    local displayedTitle = truncateToPixelWidth(title, titleWidth - px(10), 10)
    local displayedSkillName = truncateToPixelWidth(skillName, titleWidth - px(10), 10)

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
                                        text = displayedSkillName,
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
    if node ~= nil and type(node.requiresAny) == "table" and #node.requiresAny > 0 then
        local anyOwned = false
        for _, parentID in ipairs(node.requiresAny) do
            if hasPerk(parentID) then
                anyOwned = true
                break
            end
        end
        table.insert(requirementRows, {
            label = getAnyParentRequirementLabel(node.requiresAny),
            met = anyOwned,
        })
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
                                text = truncateToPixelWidth(req.label, leftColumnWidth - (requirementInset * 4), 12),
                                autoSize = false,
                                size = v2(leftColumnWidth - (requirementInset * 4), requirementRowHeight),
                                textAlignH = ui.ALIGNMENT.Start,
                                textAlignV = ui.ALIGNMENT.Center,
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
                safeMenuUpdate()
                -- The purchase lands in the player script a frame later, so
                -- the rebuild above still shows the pre-purchase state.
                pendingPerkStateRebuildFrames = 2
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
                safeMenuUpdate()
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
                                text = displayedTitle,
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
        -- Bounds clamping used to ride along on the per-frame pan handler. Now
        -- that panning no longer rebuilds, clamp here so a rebuild (tab switch,
        -- perk purchase) still lands inside the tab's content bounds.
        updateTreePanBounds(selectedSkillID, treeNodes)
        local pan = getTreePan(selectedSkillID)
        local viewportSize = v2(TREE_INNER_VIEWPORT_WIDTH, TREE_INNER_VIEWPORT_HEIGHT)
        -- Keep tree node boxes/lines at a fixed pixel footprint so dense trees remain readable
        -- and scrolling doesn't feel overly zoomed on high-resolution displays.
        local nodeHeight = 24
        local lineThickness = 2
        local horizontalLineTexture = cachedTexture("textures/menu_thin_border_top.dds")
        local verticalLineTexture = cachedTexture("textures/menu_thin_border_left.dds")
        local treeOrigin = util.vector2(math.floor(viewportSize.x / 2), math.floor(viewportSize.y / 2))
        local nodeByID = {}

        for _, node in ipairs(treeNodes) do
            nodeByID[node.id] = node
        end

        local treeHintRow = {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textDisabled,
            props = {
                text = treePanLabelText(pan),
            },
        }
        activeTreePanLabelLayout = treeHintRow

        local treeHintSpacer = {
            type = ui.TYPE.Widget,
            props = { size = v2(1, PERK_UI_BOTTOM_ROW_SPACER_HEIGHT) },
        }

        table.insert(perksCol, treeHintRow)
        table.insert(perksCol, treeHintSpacer)

        local treeCanvasContent = {}

        -- Node positions are relative to the canvas, not to the current pan. The
        -- canvas container is offset instead, so panning never rebuilds nodes.
        local function toCanvasPos(node)
            return util.vector2(
                treeOrigin.x + node.x,
                treeOrigin.y - node.y
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
            local parentIDs = {}
            for _, reqID in ipairs(node.requires or {}) do
                table.insert(parentIDs, reqID)
            end
            for _, reqID in ipairs(node.requiresAny or {}) do
                table.insert(parentIDs, reqID)
            end
            for _, reqID in ipairs(parentIDs) do
                local parentNode = nodeByID[reqID]
                if parentNode ~= nil then
                    local parentPos = toCanvasPos(parentNode)
                    local halfNodeHeight = math.floor(nodeHeight / 2)
                    local parentEdgeY
                    local childEdgeY

                    if childPos.y < parentPos.y then
                        parentEdgeY = parentPos.y - halfNodeHeight
                        childEdgeY = childPos.y + halfNodeHeight
                    else
                        parentEdgeY = parentPos.y + halfNodeHeight
                        childEdgeY = childPos.y - halfNodeHeight
                    end

                    local middleY = math.floor((parentEdgeY + childEdgeY) / 2)

                    local startY = math.min(parentEdgeY, middleY)
                    local vertical1Height = math.abs(middleY - parentEdgeY)
                    addLine(parentPos.x, startY, lineThickness, vertical1Height)

                    local leftX = math.min(parentPos.x, childPos.x)
                    local horizontalWidth = math.abs(childPos.x - parentPos.x)
                    addLine(leftX, middleY, horizontalWidth, lineThickness)

                    local startY2 = math.min(middleY, childEdgeY)
                    local vertical2Height = math.abs(childEdgeY - middleY)
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
                safeMenuUpdate()
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

        -- Children above or left of the tree origin have negative coordinates
        -- at this point. Shift everything so the minimum is zero and size the
        -- canvas to the content bounds: MyGUI crops children to their parent's
        -- rect, so a child at a negative coordinate would never render.
        --
        -- The bounds are padded because that cropping is inclusive of the edge:
        -- a node box sitting exactly on the canvas boundary loses the border
        -- drawn on that side. Without the padding the outermost column of any
        -- tree wider than the viewport renders with one border missing.
        local canvasEdgePadding = 8
        local contentMinX, contentMinY = 0, 0
        local contentMaxX, contentMaxY = viewportSize.x, viewportSize.y
        for _, child in ipairs(treeCanvasContent) do
            local childPosition = child.props.position
            local childSize = child.props.size
            contentMinX = math.min(contentMinX, childPosition.x - canvasEdgePadding)
            contentMinY = math.min(contentMinY, childPosition.y - canvasEdgePadding)
            contentMaxX = math.max(contentMaxX, childPosition.x + childSize.x + canvasEdgePadding)
            contentMaxY = math.max(contentMaxY, childPosition.y + childSize.y + canvasEdgePadding)
        end
        local canvasShift = util.vector2(-contentMinX, -contentMinY)
        for _, child in ipairs(treeCanvasContent) do
            local childPosition = child.props.position
            child.props.position = util.vector2(
                childPosition.x + canvasShift.x,
                childPosition.y + canvasShift.y
            )
        end

        local treeCanvas = {
            type = ui.TYPE.Widget,
            props = {
                autoSize = false,
                size = util.vector2(
                    contentMaxX - contentMinX,
                    contentMaxY - contentMinY
                ),
                position = treeCanvasPosition(pan, canvasShift),
            },
            content = ui.content(treeCanvasContent),
        }
        activeTreeCanvasLayout = treeCanvas
        activeTreeCanvasSkillID = selectedSkillID
        activeTreeCanvasShift = canvasShift

        table.insert(perksCol, {
            type = ui.TYPE.Container,
            props = {
                autoSize = false,
                size = viewportSize,
                clip = true,
            },
            content = ui.content { treeCanvas },
        })
    else
        activeTreeCanvasLayout = nil
        activeTreeCanvasSkillID = nil
        activeTreePanLabelLayout = nil
        activeTreeCanvasShift = nil
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
                            safeMenuUpdate()
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
                                if not applyTreePanOffset() then
                                    menu.layout = buildLayout()
                                    safeMenuUpdate()
                                end
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
    local topHeaderFillTiles = headerFillTiles(math.max(1, math.ceil(menuWidth / 20)))

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
    logUiDebug("showMenu:start")
    refreshLayoutMetrics()
    skillIDs = getSkillIDs()
    selectedSkillIndex = math.max(1, math.min(selectedSkillIndex, #skillIDs))
    selectedPerkIndex = 0
    selectedTreeNodeID = nil
    updateFilteredPerks()

    interfaceDepthBeforeOpen = countInterfaceModeDepth()
    didForceUiModeReset = false
    local addModeOk, addModeError = pcall(function()
        interfaces.UI.addMode(PERK_UI_MODE_ID, { windows = {} })
    end)
    if not addModeOk then
        print("[" .. MOD_NAME .. "] Failed to add perk UI mode: " .. tostring(addModeError))
        logUiDebug("showMenu:addMode-failed")
        return
    end
    beginJournalOpenSoundSuppressionWindow()

    local ok, createdOrError = pcall(function()
        return ui.create(buildLayout())
    end)

    if not ok then
        print("[" .. MOD_NAME .. "] Failed to create perk UI: " .. tostring(createdOrError))
        releaseOwnedInterfaceMode(true, true)
        logUiDebug("showMenu:create-failed")
        return
    end

    menu = createdOrError
    perkModeOwned = true
    lastKnownGlobalPoints = getCurrentGlobalPoints(getSelectedSkillID())
    logUiDebug("showMenu:success")
end

local function closeMenu(options)
    options = options or {}
    if isClosingMenu then
        return
    end
    isClosingMenu = true

    if menu == nil and not perkModeOwned then
        isClosingMenu = false
        if ENABLE_UI_CLOSE_DEBUG_LOGS then
            logUiDebug("closeMenu:ignored-no-owned-state")
        end
        return
    end

    logUiDebug("closeMenu:start")

    isDraggingTree = false
    lastMousePos = nil
    selectedPerkIndex = 0
    selectedTreeNodeID = nil
    filteredPerkIDs = {}

    if menu ~= nil then
        local ok, err = pcall(function()
            menu:destroy()
        end)
        if not ok then
            print("[" .. MOD_NAME .. "] Failed to destroy perk UI: " .. tostring(err))
        end
        menu = nil
    end

    beginJournalCloseSoundSuppressionWindow()

    local ok, err = pcall(function()
        interfaces.UI.removeMode(PERK_UI_MODE_ID)
    end)
    if not ok then
        print("[" .. MOD_NAME .. "] Failed to remove UI mode: " .. tostring(err))
    end
    beginJournalSoundSuppressionWindow()
    perkModeOwned = false
    interfaceDepthBeforeOpen = 0
    didForceUiModeReset = ok
    optimisticPerkEffectEnabledByID = {}
    lastKnownGlobalPoints = nil
    suppressToggleUntilRelease = true
    isClosingMenu = false
    logUiDebug("closeMenu:done")
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
    if ENABLE_UI_CLOSE_DEBUG_LOGS then
        logUiDebug("UiModeChanged old=" .. tostring(data.oldMode) .. " new=" .. tostring(data.newMode))
    end

    local transitionTouchesJournal = data.oldMode == PERK_UI_MODE_ID or data.newMode == PERK_UI_MODE_ID
    if transitionTouchesJournal and (menu ~= nil or perkModeOwned or isClosingMenu) then
        if data.newMode == PERK_UI_MODE_ID then
            beginJournalOpenSoundSuppressionWindow()
        end
        if data.oldMode == PERK_UI_MODE_ID then
            beginJournalCloseSoundSuppressionWindow()
        end
    end

    if menu ~= nil and data.oldMode == PERK_UI_MODE_ID and data.newMode ~= PERK_UI_MODE_ID then
        if isClosingMenu then
            return
        end
        closeMenu({ allowFallbackModeRemove = false, allowForceSetMode = false })
    end

    -- If any non-nil mode just closed, wait until the toggle key is released
    -- before allowing the perk menu to open from keyboard input again.
    if data.oldMode ~= nil and data.newMode == nil then
        suppressToggleUntilRelease = true
    end
end

local function onFrame(dt)
    local deltaTime = tonumber(dt) or 0

    if journalOpenSoundSuppressionRemaining > 0 then
        suppressJournalOpenUiSounds()
        journalOpenSoundSuppressionRemaining = math.max(0, journalOpenSoundSuppressionRemaining - deltaTime)
    end

    if journalCloseSoundSuppressionRemaining > 0 then
        suppressJournalCloseUiSounds()
        journalCloseSoundSuppressionRemaining = math.max(0, journalCloseSoundSuppressionRemaining - deltaTime)
    end

    if menu ~= nil and not isClosingMenu then
        local ok, currentMode = pcall(function()
            return interfaces.UI.getMode()
        end)
        if not ok or currentMode ~= PERK_UI_MODE_ID then
            closeMenu({ allowFallbackModeRemove = false, allowForceSetMode = false })
            return
        end
    end

    if menu == nil and perkModeOwned then
        local released = releaseOwnedInterfaceMode(false, true)
        if released then
            perkModeOwned = false
            interfaceDepthBeforeOpen = 0
            didForceUiModeReset = false
        elseif not didForceUiModeReset then
            local ok, err = pcall(function()
                interfaces.UI.removeMode(PERK_UI_MODE_ID)
            end)
            if not ok then
                print("[" .. MOD_NAME .. "] Failed to remove UI mode from onFrame: " .. tostring(err))
            end
            perkModeOwned = false
            interfaceDepthBeforeOpen = 0
            didForceUiModeReset = true
        end
    end

    -- dt is 0 while the game is paused, which it is whenever this menu is open.
    local uiDelta = deltaTime > 0 and deltaTime or PAUSED_FRAME_SECONDS

    if menu ~= nil then
        if pendingPerkStateRebuildFrames > 0 then
            pendingPerkStateRebuildFrames = pendingPerkStateRebuildFrames - 1
            if pendingPerkStateRebuildFrames == 0 then
                lastKnownGlobalPoints = getCurrentGlobalPoints(getSelectedSkillID())
                menu.layout = buildLayout()
                safeMenuUpdate()
            end
        end

        -- Point totals only change from outside the menu on level-up or skill
        -- milestones, so polling them a few times a second is responsive enough
        -- and keeps the interface lookup off the per-frame path.
        globalPointsPollTimer = globalPointsPollTimer + uiDelta
        if globalPointsPollTimer >= GLOBAL_POINTS_POLL_INTERVAL then
            globalPointsPollTimer = 0
            local playerApi = interfaces[MOD_NAME .. "Player"]
            if playerApi ~= nil then
                local globalPoints = getCurrentGlobalPoints(getSelectedSkillID())

                if type(globalPoints) == "number" and globalPoints ~= lastKnownGlobalPoints then
                    lastKnownGlobalPoints = globalPoints
                    menu.layout = buildLayout()
                    safeMenuUpdate()
                end
            end
        end

        local panDelta = 320 * uiDelta
        local dx, dy = 0, 0
        if anyKeyDown(PAN_LEFT_KEYS) then
            dx = dx - panDelta
        end
        if anyKeyDown(PAN_RIGHT_KEYS) then
            dx = dx + panDelta
        end
        if anyKeyDown(PAN_UP_KEYS) then
            dy = dy - panDelta
        end
        if anyKeyDown(PAN_DOWN_KEYS) then
            dy = dy + panDelta
        end

        -- Fetching the tab's tree nodes copies and sorts the node list, so only
        -- do it when the player is actually panning.
        if dx ~= 0 or dy ~= 0 then
            local modApi = getModApi()
            local selectedSkillID = getSelectedSkillID()
            local treeNodes = modApi ~= nil and type(modApi.getTreeNodesForTab) == "function"
                and modApi.getTreeNodesForTab(selectedSkillID)
                or {}

            if #treeNodes > 0 then
                local pan = getTreePan(selectedSkillID)
                updateTreePanBounds(selectedSkillID, treeNodes)
                pan.x = pan.x + dx
                pan.y = pan.y + dy
                clampTreePan(pan)
                if not applyTreePanOffset() then
                    menu.layout = buildLayout()
                    safeMenuUpdate()
                end
            end
        end
    end

    if refreshToggleKeyBindingThrottled(uiDelta) then
        refreshToggleKeyBinding()
    end

    local isPressed = input.isKeyPressed(activeToggleKeyCode)
    if not isPressed then
        suppressToggleUntilRelease = false
    end

    if isPressed and not toggleKeyWasPressed then
        if menu ~= nil then
            closeMenu()
        -- hasOpenMenuMode() walks the interface mode stack, so it is only
        -- consulted on the key edge that would actually open the menu.
        elseif not suppressToggleUntilRelease and not hasOpenMenuMode() then
            toggleMenu()
        end
    end
    toggleKeyWasPressed = isPressed
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
