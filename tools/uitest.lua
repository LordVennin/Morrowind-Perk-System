-- Perk UI smoke test. Run from the repository root:
--
--     lua5.4 tools/uitest.lua
--
-- Loads SkillPerkSystem/perkpage.lua against mocked openmw modules and drives
-- the menu-open, per-frame, and close paths. luac -p only catches syntax;
-- this catches the runtime class of bug where a helper references a local
-- declared later in the file and silently resolves to a nil global (the
-- "attempt to call global 'v2'" failure). It exercises layout building end to
-- end, so most nil-field and ordering mistakes in the UI path surface here
-- instead of in game.
local function vec2(x, y)
    return setmetatable({x=x, y=y}, {__sub=function(a,b) return vec2(a.x-b.x, a.y-b.y) end,
                                     __unm=function(a) return vec2(-a.x, -a.y) end})
end

local mocks = {}
mocks["openmw.util"] = { vector2 = vec2 }
mocks["openmw.core"] = {
    stats = { Skill = { records = setmetatable({}, {__index=function(_,k) return {name=k} end}) } },
    sendGlobalEvent = function() end,
    getRealTime = function() return 0 end,
    l10n = function() return function(k) return k end end,
}
local uiContent = function(t) return t end
local lastCreatedLayout = nil
local lastCreatedElement = nil
mocks["openmw.ui"] = {
    TYPE = setmetatable({}, {__index=function(_,k) return k end}),
    ALIGNMENT = setmetatable({}, {__index=function(_,k) return k end}),
    texture = function(t) return t end,
    content = uiContent,
    create = function(layout)
        lastCreatedLayout = layout
        lastCreatedElement = { layout = layout, update = function() end, destroy = function() end }
        return lastCreatedElement
    end,
    showMessage = function() end,
    layers = { indexOf = function() return 1 end },
    screenSize = function() return vec2(1920, 1080) end,
}
mocks["openmw.async"] = { callback = function(_, f) return f end }
setmetatable(mocks["openmw.async"], {__index = {callback = function(_, f) return f end}})
mocks["openmw.ambient"] = { playSound = function() end, stopSound = function() end }
mocks["openmw.input"] = {
    KEY = setmetatable({}, {__index=function(_,k) return k end}),
    isKeyPressed = function() return false end,
    ACTION = {}, isActionPressed = function() return false end,
}
-- Stateful perk ownership and points, mutated only when queued events are
-- delivered -- mimicking the engine's asynchronous event dispatch between the
-- perk page script and the player script.
local ownedPerks = {}
local playerPoints = 3
local eventQueue = {}
local function deliverEvents()
    local queued = eventQueue
    eventQueue = {}
    for _, event in ipairs(queued) do
        if event.name:match("addPerk$") then
            local perkID = event.data.perkID
            if not ownedPerks[perkID] and playerPoints >= 1 then
                ownedPerks[perkID] = true
                playerPoints = playerPoints - 1
            end
        end
    end
end

