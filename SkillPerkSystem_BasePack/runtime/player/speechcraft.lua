-- Speechcraft player runtime for SkillPerkSystem_BasePack.
--
-- Nothing hooks the persuasion roll itself, but the skill-use events say
-- when a persuasion succeeded or failed, the dialogue window says who it was
-- with, and disposition can be read and written. The tree is built on those:
-- a skill use for every new acquaintance, a chance to put back the
-- disposition a failure cost, and a slow, gated road into faction
-- reputation. The list of people met is perk state and lives in the save.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
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
    WELL_CONNECTED = "speechcraft_well_connected",

    POLL_INTERVAL = 0.5,
    STUDY_MULTIPLIER = 1.25,
    -- Never 100%: a failure should still be able to cost something.
    FACE_SAVING_CHANCE = 0.25,
    SMOOTH_RECOVERY_CHANCE = 0.50,
    WELL_CONNECTED_CHANCE = 0.20,
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
}
local FRAME_CHECK_SECONDS = 0.25

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
        noteMeeting(arg)
        return
    end
    if state.npc ~= nil then
        state.npc = nil
        state.lastDisposition = nil
        state.pendingRestore = false
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
        if enabled(C.WELL_CONNECTED) and math.random() < C.WELL_CONNECTED_CHANCE then
            core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_Reputation", {
                player = pself,
                npc = state.npc,
            })
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
        smoothRecovery = C.SMOOTH_RECOVERY, wellConnected = C.WELL_CONNECTED,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Speechcraft_Diagnose", { player = pself })
end

local function onReputationRaised(data)
    local faction = type(data) == "table" and data.faction or "the faction"
    ui.showMessage(string.format("Your reputation with %s grows.", tostring(faction)))
end

__basepack_subsystem_result = {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        SkillPerkSystem_BasePack_Speechcraft_ReputationRaised = onReputationRaised,
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
