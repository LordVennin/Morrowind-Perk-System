-- Speechcraft player runtime for SkillPerkSystem_BasePack.
--
-- Nothing hooks the persuasion roll itself, but the skill-use events say
-- when a persuasion succeeded or failed, the dialogue window says who it was
-- with, and disposition can be read and written. The tree is built on those:
-- a skill use for every new acquaintance, a chance to put back the
-- disposition a failure cost, and a short Fortify after a success so a
-- conversation can snowball. The list of people met is perk state and lives
-- in the save.

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

local LOG_TAG = "[SkillPerkSystem_BasePack][Speechcraft][Player]"

local ensureSkillUsedHandler

local C = {
    ATTENTIVE_EAR = "speechcraft_attentive_ear",
    WELL_MET = "speechcraft_well_met",
    FACE_SAVING = "speechcraft_face_saving",
    SMOOTH_RECOVERY = "speechcraft_smooth_recovery",
    SILVER_TONGUE = "speechcraft_silver_tongue",
    -- Hidden: Speechcraft major with Illusion or Mercantile as a class
    -- skill. A dialogue panel that asks the NPC to follow; one at a time.
    RETINUE = "speechcraft_retinue",
    -- Only the panel's position is a preference; who follows is perk state
    -- and lives in the global script's save data.
    PANEL_SECTION = "SkillPerkSystem_BasePack_Speechcraft",
    PANEL_WIDTH = 320,
    PANEL_ROW_HEIGHT = 22,
    PANEL_BUTTON_HEIGHT = 30,

    POLL_INTERVAL = 0.5,
    STUDY_MULTIPLIER = 1.25,
    -- Never 100%: a failure should still be able to cost something.
    FACE_SAVING_CHANCE = 0.25,
    SMOOTH_RECOVERY_CHANCE = 0.50,
    SILVER_TONGUE_MAGNITUDE = 10,
    SILVER_TONGUE_SECONDS = 60,
}

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    skillHandlerRegistered = false,
    handlerReported = false,
    -- The NPC the dialogue window is open on, or nil.
    npc = nil,
    -- Their disposition as of the last poll, so a failure's cost can be
    -- measured after the engine has applied it.
    lastDisposition = nil,
    -- A failure was rolled a save; the next poll measures and restores.
    pendingRestore = false,
    -- Object ids of every NPC spoken to at least once (Well-Met). Save data.
    met = {},
    -- Dialogue is a paused UI mode, so onUpdate does not run inside it; the
    -- disposition watch runs from onFrame on real time, and only then.
    lastFrameCheck = 0,
    -- Retinue panel: the global side's answer for the NPC in dialogue, the
    -- panel element and its drag state.
    retinue = nil,
    panel = nil,
    panelPosition = nil,
    dragging = false,
    dragOffset = nil,
}
local FRAME_CHECK_SECONDS = 0.25
local panelSection = storage.playerSection(C.PANEL_SECTION)
local lastPanelRequest = 0

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

local function disposition(npc)
    local ok, value = pcall(types.NPC.getDisposition, npc, pself)
    return ok and (tonumber(value) or 0) or nil
end

local function isDialogueMode(mode)
    if mode == nil then
        return false
    end
    local okMode, wanted = pcall(function() return interfaces.UI.MODE.Dialogue end)
    if okMode and wanted ~= nil then
        return mode == wanted
    end
    return tostring(mode):lower() == "dialogue"
end

-- ---- Retinue panel -----------------------------------------------------------
local function loadPanelPosition()
    local saved = panelSection:get("retinuePanelPosition")
    if type(saved) == "table" and tonumber(saved.x) and tonumber(saved.y) then
        return util.vector2(tonumber(saved.x), tonumber(saved.y))
    end
    local screen = ui.screenSize()
    return util.vector2(math.floor(screen.x / 2 - C.PANEL_WIDTH / 2), math.floor(screen.y * 0.06))
end

local function savePanelPosition(position)
    pcall(function()
        panelSection:set("retinuePanelPosition", { x = position.x, y = position.y })
    end)
end

local function destroyPanel()
    if state.panel ~= nil then
        pcall(function() state.panel:destroy() end)
        state.panel = nil
    end
end

local function npcName(npc)
    local ok, record = pcall(types.NPC.record, npc)
    if ok and record ~= nil and type(record.name) == "string" and record.name ~= "" then
        return record.name
    end
    return tostring(npc and npc.recordId or "?")
end

-- Click and release can both report one press; one request per press.
local function requestRetinueAction(eventName)
    if state.npc == nil then
        return
    end
    local now = core.getRealTime()
    if now - lastPanelRequest < 0.3 then
        return
    end
    lastPanelRequest = now
    core.sendGlobalEvent(eventName, { player = pself, npc = state.npc })
end

local panelTexture = nil

local function whiteTexture()
    if panelTexture == nil then
        local ok, texture = pcall(ui.texture, { path = "white" })
        if ok then panelTexture = texture end
    end
    return panelTexture