mocks["openmw.self"] = {
    position = vec2(0,0),
    controls = {},
    sendEvent = function(_, name, data)
        eventQueue[#eventQueue + 1] = { name = name, data = data }
    end,
}
mocks["openmw.storage"] = {
    playerSection = function() return {
        get = function() return nil end,
        asTable = function() return {} end,
        subscribe = function() end,
        setLifeTime = function() end,
        set = function() end,
    } end,
    LIFE_TIME = { GameSession = 1 },
}
mocks["openmw.types"] = { NPC = { stats = { skills = setmetatable({}, {__index=function(_,k)
    return function() return { base = 100, modified = 100, modifier = 0 } end end}) } },
    Actor = { stats = { attributes = {}, dynamic = {} } } }

-- interfaces: MWUI templates + UI modes + the mod APIs perkpage looks up
-- Real tree data: the widest and tallest tree in the pack, so the layout
-- assertions below run against the actual shape shipped to players rather
-- than a hand-made stand-in.
local function widestShippedTree()
    local widest, widestSpan = nil, -1
    local pipe = io.popen('ls SkillPerkSystem_BasePack/perks/*/*.lua')
    for path in pipe:lines() do
        if not path:match("_effect%.lua$") and not path:match("_config%.lua$") then
            local ok, data = pcall(function() return assert(loadfile(path))() end)
            if ok and type(data) == "table" and type(data.perks) == "table" and #data.perks > 0 then
                local minX, maxX = data.perks[1].x, data.perks[1].x
                for _, perk in ipairs(data.perks) do
                    minX = math.min(minX, perk.x)
                    maxX = math.max(maxX, perk.x)
                end
                if maxX - minX > widestSpan then widestSpan = maxX - minX; widest = data.perks end
            end
        end
    end
    pipe:close()
    return assert(widest, "no perk trees found")
end

local treeNodes = widestShippedTree()
local perks = {}
for _, node in ipairs(treeNodes) do
    node.requires = node.requires or {}
    node.requiresAny = node.requiresAny or {}
    perks[node.id] = { cost = node.cost or 1 }
end
local template = setmetatable({}, {__index=function(_,k) return {name=k} end})
local currentMode = nil
mocks["openmw.interfaces"] = setmetatable({
    MWUI = { templates = template },
    UI = {
        getMode = function() return currentMode end,
        setMode = function(m) currentMode = m end,
        addMode = function(m) currentMode = m end,
        removeMode = function() currentMode = nil end,
        modes = {},
        registerWindow = function() end,
    },
    Settings = { registerPage = function() end, registerGroup = function() end,
                 updateRendererArgument = function() end },
    SkillPerkSystem = {
        getPerks = function() return perks end,
        getTreeNodesForTab = function() return treeNodes end,
        getTreeNode = function(id) for _,n in ipairs(treeNodes) do if n.id==id then return n end end end,
        getTabDescription = function() return "desc" end,
        getSkillIDs = function() return { "athletics" } end,
        getRegisteredTabs = function() return { "athletics" } end,
    },
    SkillPerkSystemPlayer = {
        hasPerk = function(id) return ownedPerks[id] == true end,
        isPerkEffectEnabled = function(id) return ownedPerks[id] == true end,
        globalAvailablePoints = function() return playerPoints end,
        availablePoints = function() return playerPoints end,
        getGlobalPoints = function() return playerPoints end,
        getPoints = function() return playerPoints end,
        listOwnedPerks = function() return {} end,
    },
}, {__index=function(_,k) return nil end})

package.path = "./?.lua;" .. package.path
local realRequire = require
_G.require = function(name)
    if mocks[name] then return mocks[name] end
    if name:match("^openmw") then error("unmocked openmw module: " .. name) end
    -- map script module names to files
    local file = name:gsub("^scripts%.", ""):gsub("%.", "/") .. ".lua"
    local chunk = assert(loadfile(file))
    return chunk()
end
_G.print = function() end  -- silence mod logging

local page = assert(loadfile("SkillPerkSystem/perkpage.lua"))()
assert(type(page) == "table" and page.eventHandlers, "perkpage returned no handlers")

-- find the show/close/toggle handlers regardless of MOD_NAME prefix
local show, close
for name, fn in pairs(page.eventHandlers) do
    if name:match("showPerkUI$") then show = fn end
    if name:match("closePerkUI$") then close = fn end
end
assert(show and close, "show/close handlers not found")

-- The perk menu opens a paused UI mode: the engine passes dt == 0 to onFrame
-- for every frame the menu is on screen. Model that faithfully -- timers that
-- accumulate dt freeze exactly while the menu is open, which is how the
-- "Unlock Perk button never updates" regression escaped the earlier test.
local PAUSED = 0

show()                                   -- exercises buildLayout end to end
assert(currentMode ~= nil, "menu did not claim a UI mode")

-- MyGUI crops children to their parent's rect, so tree content (connector
-- lines and node boxes, marked with userData.drawLayer) must sit at
-- non-negative coordinates inside a parent large enough to contain it --
-- otherwise it silently vanishes in game (the "top half of the tree missing"
-- bug). The canvas itself may have a negative position: that is ordinary
-- scrolling, cropped by the viewport. Also count the node boxes so a missing
-- node fails the test.
local nodeBoxes = 0
local function walkLayout(node, parent, path)
    if type(node) ~= "table" then return end
    local props = node.props
    if type(node.userData) == "table" and node.userData.drawLayer ~= nil then
        assert(props.position.x >= 0 and props.position.y >= 0,
            string.format("tree content at negative position (%s, %s) at %s",
                tostring(props.position.x), tostring(props.position.y), path))
        local parentSize = parent and parent.props and parent.props.size
        if parentSize then
            assert(props.position.x + props.size.x <= parentSize.x
                    and props.position.y + props.size.y <= parentSize.y,
                string.format("tree content exceeds its canvas (%s+%s > %s) at %s",
                    tostring(props.position.y), tostring(props.size.y),
                    tostring(parentSize.y), path))
        end
        if node.userData.drawLayer == 1 then
            nodeBoxes = nodeBoxes + 1
        end
    end
    if type(node.content) == "table" then
        for i, child in ipairs(node.content) do
            walkLayout(child, node, path .. "/" .. i)
        end
    end
end
assert(lastCreatedLayout ~= nil, "ui.create was never called")
walkLayout(lastCreatedLayout, nil, "root")

