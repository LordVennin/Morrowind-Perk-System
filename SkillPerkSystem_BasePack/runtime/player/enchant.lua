-- Enchant player runtime for SkillPerkSystem_BasePack.
--
-- What Lua can reach for Enchant is the charge economy: an item's current
-- charge, its enchantment record, which item the player casts from, and the
-- four Enchant skill-use types. So this side reacts to those uses -- refund
-- on cast-on-use, a spare gem on recharge -- and runs the slow regen timer.
-- Charge is written on the global side. The strike perks resolve on the
-- target the weapon hits; see the enchant section of basepack_actor_target.lua.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local stats = require("scripts.SkillPerkSystem_BasePack.runtime.perkstats")

local enabled = stats.enabled
local setModifier = stats.setModifier

local __basepack_subsystem_result = nil

local Actor = types.Actor
local LOG_TAG = "[SkillPerkSystem_BasePack][Enchant][Player]"

local ensureSkillUsedHandler

local C = {
    ATTENTIVE_ENCHANTER = "enchant_attentive_enchanter",
    ENCHANTERS_RESERVE = "enchant_enchanters_reserve",
    THRIFTY_CHANNELING = "enchant_thrifty_channeling",
    BRAND_OF_THE_MAKER = "enchant_brand_of_the_maker",
    SPARE_VESSEL = "enchant_spare_vessel",
    LIVING_ENCHANTMENT = "enchant_living_enchantment",
    SOUL_FED_BLADE = "enchant_soul_fed_blade",
    PRACTICED_BINDING = "enchant_practiced_binding",

    POLL_INTERVAL = 0.5,
    RESERVOIR_EVENT = "SkillPerkSystem_BasePack_SkillBase_SetReservoir",
    RIDERS_EVENT = "SkillPerkSystem_BasePack_Enchant_SetRiders",

    STUDY_MULTIPLIER = 1.25,
    -- A share of the charge ACTUALLY SPENT, measured off the item, never of
    -- the enchantment's listed cost: the engine scales the cost down with
    -- Enchant skill, so the listed cost over-refunded -- a 4-cost item got
    -- its whole cast back. Paid per cast, rounded down, so a cast that spent
    -- under 4 refunds nothing and can never loop for free.
    THRIFTY_REFUND_FRACTION = 0.25,
    -- Practiced Binding: applied while the enchanting menu is open.
    BINDING_SKILL_BONUS = 25,
    -- Living Enchantment ticks on its own slow clock inside the poll.
    REGEN_INTERVAL = 10.0,
    SPARE_VESSEL_CHANCE = 0.5,
}

local debugLogging = false

local state = {
    pollTimer = C.POLL_INTERVAL,
    regenTimer = 0,
    lastReservoirKey = nil,
    lastRidersKey = nil,
    skillHandlerRegistered = false,
    handlerReported = false,
    -- Filled soul gems by record id, taken when a menu opens; the recharge
    -- skill use fires after the gem is already gone, so this is how the one
    -- that went is known.
    filledGems = {},
    -- Thrifty Channeling watches the selected enchanted item's charge from
    -- the poll, so a cast can be measured as the drop between the reading
    -- before it and the reading after.
    watchedItemId = nil,
    watchedCharge = nil,
    pendingCast = nil,
    appliedBinding = 0,
}

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

-- The enchantment record behind an item, or nil for an unenchanted one.
local function enchantmentOf(item)
    if item == nil then
        return nil
    end
    local ok, enchantment = pcall(function()
        local record = item.type.record(item)
        local id = record ~= nil and record.enchant or nil
        if type(id) ~= "string" or id == "" then
            return nil
        end
        return core.magic.enchantments.records[id]
    end)
    return ok and enchantment or nil
end

-- Current charge of an item; nil charge means never drawn on, i.e. full.
local function readCharge(item)
    local enchantment = enchantmentOf(item)
    if enchantment == nil then
        return nil, nil
    end
    local okData, data = pcall(types.Item.itemData, item)
    if not okData or data == nil then
        return nil, enchantment
    end
    local charge = data.enchantmentCharge
    if charge == nil then
        return tonumber(enchantment.charge) or 0, enchantment
    end
    return tonumber(charge) or 0, enchantment
end

-- Thrifty Channeling, half one: a cast just happened on the selected item.
-- Its charge before the cast is the poll's last reading; the reading after
-- is taken at the next poll, once the engine has finished with it.
local function noteCast()
    if not enabled(C.THRIFTY_CHANNELING) then
        return
    end
    local okItem, item = pcall(Actor.getSelectedEnchantedItem, pself)
    if not okItem or item == nil then
        return
    end
    if state.watchedItemId ~= item.id or state.watchedCharge == nil then
        -- Nothing reliable to measure against; the poll will pick it up.
        return
    end
    state.pendingCast = { item = item, before = state.watchedCharge }
end

