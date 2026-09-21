-- Mercantile player runtime for SkillPerkSystem_BasePack.
--
-- Lua cannot touch prices or a merchant's gold, but it can read and write
-- disposition (which is what drives prices), create gold, award skill use,
-- and see which merchant the barter window is open on. The tree is built on
-- exactly those: loyalty per successful barter, an investment that buys
-- permanent disposition, dividends paid in gold when the shop is visited
-- again, and a skill use for every collection. The ledger lives on the
-- global side; this side reacts to the barter window and draws the invest
-- panel beside it.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")
local storage = require("openmw.storage")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Mercantile][Player]"

local ensureSkillUsedHandler

local C = {
    KEEN_TRADER = "mercantile_keen_trader",
    REGULAR_CUSTOMER = "mercantile_regular_customer",
    INVESTOR = "mercantile_investor",
    DIVIDENDS = "mercantile_dividends",
    TRADE_PRINCE = "mercantile_trade_prince",

    POLL_INTERVAL = 0.5,
    STUDY_MULTIPLIER = 1.25,
    LOYALTY_DELTA = 2,
    LOYALTY_CAP = 90,
    INVEST_MIN_DISPOSITION = 60,
    INVEST_AMOUNT = 100,
    GOLD_ID = "gold_001",
    -- Collecting dividends is trade: it counts as this many successful barters.
    DIVIDEND_SKILL_SCALE = 4,
    -- Where the panel sits is a UI preference, not perk state, so it lives
    -- in the player's storage section like the framework's own settings.
    PANEL_SECTION = "SkillPerkSystem_BasePack_Mercantile",
    PANEL_WIDTH = 320,
    PANEL_ROW_HEIGHT = 22,
    PANEL_BUTTON_HEIGHT = 30,
}

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    skillHandlerRegistered = false,
    handlerReported = false,
    -- The merchant the barter window is open on, or nil.
    merchant = nil,
    -- Last status the global side reported for that merchant.
    status = nil,
    panel = nil,
    -- Drag state for the panel.
    dragging = false,
    dragOffset = nil,
    panelPosition = nil,
}

local panelSection = storage.playerSection(C.PANEL_SECTION)

local function loadPanelPosition()
    local saved = panelSection:get("investPanelPosition")
    if type(saved) == "table" and tonumber(saved.x) and tonumber(saved.y) then
        return util.vector2(tonumber(saved.x), tonumber(saved.y))
    end
    -- Top centre by default, clear of the barter window's title bar.
    local screen = ui.screenSize()
    return util.vector2(math.floor(screen.x / 2 - C.PANEL_WIDTH / 2), math.floor(screen.y * 0.06))
end

local function savePanelPosition(position)
    pcall(function()
        panelSection:set("investPanelPosition", { x = position.x, y = position.y })
    end)
end

local function debugPrint(message)
    if debugLogging then
        print(LOG_TAG .. " " .. message)
    end
end

local function useTypeIs(params, name)
    local useTypes = interfaces.SkillProgression ~= nil
        and interfaces.SkillProgression.SKILL_USE_TYPES or nil
    local wanted = useTypes ~= nil and useTypes[name] or nil
    if wanted == nil or type(params) ~= "table" or params.useType == nil then
        return false
    end
    return params.useType == wanted
end

local function playerGold()
    local ok, count = pcall(function() return Actor.inventory(pself):countOf(C.GOLD_ID) end)
    return ok and (tonumber(count) or 0) or 0
end

local function merchantName(npc)
    local ok, name = pcall(function() return npc.type.record(npc).name end)
    return ok and type(name) == "string" and name or tostring(npc and npc.recordId or "?")
end

local function merchantDisposition(npc)
    local ok, value = pcall(types.NPC.getDisposition, npc, pself)
    return ok and (tonumber(value) or 0) or 0
end

-- ---- Invest panel -----------------------------------------------------------
local function destroyPanel()
    if state.panel ~= nil then
        pcall(function() state.panel:destroy() end)
        state.panel = nil
    end
end

local lastInvestRequest = 0

local function requestInvest()
    if state.merchant == nil then
        return
    end
    -- click and release can both report the same press; one request per
    -- press is enough.
    local now = core.getRealTime()
    if now - lastInvestRequest < 0.3 then
        return
    end
    lastInvestRequest = now
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Mercantile_Invest", {
        player = pself,
        npc = state.merchant,
        tradePrince = enabled(C.TRADE_PRINCE),
    })
end

local panelTexture = nil

local function whiteTexture()
    if panelTexture == nil then
        local ok, texture = pcall(ui.texture, { path = "white" })
        if ok then panelTexture = texture end
    end
    return panelTexture
end