-- Geometry of the scrolling tree canvas.
--
-- Two distinct failure modes are checked. MyGUI crops children to the parent
-- rect INCLUSIVE of the edge, so a node touching the canvas boundary renders
-- with that side's border missing -- which is why the canvas must be padded
-- past the node extent, not sized flush to it. And a node whose required
-- scroll offset falls outside the pan clamp can never be brought fully into
-- view. The canvas is located by finding the widget that actually holds the
-- node boxes, not merely the first clipping container in the layout.
do
    local canvas, viewport = nil, nil
    local function findCanvas(node, parent)
        if type(node) ~= "table" or canvas ~= nil then return end
        if type(node.content) == "table" then
            for _, child in ipairs(node.content) do
                if type(child.userData) == "table" and child.userData.drawLayer == 1 then
                    canvas, viewport = node, parent
                    return
                end
            end
            for _, child in ipairs(node.content) do findCanvas(child, node) end
        end
    end
    findCanvas(lastCreatedLayout, nil)
    assert(canvas, "tree canvas (widget holding the node boxes) not found in layout")
    assert(viewport and viewport.props.clip == true, "tree canvas is not inside a clipping viewport")

    local canvasW, canvasH = canvas.props.size.x, canvas.props.size.y
    local viewW, viewH = viewport.props.size.x, viewport.props.size.y
    local MAX_PAN = 600   -- perkpage clamps pan to +/- px(600)
    -- canvas position is -pan - shift, and pan is 0 on a fresh open
    local shiftX, shiftY = -canvas.props.position.x, -canvas.props.position.y

    for _, child in ipairs(canvas.content) do
        if type(child.userData) == "table" and child.userData.drawLayer == 1 then
            local cx, cy = child.props.position.x, child.props.position.y
            local w, h = child.props.size.x, child.props.size.y

            assert(cx > 0 and cy > 0 and cx + w < canvasW and cy + h < canvasH,
                string.format("node box touches the canvas edge and will lose a border: "
                    .. "box (%d,%d)-(%d,%d) in canvas %dx%d",
                    cx, cy, cx + w, cy + h, canvasW, canvasH))

            local minPanX, maxPanX = cx - shiftX + w - viewW, cx - shiftX
            local minPanY, maxPanY = cy - shiftY + h - viewH, cy - shiftY
            assert(minPanX <= MAX_PAN and maxPanX >= -MAX_PAN and minPanX <= maxPanX
                    and minPanY <= MAX_PAN and maxPanY >= -MAX_PAN and minPanY <= maxPanY,
                string.format("node unreachable within pan limits: needs panX [%d,%d] panY [%d,%d]; "
                    .. "clamp +/-%d, viewport %dx%d", minPanX, maxPanX, minPanY, maxPanY, MAX_PAN, viewW, viewH))
        end
    end
end
assert(nodeBoxes == #treeNodes,
    string.format("expected %d tree node boxes in the layout, found %d", #treeNodes, nodeBoxes))

for i = 1, 5 do page.engineHandlers.onFrame(PAUSED) end   -- frame path with menu open (game paused)

-- ==========================================================================
-- Purchase flow: click a node, click Unlock Perk, deliver the queued addPerk
-- event (as the engine would, one frame later), run the frame handler for
-- under half a second, and require the button row to have caught up on its
-- own -- no second click. Guards the "Unlock Perk button does not update
-- until you click something else" regression.
-- ==========================================================================
local menuElement = nil   -- the live element whose .layout rebuilds replace
local function findText(node, text)
    if type(node) ~= "table" then return nil end
    if type(node.props) == "table" and node.props.text == text then return node end
    if type(node.content) == "table" then
        for _, child in ipairs(node.content) do
            local found = findText(child, text)
            if found then return found end
        end
    end
    return nil
end
local function clickAt(node, label)
    -- Fire the press/release pair on the nearest ancestor of the label's Text
    -- node that carries mouse events, the way the engine would.
    local function walk(candidate, ancestorWithEvents)
        if type(candidate) ~= "table" then return false end
        local carrier = (type(candidate.events) == "table") and candidate or ancestorWithEvents
        if type(candidate.props) == "table" and candidate.props.text == label then
            assert(carrier, "no event carrier found for '" .. label .. "'")
            local mouseEvent = { button = 1, position = vec2(0,0), offset = vec2(0,0) }
            if carrier.events.mousePress then carrier.events.mousePress(mouseEvent) end
            if carrier.events.mouseRelease then carrier.events.mouseRelease(mouseEvent) end
            if carrier.events.mouseClick then carrier.events.mouseClick(mouseEvent) end
            return true
        end
        if type(candidate.content) == "table" then
            for _, child in ipairs(candidate.content) do
                if walk(child, carrier) then return true end
            end
        end
        return false
    end
    assert(walk(node, nil), "could not find clickable '" .. label .. "'")
end

menuElement = lastCreatedElement
local firstNodeTitle = treeNodes[1].title
local firstNodeId = treeNodes[1].id
clickAt(menuElement.layout, firstNodeTitle)           -- select the tree node
assert(findText(menuElement.layout, "Unlock Perk"), "Unlock Perk button missing after selecting an affordable perk")
clickAt(menuElement.layout, "Unlock Perk")            -- spend the point
deliverEvents()                                       -- engine delivers addPerk next frame
for i = 1, 25 do page.engineHandlers.onFrame(PAUSED) end  -- the game stays paused under the menu
assert(ownedPerks[firstNodeId], "purchase event was not applied")
assert(findText(menuElement.layout, "Unlock Perk") == nil,
    "Unlock Perk button still shown after the purchase landed")
assert(findText(menuElement.layout, "Disable") or findText(menuElement.layout, "Enable"),
    "Disable/Enable toggle missing after the purchase landed")

close()                                  -- close path
for i = 1, 5 do page.engineHandlers.onFrame(0.016) end   -- frame path with menu closed
io.write("UI SMOKE TEST PASSED\n")
