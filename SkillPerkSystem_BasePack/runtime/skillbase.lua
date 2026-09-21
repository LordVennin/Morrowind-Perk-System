-- Shared base for the trees that so far carry only their opening perks:
-- Alteration, Illusion, Restoration, Enchant, Mercantile and Speechcraft.
--
-- Each of those trees has its own one-line player module that calls build()
-- with its perk ids, so the one-module-per-tree rule holds while the refund,
-- reservoir and study logic lives in one place instead of six copies. Three
-- perk shapes are supported, each optional:
--
--   refund    a share of every successful cast's own cost returned, for the
--             magic schools (same rule as Efficient Ruin: never a share of
--             the pool, so the cheapest spell cannot turn a profit)
--   reservoir +25 maximum magicka, granted as an Ability by the global side
--   study     skill progress for the tree's own skill raised by a quarter,
--             through the modifiable skillGain the progression handler gets

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local Actor = types.Actor

local M = {}

local POLL_INTERVAL = 0.5
local REFUND_FRACTION = 0.25
local STUDY_MULTIPLIER = 1.25
local RESERVOIR_EVENT = "SkillPerkSystem_BasePack_SkillBase_SetReservoir"

local function restoreMagicka(amount)
    local magicka = stats.dynamicStat("magicka")
    if magicka == nil or amount <= 0 then
        return
    end
    local maximum = math.max(0, (tonumber(magicka.base) or 0) + (tonumber(magicka.modifier) or 0))
    if maximum <= 0 then
        return
    end
    local current = tonumber(magicka.current) or 0
    pcall(function()
        magicka.current = math.min(maximum, current + amount)
    end)
end

-- config: { skillId, tag, refundPerk?, reservoirPerk?, studyPerk? }
function M.build(config)
    local skillId = config.skillId
    local LOG_TAG = "[SkillPerkSystem_BasePack][" .. tostring(config.tag) .. "][Player]"

    local state = {
        pollTimer = POLL_INTERVAL,
        lastReservoirKey = nil,
        handlerRegistered = false,
        handlerReported = false,
    }

    local function onSkillUsed(usedSkillId, params)
        if usedSkillId ~= skillId then
            return
        end

        -- Study: raise the gain in place. The progression interface hands a
        -- modifiable table, and later handlers (including the default) read
        -- the changed value.
        if config.studyPerk ~= nil and enabled(config.studyPerk)
                and type(params) == "table" and type(params.skillGain) == "number" then
            params.skillGain = params.skillGain * STUDY_MULTIPLIER
        end

        if config.refundPerk == nil or not enabled(config.refundPerk) then
            return
        end
        local useTypes = interfaces.SkillProgression ~= nil
            and interfaces.SkillProgression.SKILL_USE_TYPES or nil
        local castSuccess = useTypes ~= nil and useTypes.Spellcast_Success or nil
        if castSuccess ~= nil and type(params) == "table" and params.useType ~= nil
                and params.useType ~= castSuccess then
            return
        end
        -- The spell being cast is the selected one. A cast from an enchanted
        -- item selects no spell and spends no magicka, so it refunds nothing.
        local okSpell, selected = pcall(Actor.getSelectedSpell, pself)
        if not okSpell or selected == nil then
            return
        end
        local cost = tonumber(selected.cost)
        if cost == nil and type(selected.id) == "string" then
            local okRecord, record = pcall(function() return core.magic.spells.records[selected.id] end)
            if okRecord and record ~= nil then cost = tonumber(record.cost) end
        end
        if cost == nil or cost <= 0 then
            return
        end
        restoreMagicka(cost * REFUND_FRACTION)
    end

    -- Interfaces fill in as scripts come up, so registration is retried from
    -- the poll rather than attempted once at module load.
    local function ensureSkillUsedHandler()
        if state.handlerRegistered then
            return
        end
        local progression = interfaces.SkillProgression
        if progression == nil then
            return
        end
        if type(progression.addSkillUsedHandler) == "function" then
            progression.addSkillUsedHandler(onSkillUsed)
            state.handlerRegistered = true
            return
        end
        if not state.handlerReported then
            state.handlerReported = true
            print(LOG_TAG .. " SkillProgression has no addSkillUsedHandler")
        end
    end

    local function publishReservoir()
        if config.reservoirPerk == nil then
            return
        end
        local wanted = enabled(config.reservoirPerk)
        local key = tostring(wanted)
        if key == state.lastReservoirKey then
            return
        end
        state.lastReservoirKey = key
        core.sendGlobalEvent(RESERVOIR_EVENT, {
            player = pself,
            school = skillId,
            tag = config.tag,
            wanted = wanted,
        })
    end

    local function refresh()
        ensureSkillUsedHandler()
        publishReservoir()
    end

    return {
        eventHandlers = {
            SkillPerkSystem_PerkStateChanged = function()
                state.lastReservoirKey = nil
                refresh()
            end,
        },
        engineHandlers = {
            shouldUpdate = function(dt)
                state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
                return state.pollTimer >= POLL_INTERVAL
            end,
            onUpdate = function()
                state.pollTimer = 0
                refresh()
            end,
            onLoad = function()
                state.pollTimer = POLL_INTERVAL
                state.lastReservoirKey = nil
                refresh()
            end,
        },
    }
end

return M