local function buildPanel(status)
    local templates = interfaces.MWUI ~= nil and interfaces.MWUI.templates or nil
    if templates == nil then
        return nil
    end
    local npc = state.merchant
    local disposition = merchantDisposition(npc)
    local invested = tonumber(status and status.amount) or 0
    local maximum = tonumber(status and status.maxAmount) or C.INVEST_AMOUNT * 5
    local slotsLeft = tonumber(status and status.slotsLeft) or 0
    local gold = playerGold()

    local canInvest = disposition >= C.INVEST_MIN_DISPOSITION and invested < maximum
        and gold >= C.INVEST_AMOUNT and (invested > 0 or slotsLeft > 0)
    local reason = nil
    if disposition < C.INVEST_MIN_DISPOSITION then
        reason = string.format("Needs disposition %d", C.INVEST_MIN_DISPOSITION)
    elseif invested >= maximum then
        reason = "Fully invested"
    elseif invested == 0 and slotsLeft <= 0 then
        reason = "No investment slots left"
    elseif gold < C.INVEST_AMOUNT then
        reason = string.format("Needs %d gold", C.INVEST_AMOUNT)
    end

    if state.panelPosition == nil then
        state.panelPosition = loadPanelPosition()
    end

    -- Text widgets neither raise mouse events nor pass them on, so the two
    -- interactive spots -- the drag handle over the title and the invest
    -- button -- are transparent Image widgets laid over the text. Image is
    -- the widget type the overheal bar proved drags and clicks correctly.
    -- Everything is placed at explicit positions inside the container.
    local padX, padY = 12, 8
    local rowWidth = C.PANEL_WIDTH - padX * 2
    local y = padY
    local content = {}
    local function textRow(text, template)
        content[#content + 1] = {
            type = ui.TYPE.Text,
            template = template or templates.textNormal,
            props = {
                text = text,
                textSize = 16,
                autoSize = false,
                position = util.vector2(padX, y),
                size = util.vector2(rowWidth, C.PANEL_ROW_HEIGHT),
            },
        }
        local top = y
        y = y + C.PANEL_ROW_HEIGHT
        return top
    end
    local function overlay(top, height, events)
        content[#content + 1] = {
            type = ui.TYPE.Image,
            props = {
                resource = whiteTexture(),
                alpha = 0,
                position = util.vector2(padX, top),
                size = util.vector2(rowWidth, height),
            },
            events = events,
        }
    end

    local titleTop = textRow("Investments  (drag here)", templates.textHeader or templates.textNormal)
    textRow(string.format("%s  (disposition %d)", merchantName(npc), disposition))
    textRow(string.format("Invested: %d / %d", invested, maximum))
    if reason ~= nil then
        textRow(reason, templates.textDisabled or templates.textNormal)
    end
    local buttonTop = nil
    if canInvest then
        buttonTop = y
        content[#content + 1] = {
            type = ui.TYPE.Container,
            template = templates.boxButton or templates.boxTransparentThick,
            props = {
                position = util.vector2(padX, y),
                size = util.vector2(rowWidth, C.PANEL_BUTTON_HEIGHT),
            },
            content = ui.content {
                {
                    type = ui.TYPE.Text,
                    template = templates.textNormal,
                    props = {
                        text = string.format("Invest %d gold", C.INVEST_AMOUNT),
                        textSize = 16,
                        autoSize = false,
                        size = util.vector2(rowWidth, C.PANEL_BUTTON_HEIGHT),
                        textAlignH = ui.ALIGNMENT.Center,
                        textAlignV = ui.ALIGNMENT.Center,
                    },
                },
            },
        }
        y = y + C.PANEL_BUTTON_HEIGHT
    end
    local height = y + padY

    -- Overlays go last so they sit above the text and the button box.
    overlay(titleTop, C.PANEL_ROW_HEIGHT, {
        mousePress = async:callback(function(mouseEvent)
            if mouseEvent.button ~= 1 then return end
            state.dragging = true
            state.dragOffset = mouseEvent.position - state.panelPosition
        end),
        mouseMove = async:callback(function(mouseEvent)
            if not state.dragging or state.dragOffset == nil or state.panel == nil then return end
            state.panelPosition = mouseEvent.position - state.dragOffset
            pcall(function()
                state.panel.layout.props.position = state.panelPosition
                state.panel:update()
            end)
        end),
        mouseRelease = async:callback(function(mouseEvent)
            if mouseEvent.button ~= 1 or not state.dragging then return end
            state.dragging = false
            state.dragOffset = nil
            savePanelPosition(state.panelPosition)
        end),
    })
    if buttonTop ~= nil then
        overlay(buttonTop, C.PANEL_BUTTON_HEIGHT, {
            mouseClick = async:callback(function()
                debugPrint("invest button clicked")
                requestInvest()
            end),
            mouseRelease = async:callback(function(mouseEvent)
                -- Belt and braces: some builds report release without click.
                if mouseEvent.button == 1 and not state.dragging then
                    debugPrint("invest button released")
                    requestInvest()
                end
            end),
        })
    end

    return {
        layer = "Windows",
        type = ui.TYPE.Container,
        template = templates.boxTransparentThick or templates.boxTransparent,
        props = {
            position = state.panelPosition,
        },
        content = ui.content {
            {
                type = ui.TYPE.Widget,
                props = { size = util.vector2(C.PANEL_WIDTH, height) },
                content = ui.content(content),
            },
        },
    }
end

