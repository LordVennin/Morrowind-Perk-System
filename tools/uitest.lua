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
-- A realistically tall tree: high-y nodes sit above the viewport centre, which
-- is exactly the shape that exposed the negative-canvas-coordinate cutoff.
local perks = { athletics_steady_pace = { cost = 1 } }
local treeNodes = {
    { id="athletics_steady_pace", x=-180, y=0, requires={}, requiresAny={}, title="Steady Pace", description="d" },
    { id="athletics_deep_lungs", x=180, y=0, requires={"athletics_steady_pace"}, requiresAny={}, title="Deep Lungs", description="d" },
    { id="athletics_momentum", x=0, y=140, requires={"athletics_steady_pace"}, requiresAny={}, title="Momentum", description="d" },
    { id="athletics_long_strider", x=-220, y=280, requires={"athletics_momentum"}, requiresAny={}, title="Long Strider", description="d" },
    { id="athletics_relentless", x=0, y=420, requires={"athletics_long_strider"}, requiresAny={}, title="Relentless", description="d" },
    { id="athletics_peerless", x=0, y=580, requires={"athletics_relentless"}, requiresAny={}, title="Peerless", description="d" },
}
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
clickAt(menuElement.layout, "Steady Pace")            -- select the tree node
assert(findText(menuElement.layout, "Unlock Perk"), "Unlock Perk button missing after selecting an affordable perk")
clickAt(menuElement.layout, "Unlock Perk")            -- spend the point
deliverEvents()                                       -- engine delivers addPerk next frame
for i = 1, 25 do page.engineHandlers.onFrame(PAUSED) end  -- the game stays paused under the menu
assert(ownedPerks["athletics_steady_pace"], "purchase event was not applied")
assert(findText(menuElement.layout, "Unlock Perk") == nil,
    "Unlock Perk button still shown after the purchase landed")
assert(findText(menuElement.layout, "Disable") or findText(menuElement.layout, "Enable"),
    "Disable/Enable toggle missing after the purchase landed")

close()                                  -- close path
for i = 1, 5 do page.engineHandlers.onFrame(0.016) end   -- frame path with menu closed
io.write("UI SMOKE TEST PASSED\n")