end

-- Same construction as the Mercantile invest panel: text rows at explicit
-- positions, with transparent Image overlays for the drag handle and the
-- button, since Text widgets do not raise mouse events.
local function buildPanel(status)
    local templates = interfaces.MWUI ~= nil and interfaces.MWUI.templates or nil
    if templates == nil or state.npc == nil then
        return nil
    end
    local npc = state.npc
    local current = disposition(npc) or 0
    local minimum = tonumber(status.minDisposition) or 80
    local action, reason = nil, nil
    if status.isFollower then
        action = "Dismiss"
    elseif status.hasFollower then
        reason = "Already leading " .. tostring(status.followerName or "someone")
    elseif status.recruitable ~= true then
        reason = tostring(status.reason or "Will not follow")
    elseif current < minimum then
        reason = string.format("Needs disposition %d", minimum)
    else
        action = "Ask to follow"
    end

    if state.panelPosition == nil then
        state.panelPosition = loadPanelPosition()
    end

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

    local titleTop = textRow("Retinue  (drag here)", templates.textHeader or templates.textNormal)
    textRow(string.format("%s  (disposition %d)", npcName(npc), current))
    if reason ~= nil then
        textRow(reason, templates.textDisabled or templates.textNormal)
    end
    local buttonTop = nil
    if action ~= nil then
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
                        text = action,
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
        local eventName = status.isFollower and "SkillPerkSystem_BasePack_Speechcraft_Dismiss"
            or "SkillPerkSystem_BasePack_Speechcraft_Recruit"
        overlay(buttonTop, C.PANEL_BUTTON_HEIGHT, {
            mouseClick = async:callback(function()
                requestRetinueAction(eventName)
            end),
            mouseRelease = async:callback(function(mouseEvent)
                if mouseEvent.button == 1 and not state.dragging then
                    requestRetinueAction(eventName)
                end
            end),
        })
    end

    return {
        layer = "Windows",
        type = ui.TYPE.Container,
        template = templates.boxTransparentThick or templates.boxTransparent,
        props = { position = state.panelPosition },
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
    if state.npc == nil or state.retinue == nil or not enabled(C.RETINUE) then
        return
    end
    local layout = buildPanel(state.retinue)
    if layout == nil then
        return
    end
    local ok, element = pcall(ui.create, layout)
    if ok then
        state.panel = element
    else
        print(LOG_TAG .. " could not build the retinue panel: " .. tostring(element))
    end
end

local function requestRetinueStatus()
    if state.npc == nil or not enabled(C.RETINUE) then
        return
    end
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_RetinueStatus", { player = pself, npc = state.npc })
end

local function onRetinueState(data)
    if type(data) ~= "table" or state.npc == nil or data.npcId ~= state.npc.id then
        return
    end
    state.retinue = data
    showPanel()
end

-- Talking someone into coming along is a persuasion.
local function onRetinueRecruited(data)
    local name = type(data) == "table" and data.name or "They"
    ui.showMessage(tostring(name) .. " will follow you.")
    local progression = interfaces.SkillProgression
    local useTypes = progression ~= nil and progression.SKILL_USE_TYPES or nil
    if progression ~= nil and type(progression.skillUsed) == "function" and useTypes ~= nil then
        pcall(progression.skillUsed, "speechcraft", { useType = useTypes.Speechcraft_Success })
    end
end

-- Well-Met: the first time a conversation opens with someone, it counts.
local function noteMeeting(npc)
    if not enabled(C.WELL_MET) or npc == nil or state.met[npc.id] then
        return
    end
    state.met[npc.id] = true
    local progression = interfaces.SkillProgression
    local useTypes = progression ~= nil and progression.SKILL_USE_TYPES or nil
    if progression ~= nil and type(progression.skillUsed) == "function" and useTypes ~= nil then
        pcall(progression.skillUsed, "speechcraft", { useType = useTypes.Speechcraft_Success })
        debugPrint("well-met: first conversation with " .. tostring(npc.recordId))
    end
end

local function onUiModeChanged(data)
    local newMode = type(data) == "table" and data.newMode or nil
    local arg = type(data) == "table" and data.arg or nil
    if isDialogueMode(newMode) and arg ~= nil and types.NPC.objectIsInstance(arg) then
        state.npc = arg
        state.lastDisposition = disposition(arg)
        state.pendingRestore = false
        state.retinue = nil
        noteMeeting(arg)
        requestRetinueStatus()
        return
    end
    if state.npc ~= nil then
        state.npc = nil
        state.lastDisposition = nil
        state.pendingRestore = false
        state.retinue = nil
        destroyPanel()
    end
end

-- Refunding the perk sends the follower home.
local function onPerkStateChanged(data)
    if type(data) ~= "table" or data.perkID ~= C.RETINUE then
        return
    end
    if not enabled(C.RETINUE) then
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_Dismiss", { player = pself })
        destroyPanel()
    elseif state.npc ~= nil then
        requestRetinueStatus()
    end
end

local function faceSavingChance()
    if enabled(C.SMOOTH_RECOVERY) then
        return C.SMOOTH_RECOVERY_CHANCE
    end
    if enabled(C.FACE_SAVING) then
        return C.FACE_SAVING_CHANCE
    end
    return 0
end

local function onSkillUsed(skillId, params)
    if skillId ~= "speechcraft" then
        return
    end
    if enabled(C.ATTENTIVE_EAR) and type(params) == "table" and type(params.skillGain) == "number" then
        params.skillGain = params.skillGain * C.STUDY_MULTIPLIER
    end
    if state.npc == nil then
        return
    end
    if useTypeIs(params, "Speechcraft_Fail") then
        local chance = faceSavingChance()
        if chance > 0 and math.random() < chance then
            -- The engine's penalty may not be applied yet; the poll measures
            -- the drop against the last reading and puts it back.
            state.pendingRestore = true
            debugPrint("face saving: this failure will be forgiven")
        else
            debugPrint("face saving: failure stands")
        end
    elseif useTypeIs(params, "Speechcraft_Success") then
        if state.panel ~= nil then
            -- Disposition may have crossed the recruiting line.
            showPanel()
        end
        if enabled(C.SILVER_TONGUE) then
            core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_SilverTongue", {
                player = pself,
                magnitude = C.SILVER_TONGUE_MAGNITUDE,
                seconds = C.SILVER_TONGUE_SECONDS,
            })
            debugPrint("silver tongue: fortify requested")
        end
    end
