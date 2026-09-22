core = require('openmw.core')
types = require('openmw.types')
self = require('openmw.self')
animation = require('openmw.animation')
async = require('openmw.async')
I = require('openmw.interfaces')
util = require('openmw.util')
nearby = require('openmw.nearby')
v3 = util.vector3
activeEffects = types.Actor.activeEffects(self)
trData = require('scripts.tr_spells.trData')
vfs = require('openmw.vfs')
local activeSpells = types.Actor.activeSpells(self)

isPlayer = false
local SCRIPT_PATH = 'scripts/tr_spells/trActor.lua'
local CHECK_INTERVAL = 0.2
local loadedAddons = false

G = {
	isDead = false,
	
	-- primary events for all effect modules
	onMgefAdded   = {},
	onMgefTick    = {},
	onMgefRemoved = {},
	
	-- for manually accumulating magnitudes
	onAggregateReset  = {},
	onAggregateEffect = {},
	onAggregateCommit = {},
	
	-- for removing spells at the end of a frame
	pendingActiveSpellRemovals = {},
	
	eventHandlers  = {}, -- returned eventHandlers
	onHitJobs      = {}, -- I.Combat events
	onInactiveJobs = {}, -- Cleanup before the actor becomes inactive
	onSaveRevert   = {}, -- revert visual-only activeEffect modifies before serialization
	
	-- onUpdate Jobs.. but not *every* frame
	sluggishJobs     = {},
	sluggishIterator = nil,
	
	scheduleJob = nil -- function to schedule an job (G.scheduleJob(fn, delaySec))
}

local G = G

------------------------- Util -------------------------

-- wrapper for a scheduled onUpdate (sluggish) job
function G.scheduleJob(fn, delaySec)
	local runAfter = core.getSimulationTime() + (delaySec or 0)
	local key = {} --unique random key
	G.sluggishJobs[key] = function()
		if core.getSimulationTime() >= runAfter then
			G.sluggishJobs[key] = nil
			fn()
		end
	end
end

local relevanceCache = {}
local registeredEffects = {}

-- scan if a spell can *ever* contain any of our registered effects (performance optimization)
function isSpellRelevant(spell)
	local cached = relevanceCache[spell.id]
	if cached ~= nil then return cached end
	
	local source = core.magic.spells.records[spell.id] or types.Potion.records[spell.id] or types.Ingredient.records[spell.id]
	if not source and spell.item then
		local enchantId = spell.item.type.record(spell.item).enchant or ""
		source = core.magic.enchantments.records[enchantId]
	end
	if not source then
		local bookRecord = types.Book.records[spell.id]
		if bookRecord then
			local enchantId = bookRecord.enchant or ""
			source = core.magic.enchantments.records[enchantId]
		end
	end
	
	local result = false
	if not source then
		result = true
	else
		for _, eff in pairs(source.effects) do
			if registeredEffects[eff.id] then
				result = true
				break
			end
		end
	end
	relevanceCache[spell.id] = result
	return result
end

------------------------- Loading spells -------------------------

-- delayed loading of effects (performance optimization)
function loadAddons()
	for filename in vfs.pathsWithPrefix("scripts/tr_spells/shared/") do
		if filename:match("%.lua$") and not filename:match("/%._") then
			local require_path = filename:gsub("%.lua$", ""):gsub("/", ".")
			require(require_path)
		end
	end
	
	-- for relevance cache
	for _, handlers in pairs({ G.onMgefAdded, G.onMgefTick, G.onMgefRemoved, G.onAggregateReset, G.onAggregateEffect, G.onAggregateCommit }) do
		for effectId in pairs(handlers) do
			registeredEffects[effectId] = true
		end
	end
end

------------------------- ON HIT -------------------------

I.Combat.addOnHitHandler(function(attack)
	for _, fn in pairs(G.onHitJobs) do fn(attack) end
end)

------------------------- SCAN LOOP -------------------------

local nextUpdate = math.random() * 1.0

-- general spell detection
local knownSpells = {} -- [activeSpellId] = { spellId, caster, harmful, effects }
local spellTrackerPrimed = false