local function showPanel()
    destroyPanel()
    if state.merchant == nil or not enabled(C.INVESTOR) then
        return
    end
    local layout = buildPanel(state.status)
    if layout == nil then
        return
    end
    local ok, element = pcall(ui.create, layout)
    if ok then
        state.panel = element
    else
        print(LOG_TAG .. " could not build the invest panel: " .. tostring(element))
    end
end

-- ---- Barter window ----------------------------------------------------------
local function isBarterMode(mode)
    if mode == nil then
        return false
    end
    local okMode, wanted = pcall(function() return interfaces.UI.MODE.Barter end)
    if okMode and wanted ~= nil then
        return mode == wanted
    end
    return tostring(mode):lower() == "barter"
end

local function onUiModeChanged(data)
    local newMode = type(data) == "table" and data.newMode or nil
    local arg = type(data) == "table" and data.arg or nil
    if isBarterMode(newMode) and arg ~= nil then
        state.merchant = arg
        state.status = nil
        if enabled(C.INVESTOR) or enabled(C.DIVIDENDS) then
            core.sendGlobalEvent("SkillPerkSystem_BasePack_Mercantile_BarterOpened", {
                player = pself,
                npc = arg,
                dividends = enabled(C.DIVIDENDS),
                tradePrince = enabled(C.TRADE_PRINCE),
            })
        end
        debugPrint("bartering with " .. merchantName(arg))
        return
    end
    if state.merchant ~= nil then
        state.merchant = nil
        state.status = nil
        destroyPanel()
    end
end

-- The global side answers a barter opening or an investment with the
-- merchant's ledger line; dividends paid on the way are reported too.
local function onMerchantStatus(data)
    if type(data) ~= "table" or state.merchant == nil or data.npcId ~= state.merchant.id then
        return
    end
    state.status = data
    local paid = tonumber(data.paid) or 0
    if paid > 0 then
        ui.showMessage(string.format("%s pays you %d gold in dividends.", merchantName(state.merchant), paid))
        -- Income is trade: the collection counts as several successful
        -- barters' worth of skill use.
        local progression = interfaces.SkillProgression
        local useTypes = progression ~= nil and progression.SKILL_USE_TYPES or nil
        if progression ~= nil and type(progression.skillUsed) == "function" and useTypes ~= nil then
            pcall(progression.skillUsed, "mercantile", {
                useType = useTypes.Mercantile_Success,
                scale = C.DIVIDEND_SKILL_SCALE,
            })
        end
    end
    if data.invested == true then
        ui.showMessage(string.format("You invest %d gold in %s.", C.INVEST_AMOUNT, merchantName(state.merchant)))
    end
    showPanel()
end

-- ---- Skill use -----------------------------------------------------------------
local function onSkillUsed(skillId, params)
    if skillId ~= "mercantile" then
        return
    end
    if enabled(C.KEEN_TRADER) and type(params) == "table" and type(params.skillGain) == "number" then
        params.skillGain = params.skillGain * C.STUDY_MULTIPLIER
    end
    if enabled(C.REGULAR_CUSTOMER) and state.merchant ~= nil and useTypeIs(params, "Mercantile_Success") then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Mercantile_Loyalty", {
            player = pself,
            npc = state.merchant,
            delta = C.LOYALTY_DELTA,
            cap = C.LOYALTY_CAP,
        })
    end
end

ensureSkillUsedHandler = function()
    if state.skillHandlerRegistered then
        return
    end
    local progression = interfaces.SkillProgression
    if progression == nil then
        return
    end
    if type(progression.addSkillUsedHandler) == "function" then
        progression.addSkillUsedHandler(onSkillUsed)
        state.skillHandlerRegistered = true
        return
    end
    if not state.handlerReported then
        state.handlerReported = true
        print(LOG_TAG .. " SkillProgression has no addSkillUsedHandler")
    end
end

local function onConsoleCommand(_, command)
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text == "spsmercantiledebug" or text == "luaspsmercantiledebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Mercantile_SetDebug", { player = pself, enabled = debugLogging })
        return
    end
    if text ~= "spsmercantile" and text ~= "luaspsmercantile" then
        return
    end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " gold=" .. playerGold() .. " merchant=" .. tostring(state.merchant and state.merchant.recordId))
    for label, perkId in pairs({
        keenTrader = C.KEEN_TRADER, regularCustomer = C.REGULAR_CUSTOMER, investor = C.INVESTOR,
        dividends = C.DIVIDENDS, tradePrince = C.TRADE_PRINCE,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Mercantile_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        SkillPerkSystem_BasePack_Mercantile_MerchantStatus = onMerchantStatus,
    },
    engineHandlers = {
        shouldUpdate = function(dt)
            state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
            return state.pollTimer >= C.POLL_INTERVAL
        end,
        onUpdate = function()
            state.pollTimer = 0
            ensureSkillUsedHandler()
        end,
        onLoad = function()
            state.pollTimer = C.POLL_INTERVAL
            state.merchant = nil
            state.status = nil
            state.dragging = false
            state.dragOffset = nil
            state.panelPosition = nil
            destroyPanel()
            ensureSkillUsedHandler()
        end,
        onConsoleCommand = onConsoleCommand,
    },
}

return __basepack_subsystem_result