end

-- Runs a few times a second while a dialogue is open: measures a forgiven
-- failure's cost and asks the global side to restore it, otherwise keeps the
-- reading current so successes and ordinary drift are not mistaken for
-- penalties.
local function trackDisposition()
    if state.npc == nil then
        return
    end
    local current = disposition(state.npc)
    if current == nil then
        return
    end
    if state.pendingRestore and state.lastDisposition ~= nil and current < state.lastDisposition then
        local lost = state.lastDisposition - current
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_RestoreDisposition", {
            player = pself,
            npc = state.npc,
            delta = lost,
        })
        debugPrint("face saving: restoring " .. lost .. " disposition")
        state.pendingRestore = false
        state.lastDisposition = current + lost
        return
    end
    if state.pendingRestore and state.lastDisposition ~= nil and current >= state.lastDisposition then
        -- Nothing was lost after all (or it has not landed yet); one more
        -- poll of grace, then give up on it.
        if state.restoreGrace then
            state.pendingRestore = false
            state.restoreGrace = nil
        else
            state.restoreGrace = true
        end
        return
    end
    state.lastDisposition = current
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
    if text == "spsspeechcraftdebug" or text == "luaspsspeechcraftdebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_SetDebug", { player = pself, enabled = debugLogging })
        return
    end
    if text ~= "spsspeechcraft" and text ~= "luaspsspeechcraft" then
        return
    end
    local metCount = 0
    for _ in pairs(state.met) do metCount = metCount + 1 end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " talking to=" .. tostring(state.npc and state.npc.recordId)
        .. " disposition=" .. tostring(state.lastDisposition) .. " met=" .. metCount)
    for label, perkId in pairs({
        attentiveEar = C.ATTENTIVE_EAR, wellMet = C.WELL_MET, faceSaving = C.FACE_SAVING,
        smoothRecovery = C.SMOOTH_RECOVERY, silverTongue = C.SILVER_TONGUE,
        retinue = C.RETINUE,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        SkillPerkSystem_BasePack_Speechcraft_RetinueState = onRetinueState,
        SkillPerkSystem_BasePack_Speechcraft_RetinueRecruited = onRetinueRecruited,
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
        -- Per frame only while the dialogue window is open, and throttled on
        -- real time inside that, since game time stands still there.
        shouldFrame = function()
            return state.npc ~= nil
        end,
        onFrame = function()
            local now = core.getRealTime()
            if now - state.lastFrameCheck < FRAME_CHECK_SECONDS then
                return
            end
            state.lastFrameCheck = now
            trackDisposition()
        end,
        onLoad = function(data)
            data = type(data) == "table" and data or {}
            state.pollTimer = C.POLL_INTERVAL
            state.npc = nil
            state.lastDisposition = nil
            state.pendingRestore = false
            state.retinue = nil
            state.panelPosition = nil
            state.dragging = false
            state.dragOffset = nil
            destroyPanel()
            state.met = {}
            local saved = data.speechcraftMet
            if type(saved) == "table" then
                for id in pairs(saved) do
                    if type(id) == "string" then state.met[id] = true end
                end
            end
            ensureSkillUsedHandler()
        end,
        onSave = function()
            return { speechcraftMet = state.met }
        end,
        onConsoleCommand = onConsoleCommand,
    },
}

return __basepack_subsystem_result