-- cached metadata
local spellMeta = {} -- [spellId] = { harmful, effects = { effId, ... } }

local function getSpellMeta(activeSpell)
	local meta = spellMeta[activeSpell.id]
	if meta then return meta end
	
	local source = core.magic.spells.records[activeSpell.id]
		or types.Potion.records[activeSpell.id]
		or types.Ingredient.records[activeSpell.id]
	if not source and activeSpell.item then
		local enchantId = activeSpell.item.type.record(activeSpell.item).enchant or ""
		source = core.magic.enchantments.records[enchantId]
	end
	if not source then
		local bookRecord = types.Book.records[activeSpell.id]
		if bookRecord then
			source = core.magic.enchantments.records[bookRecord.enchant or ""]
		end
	end
	
	local effects = {}
	local harmful = false
	for _, eff in ipairs(source and source.effects or activeSpell.effects) do
		local effId = eff.id and eff.id:lower()
		if effId then
			table.insert(effects, effId)
			local mgef = eff.effect or core.magic.effects.records[effId]
			if mgef and mgef.harmful then harmful = true end
		end
	end
	
	meta = { harmful = harmful, effects = effects }
	if source then spellMeta[activeSpell.id] = meta end
	return meta
end

local function notifyPlayers(eventName, payload)
	for _, p in pairs(nearby.players) do
		p:sendEvent(eventName, payload)
	end
	core.sendGlobalEvent(eventName, payload)
end

local function scanActiveSpells()
	local currentlyActive = {}
	local currentSpellIds = {}

	for _, fn in pairs(G.onAggregateReset) do
		fn()
	end
	
	for _, activeSpell in pairs(activeSpells) do
		-- per-spell add tracking, outside the relevance gate so every spell is seen
		local asId = activeSpell.activeSpellId
		currentSpellIds[asId] = true
		if not knownSpells[asId] then
			local meta = getSpellMeta(activeSpell)
			knownSpells[asId] = {
				spellId = activeSpell.id,
				caster  = activeSpell.caster,
				harmful = meta.harmful,
				effects = meta.effects,
			}
			if spellTrackerPrimed then
				notifyPlayers("TD_SpellAdded", {
					target        = self.object,
					caster        = activeSpell.caster,
					spellId       = activeSpell.id,
					activeSpellId = asId,
					harmful       = meta.harmful,
					effects       = meta.effects,
				})
			end
		end

		if isSpellRelevant(activeSpell) then
			for _, eff in pairs(activeSpell.effects) do
				local effId = eff.id and eff.id:lower() or ""
				local key = activeSpell.activeSpellId .. "_" .. effId
				local addedFn = G.onMgefAdded[effId]
				if addedFn then
					currentlyActive[key] = true
					local entry = saveData.trackedEffects[key]
					if not entry then
						entry = {
							effectId      = effId,
							spellId       = activeSpell.id,
							activeSpellId = activeSpell.activeSpellId,
							avgMagnitude  = ((eff.minMagnitude or 0) + (eff.maxMagnitude or 0))/2,
						}
						saveData.trackedEffects[key] = entry
						addedFn(key, eff, activeSpell, entry)
					else
						local tickFn = G.onMgefTick[effId]
						if tickFn then tickFn(key, eff, activeSpell, entry, CHECK_INTERVAL) end
					end
				elseif G.onMgefTick[effId] then
					currentlyActive[key] = true
					local entry = saveData.trackedEffects[key]
					if not entry then
						entry = {
							effectId      = effId,
							spellId       = activeSpell.id,
							activeSpellId = activeSpell.activeSpellId,
							avgMagnitude  = ((eff.minMagnitude or 0) + (eff.maxMagnitude or 0))/2,
						}
						saveData.trackedEffects[key] = entry
					end
					G.onMgefTick[effId](key, eff, activeSpell, entry, CHECK_INTERVAL)
				end
				
				if G.onAggregateEffect[effId] then
					G.onAggregateEffect[effId](key, eff, activeSpell)
				end
			end
		end
	end
	
	for _, fn in pairs(G.onAggregateCommit) do
		fn()
	end

	-- per-spell remove tracking
	for asId, info in pairs(knownSpells) do
		if not currentSpellIds[asId] then
			if spellTrackerPrimed then
				notifyPlayers("TD_SpellRemoved", {
					target        = self.object,
					caster        = info.caster,
					spellId       = info.spellId,
					activeSpellId = asId,
					harmful       = info.harmful,
					effects       = info.effects,
					reason        = "expired",
				})
			end
			knownSpells[asId] = nil
		end
	end
	spellTrackerPrimed = true

	for key, entry in pairs(saveData.trackedEffects) do
		if not currentlyActive[key] then
			local removedFn = G.onMgefRemoved[entry.effectId]
			if removedFn then removedFn(key, entry) end
			saveData.trackedEffects[key] = nil
		end
	end
	
	if next(G.pendingActiveSpellRemovals) then
		for _, asId in pairs(G.pendingActiveSpellRemovals) do
			activeSpells:remove(asId)
		end
		G.pendingActiveSpellRemovals = {}
	end
