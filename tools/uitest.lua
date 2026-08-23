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
mocks["openmw.ui"] = {
    TYPE = setmetatable({}, {__index=function(_,k) return k end}),
    ALIGNMENT = setmetatable({}, {__index=function(_,k) return k end}),
    texture = function(t) return t end,
    content = uiContent,
    create = function(layout)
        lastCreatedLayout = layout
        return { layout = layout, update = function() end, destroy = function() end }
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
mocks["openmw.self"] = { position = vec2(0,0), controls = {} }
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
        hasPerk = function() return false end,
        isPerkEffectEnabled = function() return true end,
        getGlobalPoints = function() return 3 end,
        getPoints = function() return 3 end,
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

for i = 1, 5 do page.engineHandlers.onFrame(0.016) end   -- frame path with menu open
close()                                  -- close path
for i = 1, 5 do page.engineHandlers.onFrame(0.016) end   -- frame path with menu closed
io.write("UI SMOKE TEST PASSED\n")