-- Half two, from the poll: measure the drop and refund a share of it,
-- rounded down. The drop is capped at the enchantment's listed cost so two
-- casts inside one poll cannot be read as one large one.
local function settleCast()
    local pending = state.pendingCast
    state.pendingCast = nil
    if pending == nil or pending.item == nil then
        return nil
    end
    local after, enchantment = readCharge(pending.item)
    if after == nil or enchantment == nil then
        return nil
    end
    local spent = math.min(pending.before - after, tonumber(enchantment.cost) or 0)
    local pay = math.floor(spent * C.THRIFTY_REFUND_FRACTION)
    if pay < 1 then
        debugPrint(string.format("spent %d charge; nothing to refund", spent))
        return after
    end
    debugPrint(string.format("spent %d charge; refunding %d", spent, pay))
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Enchant_AddCharge", {
        player = pself,
        item = pending.item,
        amount = pay,
    })
    return after + pay
end

-- Keeps the "before" reading current. Runs on the poll, so a reading is at
-- most half a second stale.
local function watchSelectedItem()
    if not enabled(C.THRIFTY_CHANNELING) then
        state.watchedItemId, state.watchedCharge = nil, nil
        return
    end
    local settled = settleCast()
    local okItem, item = pcall(Actor.getSelectedEnchantedItem, pself)
    if not okItem or item == nil then
        state.watchedItemId, state.watchedCharge = nil, nil
        return
    end
    if settled ~= nil and state.watchedItemId == item.id then
        -- The refund just sent has not landed yet; trust the arithmetic
        -- rather than a read that would miss it.
        state.watchedCharge = settled
        return
    end
    state.watchedItemId = item.id
    state.watchedCharge = readCharge(item)
end

-- Practiced Binding: the bonus exists only while the enchanting menu is
-- open, which is when the engine rolls success against the skill.
local function isEnchantingMode(mode)
    if mode == nil then
        return false
    end
    local okMode, wanted = pcall(function() return interfaces.UI.MODE.Enchanting end)
    if okMode and wanted ~= nil then
        return mode == wanted
    end
    return tostring(mode):lower() == "enchanting"
end

local function applyBinding(active)
    local wanted = (active and enabled(C.PRACTICED_BINDING)) and C.BINDING_SKILL_BONUS or 0
    state.appliedBinding = setModifier(stats.skillStat("enchant"), state.appliedBinding, wanted)
end

-- Counts the filled soul gems in the inventory by record id.
local function scanFilledGems()
    local counts = {}
    local okInventory, inventory = pcall(Actor.inventory, pself)
    if not okInventory or inventory == nil then
        return counts
    end
    pcall(function()
        for _, item in ipairs(inventory:getAll(types.Miscellaneous)) do
            local okData, data = pcall(types.Item.itemData, item)
            if okData and data ~= nil and data.soul ~= nil then
                local count = tonumber(item.count) or 1
                counts[item.recordId] = (counts[item.recordId] or 0) + count
            end
        end
    end)
    return counts
end

-- Spare Vessel: a filled gem that was there when the menu opened and is not
-- there now is the one the recharge consumed.
local function onRecharge()
    if not enabled(C.SPARE_VESSEL) then
        return
    end
    local before = state.filledGems
    local after = scanFilledGems()
    local consumed = nil
    for recordId, count in pairs(before) do
        if (after[recordId] or 0) < count then
            consumed = recordId
            break
        end
    end
    state.filledGems = after
    if consumed == nil then
        debugPrint("recharge seen but no filled gem went missing")
        return
    end
    if math.random() >= C.SPARE_VESSEL_CHANCE then
        debugPrint("recharge with " .. consumed .. "; the gem was spent")
        return
    end
    debugPrint("recharge with " .. consumed .. "; returning it empty")
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Enchant_ReturnGem", {
        player = pself,
        recordId = consumed,
    })
end

local function onSkillUsed(skillId, params)
    if skillId ~= "enchant" then
        return
    end
    -- Study: raise the gain in place; later handlers read the changed value.
    if enabled(C.ATTENTIVE_ENCHANTER) and type(params) == "table"
            and type(params.skillGain) == "number" then
        params.skillGain = params.skillGain * C.STUDY_MULTIPLIER
    end
    if useTypeIs(params, "Enchant_UseMagicItem") then
        noteCast()
    elseif useTypeIs(params, "Enchant_Recharge") then
        onRecharge()
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

local function publishReservoir()
    local wanted = enabled(C.ENCHANTERS_RESERVE)
    local key = tostring(wanted)
    if key == state.lastReservoirKey then
        return
    end
    state.lastReservoirKey = key
    core.sendGlobalEvent(C.RESERVOIR_EVENT, {
        player = pself,
        school = "enchant",
        tag = "Enchant",
        wanted = wanted,
    })
end