end

------------------------- LIFECYCLE -------------------------

local function teardownAll(reason)
	-- broadcast removal for spells still live at teardown (death, unload)
	for asId, info in pairs(knownSpells) do
		if spellTrackerPrimed then
			notifyPlayers("TD_SpellRemoved", {
				target        = self.object,
				caster        = info.caster,
				spellId       = info.spellId,
				activeSpellId = asId,
				harmful       = info.harmful,
				effects       = info.effects,
				reason        = reason,
			})
		end
	end
	knownSpells = {}
	for key, entry in pairs(saveData.trackedEffects) do
		local removedFn = G.onMgefRemoved[entry.effectId]
		if removedFn then removedFn(key, entry) end
	end
	saveData.trackedEffects = {}
	G.sluggishJobs = {}
	nextUpdate = math.huge
end

local function onUpdate(dt)
	if G.sluggishIterator ~= nil and G.sluggishJobs[G.sluggishIterator] == nil then
		G.sluggishIterator = nil
	end
	G.sluggishIterator = next(G.sluggishJobs, G.sluggishIterator)
	if G.sluggishIterator then
		G.sluggishJobs[G.sluggishIterator]()
	end
	local now = core.getSimulationTime()
	if now < nextUpdate then return end
	nextUpdate = now + CHECK_INTERVAL
	if loadedAddons then
		scanActiveSpells()
	else
		loadedAddons = true
		loadAddons()
	end
end

local function onInactive()
	for _, fn in pairs(G.onInactiveJobs) do fn() end
	teardownAll("inactive")
	core.sendGlobalEvent('TD_RemoveScript', {
		actor = self.object,
		script = SCRIPT_PATH,
	})
end

local function onLoad(data)
	saveData = data or {}
	saveData.trackedEffects = saveData.trackedEffects or {}
	saveData.knownBoundRecordIds = saveData.knownBoundRecordIds or {}
end

local function onSave()
	for key, entry in pairs(saveData.trackedEffects) do
		if entry.revertOnSave then
			local removedFn = G.onMgefRemoved[entry.effectId]
			if removedFn then removedFn(key, entry) end
			saveData.trackedEffects[key] = nil
		end
	end
	for _, fn in pairs(G.onSaveRevert) do fn() end
	return saveData
end

------------------------- RETURN -------------------------

local eventHandlers = {
	TD_RadiantShieldHitVfx = function()
		local rec = types.Static.records["t_vfx_radiantshieldhit"]
		if rec then animation.addVfx(self, rec.model) end
	end,
	TD_SummonCleanup = function(data)
		if data.key then
			saveData.trackedEffects[data.key] = nil
		end
	end,
	Died = function()
		teardownAll("died")
		G.isDead = true
	end,
}

for name, fn in pairs(G.eventHandlers) do
	eventHandlers[name] = fn
end

return {
	engineHandlers = {
		onUpdate   = onUpdate,
		onInit     = onLoad,
		onLoad     = onLoad,
		onSave     = onSave,
		onInactive = onInactive,
	},
	eventHandlers = eventHandlers,
}