-- The strike perks resolve on the target, so it needs to know which are
-- active. Published only when the set changes.
local function publishRiders()
    local riders = {
        playerId = pself.id,
        brand = enabled(C.BRAND_OF_THE_MAKER),
        soulFed = enabled(C.SOUL_FED_BLADE),
    }
    local key = tostring(riders.brand) .. ":" .. tostring(riders.soulFed)
    if key == state.lastRidersKey then
        return
    end
    state.lastRidersKey = key
    core.sendGlobalEvent(C.RIDERS_EVENT, riders)
end

-- Living Enchantment: one request every ten seconds, and only while the
-- perk is on; the global side walks the equipment and writes the charge.
local function tickRegen(elapsed)
    if not enabled(C.LIVING_ENCHANTMENT) then
        state.regenTimer = 0
        return
    end
    state.regenTimer = state.regenTimer + elapsed
    if state.regenTimer < C.REGEN_INTERVAL then
        return
    end
    state.regenTimer = 0
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Enchant_Regen", { player = pself })
end

local function refresh(elapsed)
    ensureSkillUsedHandler()
    publishReservoir()
    publishRiders()
    tickRegen(elapsed)
    watchSelectedItem()
end

local function onPerkStateChanged()
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    if state.appliedBinding ~= 0 and not enabled(C.PRACTICED_BINDING) then
        applyBinding(false)
    end
    refresh(0)
end

local function onUiModeChanged(data)
    local newMode = type(data) == "table" and data.newMode or nil
    -- Any menu opening is the moment to take the baseline; the recharge
    -- dialog is one of them and cheap to cover along with the rest.
    if enabled(C.SPARE_VESSEL) and newMode ~= nil then
        state.filledGems = scanFilledGems()
    end
    applyBinding(isEnchantingMode(newMode))
end

local function onConsoleCommand(_, command)
    local text = tostring(command or ""):lower():gsub("%s+", "")
    if text == "spsenchantdebug" or text == "luaspsenchantdebug" then
        debugLogging = not debugLogging
        print(LOG_TAG .. " verbose logging " .. (debugLogging and "ON" or "OFF"))
        core.sendGlobalEvent("SkillPerkSystem_BasePack_Enchant_SetDebug", {
            player = pself,
            enabled = debugLogging,
        })
        return
    end
    if text ~= "spsenchant" and text ~= "luaspsenchant" then
        return
    end
    print(LOG_TAG .. " ---- diagnostic ----")
    print(LOG_TAG .. " skill handler=" .. tostring(state.skillHandlerRegistered)
        .. " verbose=" .. tostring(debugLogging) .. " (toggle with spsenchantdebug)")
    for label, perkId in pairs({
        attentiveEnchanter = C.ATTENTIVE_ENCHANTER, enchantersReserve = C.ENCHANTERS_RESERVE,
        thriftyChanneling = C.THRIFTY_CHANNELING, brandOfTheMaker = C.BRAND_OF_THE_MAKER,
        spareVessel = C.SPARE_VESSEL, livingEnchantment = C.LIVING_ENCHANTMENT,
        soulFedBlade = C.SOUL_FED_BLADE, practicedBinding = C.PRACTICED_BINDING,
    }) do
        print(LOG_TAG .. string.format("   %s (%s) enabled=%s", label, perkId, tostring(enabled(perkId))))
    end
    local gems = {}
    for recordId, count in pairs(scanFilledGems()) do
        gems[#gems + 1] = recordId .. " x" .. count
    end
    table.sort(gems)
    print(LOG_TAG .. " filled soul gems: " .. (#gems > 0 and table.concat(gems, ", ") or "none"))
    print(LOG_TAG .. string.format(" watched item=%s charge=%s bindingBonus=%d",
        tostring(state.watchedItemId), tostring(state.watchedCharge), state.appliedBinding))
    state.lastReservoirKey = nil
    state.lastRidersKey = nil
    refresh(0)
    core.sendGlobalEvent("SkillPerkSystem_BasePack_Enchant_Diagnose", { player = pself })
end

__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        shouldUpdate = function(dt)
            state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
            return state.pollTimer >= C.POLL_INTERVAL
        end,
        onUpdate = function()
            local elapsed = state.pollTimer
            state.pollTimer = 0
            refresh(elapsed)
        end,
        onLoad = function(data)
            data = type(data) == "table" and data or {}
            state.pollTimer = C.POLL_INTERVAL
            state.regenTimer = 0
            state.lastReservoirKey = nil
            state.lastRidersKey = nil
            state.filledGems = {}
            state.watchedItemId, state.watchedCharge, state.pendingCast = nil, nil, nil
            -- A menu cannot be open on load, so any bonus carried in the
            -- save is stale and comes off.
            state.appliedBinding = math.max(0, math.floor(tonumber(data.enchantAppliedBinding) or 0))
            applyBinding(false)
            refresh(0)
        end,
        onSave = function()
            return { enchantAppliedBinding = state.appliedBinding }
        end,
        onConsoleCommand = onConsoleCommand,
    },
}

return __basepack_subsystem_result
