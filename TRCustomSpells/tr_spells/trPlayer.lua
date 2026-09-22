core = require('openmw.core')
types = require('openmw.types')
self = require('openmw.self')
I = require('openmw.interfaces')
ui = require('openmw.ui')
util = require('openmw.util')
v2 = util.vector2
v3 = util.vector3
async = require('openmw.async')
input = require('openmw.input')
storage = require('openmw.storage')
nearby = require('openmw.nearby')
camera = require('openmw.camera')
ambient = require('openmw.ambient')
animation = require('openmw.animation')
vfs = require('openmw.vfs')
activeEffects = types.Actor.activeEffects(self)
activeSpells = types.Actor.activeSpells(self)
isPlayer = true

trData = require('scripts.tr_spells.trData')
require('scripts.tr_spells.SETTINGS')

local hasCuttingRoomFloor = core.mwscripts.records["magicsound"]

MODNAME = "TRSpells"
local UPDATE_INTERVAL = 0.15

------------------------- GLOBALS -------------------------
G = {
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
	currentUiMode              = nil,
	
	-- Generic job registries
	onHitJobs         = {}, -- (attack)
	onUseAction       = {}, -- (dt, use, sneak, run) -> nil|bool (bool overrides Use)
	uiModeChangedJobs = {}, -- (data) {oldMode, newMode, arg}
	onTeleportedJobs  = {},
	onSpellCast       = {}, -- (payload) any confirmed player cast, see SPELL CAST EVENTS
	onTouchHit        = {}, -- (payload) a touch cast resolved (hitObject may be nil)
	onProjectileHitWorld = {}, -- (payload) a target cast hit a non-actor
	eventHandlers     = {}, -- player eventHandlers
	onSaveRevert   = {}, -- revert visual-only activeEffect modifies before serialization
	
	-- onUpdate Jobs.. but not *every* frame
	sluggishJobs     = {},
	sluggishIterator = nil,
	
	-- Helpers (assigned below)
	scheduleJob            = nil,
	overrideSpell          = nil,
	registerPreviewAction  = nil,
}

local G = G

------------------------- HELPERS -------------------------

function G.scheduleJob(fn, delaySec)
	local runAfter = core.getSimulationTime() + (delaySec or 0)
	local key = {} -- unique key
	G.sluggishJobs[key] = function()
		if core.getSimulationTime() >= runAfter then
			G.sluggishJobs[key] = nil
			fn()
		end
	end
end

-- cast preview helper
function G.registerPreviewAction(opts)
	local wasHeld = false
	local ctx = nil
	local actionId = opts.id or "previewAction"..math.random()
	G.onUseAction[actionId] = function(dt, use, sneak, run)
		local ready = opts.isReady()
		if not ready then
			if wasHeld then
				wasHeld = false
				ctx = nil
				if opts.onCancel then opts.onCancel() end
			end
			return nil
		end
		
		if use then
			wasHeld = true
			ctx = ready
			if opts.onHold then opts.onHold(ctx, dt) end
			return false
		end
		
		-- Released
		if wasHeld then
			wasHeld = false
			local savedCtx = ctx
			ctx = nil
			local fire = opts.onRelease and opts.onRelease(savedCtx)
			if fire then return true end
			if opts.onCancel then opts.onCancel() end
		end
		return nil
	end
end

------------------------- SPELL MODULES -------------------------

for filename in vfs.pathsWithPrefix("scripts/tr_spells/shared/") do
	if filename:match("%.lua$") and not filename:match("/%._") then
		local require_path = filename:gsub("%.lua$", ""):gsub("/", ".")
		require(require_path)
	end
end
for filename in vfs.pathsWithPrefix("scripts/tr_spells/player/") do
	if filename:match("%.lua$") and not filename:match("/%._") then
		local require_path = filename:gsub("%.lua$", ""):gsub("/", ".")
		require(require_path)
	end
end

------------------------- SCAN LOOP -------------------------

local nextUpdate = 0

-- general spell detection
local knownSpells = {}          -- [activeSpellId] = { spellId, caster, harmful, effects }
local spellTrackerPrimed = false

-- cached metadata
local spellMeta = {}            -- [spellId] = { harmful, effects = { effId, ... } }

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
	if source then spellMeta[activeSpell.id] = meta end  -- only cache stable, record-derived data
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

	-- aggregate effects count their magnitudes themselves. reset before the scan loop
	for _, c in pairs(G.onAggregateReset) do
		c()
	end
	
	for _, activeSpell in pairs(activeSpells) do
		-- per-spell add tracking
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

		for _, eff in ipairs(activeSpell.effects) do
			local effId = eff.id and eff.id:lower() or ""
			local key = activeSpell.activeSpellId .. "_" .. effId
			
			-- lifecycle (added, ticks, removed)
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
					if tickFn then tickFn(key, eff, activeSpell, entry, UPDATE_INTERVAL) end
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
				G.onMgefTick[effId](key, eff, activeSpell, entry, UPDATE_INTERVAL)
			end
			
			-- aggregate: add up magnitudes
			if G.onAggregateEffect[effId] then
				G.onAggregateEffect[effId](key, eff, activeSpell)
			end
		end
	end
	
	-- aggregate: commit to magnitude
	for _, c in pairs(G.onAggregateCommit) do
		c()
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

	-- find expired effects
	for key, entry in pairs(saveData.trackedEffects) do
		if not currentlyActive[key] then
			local removedFn = G.onMgefRemoved[entry.effectId]
			if removedFn then removedFn(key, entry) end
			saveData.trackedEffects[key] = nil
		end
	end
	
	-- requested spell removals
	local clearPendingRemovals = false
	for _, asId in pairs(G.pendingActiveSpellRemovals) do
		activeSpells:remove(asId)
		clearPendingRemovals = true
	end
	if clearPendingRemovals then
		G.pendingActiveSpellRemovals = {}
	end
end

local function getCameraVector()
    local yaw = camera.getYaw()
    local pitch = camera.getPitch()
    local cosPitch = math.cos(pitch)
    return util.vector3(
        math.sin(yaw) * cosPitch,
        math.cos(yaw) * cosPitch,
        -math.sin(pitch)
    )
end

------------------------- SPELL CAST EVENTS -------------------------

-- TD_onSpellCast      every successful cast
-- TD_onTouchHit       touch cast hitObject may be nil
-- TD_onProjectileHitWorld  projectile hit something other than an actor

-- payload:
--   all:   { caster, spellId, itemId, effects = {{id,range,min,max,area,duration,affected}...} }
--   hits:  + position, normal, hitObject
--   proj:  + timeToHit, yaw, pitch
-- ["spellId"] is set for spell/power casts, ["itemId"] for enchant/scroll casts
-- min/max are the effect's magnitude range from the spell

local CT = nearby.COLLISION_TYPE
local IMPACT_MASK = util.bitOr(CT.World, CT.Door, CT.Actor)
local IMPACT_SPEED = core.getGMST("fTargetSpellMaxSpeed")
local IMPACT_MAX_RANGE = 72000
local IMPACT_GRACE = 0.25
local TOUCH_RANGE = core.getGMST("fCombatDistance")

local pendingImpacts = {}
local impactCounter = 0

local function handleCast(source)
	if not source then return end
	
	local effects = {}
	local hasTouch, hasTarget = false, false
	for _, eff in ipairs(source.effects) do
		table.insert(effects, { id = eff.id and eff.id:lower() or "", range = eff.range, min = eff.magnitudeMin, max = eff.magnitudeMax, area = eff.area, duration = eff.duration, affected = eff.affectedAttribute or eff.affectedSkill })
		if eff.range == core.magic.RANGE.Touch then
			hasTouch = true
		elseif eff.range == core.magic.RANGE.Target then
			hasTarget = true
		end
	end
	
	-- TD_onSpellCast
	local castPayload = { caster = self.object, spellId = source.spellId, itemId = source.itemId, effects = effects }
	for _, fn in pairs(G.onSpellCast) do fn(castPayload) end
	self:sendEvent("TD_onSpellCast", castPayload)
	
	if not (hasTouch or hasTarget) then return end
	
	local bounds = types.Actor.getPathfindingAgentBounds(self)
	local startPos = self.position + v3(0, 0, bounds.halfExtents.z * 2 * 0.75)
	local yaw = camera.getYaw()
	local pitch = camera.getPitch()
	local cosPitch = math.cos(pitch)
	local dir = v3(math.sin(yaw) * cosPitch, math.cos(yaw) * cosPitch, -math.sin(pitch))
	
	-- TD_onTouchHit
	if hasTouch then
		if I.SharedRay then
			local look = I.SharedRay.get() 
			local touchPayload = {
				caster    = self.object,
				spellId   = source.spellId,
				itemId    = source.itemId,
				position  = look.hit and look.hitPos or (startPos + dir * TOUCH_RANGE),
				normal    = look.hitNormal,
				hitObject = look.hitObject,
				effects   = effects,
			}
			for _, fn in pairs(G.onTouchHit) do fn(touchPayload) end
			self:sendEvent("TD_onTouchHit", touchPayload)
		else
			local cameraPos = camera.getPosition()
			local maxDist = (core.getGMST("iMaxActivateDist") or 192) + camera.getThirdPersonDistance()
			
			local telekinesis = types.Actor.activeEffects(self):getEffect(core.magic.EFFECT_TYPE.Telekinesis)
			if telekinesis then
				maxDist = maxDist + telekinesis.magnitude * 22
			end
			
			local endPos = cameraPos + getCameraVector() * maxDist
    
			nearby.asyncCastRenderingRay(async:callback(function(look)
				local touchPayload = {
					caster    = self.object,
					spellId   = source.spellId,
					itemId    = source.itemId,
					position  = look.hit and look.hitPos or (startPos + dir * TOUCH_RANGE),
					normal    = look.hitNormal,
					hitObject = look.hitObject,
					effects   = effects,
				}
				for _, fn in pairs(G.onTouchHit) do fn(touchPayload) end
				self:sendEvent("TD_onTouchHit", touchPayload)
			end),
			cameraPos, endPos, { ignore = self})
		end
	end
	
	-- TD_onProjectileHitWorld
	if hasTarget then
		local endPos = startPos + dir * IMPACT_MAX_RANGE
		local rayStart = startPos + dir * 10
		local solidRay = nearby.castRay(rayStart, endPos, { collisionType = IMPACT_MASK, radius = 13.9 })
		local terrainRay = nearby.castRay(startPos, endPos, { collisionType = CT.HeightMap, radius = 13.9 })
		local ray
		if solidRay.hit and terrainRay.hit then
			ray = (solidRay.hitPos - startPos):length2() < (terrainRay.hitPos - startPos):length2() and solidRay or terrainRay
		else
			ray = solidRay.hit and solidRay or terrainRay
		end
		if not ray.hit or not ray.hitPos then return end

		if ray.hitObject and types.Actor.objectIsInstance(ray.hitObject) then return end

		impactCounter = impactCounter + 1
		local id = impactCounter
		local pending = { matchId = source.spellId or source.itemId }
		pendingImpacts[id] = pending

		local timeToHit = (ray.hitPos - startPos):length() / IMPACT_SPEED
		local projPayload = {
			caster    = self.object,
			spellId   = source.spellId,
			itemId    = source.itemId,
			position  = ray.hitPos,
			normal    = ray.hitNormal,
			hitObject = ray.hitObject,
			effects   = effects,
			timeToHit = timeToHit,
			yaw       = yaw,
			pitch     = pitch,
		}
		async:newUnsavableSimulationTimer(timeToHit + IMPACT_GRACE, function()
			pendingImpacts[id] = nil
			if pending.cancelled then return end
			for _, fn in pairs(G.onProjectileHitWorld) do fn(projPayload) end
			--core.sendGlobalEvent('SpawnVfx', {model = "meshes/e/magic_area.nif", position = ray.hitPos, options = {scale  = 0.3}}) -- debug
			self:sendEvent("TD_onProjectileHitWorld", projPayload)
		end)
	end
end

local castedSource = nil
local guarranteedSuccess = false

local magicSchools = {
	alteration   = true,
	conjuration  = true,
	destruction  = true,
	illusion     = true,
	mysticism    = true,
	restoration  = true,
}

I.SkillProgression.addSkillUsedHandler(function(skillid, params)
	if magicSchools[skillid] and params.useType == I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success or skillid == "enchant" and params.useType == I.SkillProgression.SKILL_USE_TYPES.Enchant_UseMagicItem then
		handleCast(castedSource)
		castedSource = nil
	end
end)

local startKeys = {
	["self start"] = true,
	["touch start"] = true,
	["target start"] = true,
}

I.AnimationController.addTextKeyHandler("spellcast", function(groupname, key)
	if startKeys[key] then
		local spell = types.Actor.getSelectedSpell(self)
		if spell then
			castedSource = { spellId = spell.id, effects = spell.effects }
			guarranteedSuccess = spell.type == core.magic.SPELL_TYPE.Power or spell.alwaysSucceedFlag or false
		else
			local item = types.Actor.getSelectedEnchantedItem(self)
			local enchantId = item and item.type.record(item).enchant
			local ench = enchantId and core.magic.enchantments.records[enchantId]
			castedSource = ench and { itemId = item.recordId, effects = ench.effects } or nil
			guarranteedSuccess = false
		end
	elseif key:sub(-7) == "release" and castedSource and guarranteedSuccess then
		handleCast(castedSource)
		castedSource = nil
	end
end)

G.eventHandlers.TD_SpellAdded = function(data)
	if data.caster ~= self.object or data.target == self.object then return end
	for _, pending in pairs(pendingImpacts) do
		if pending.matchId == data.spellId then
			pending.cancelled = true
			break
		end
	end
end

------------------------- EVENTS -------------------------

local function onFrame(dt)
	if hasCuttingRoomFloor then
		core.sound.stopSound3d("magic sound", self)
		core.sound.playSound3d("magic sound", self, {volume = 0})
	end
	if G.sluggishIterator ~= nil and G.sluggishJobs[G.sluggishIterator] == nil then
		G.sluggishIterator = nil
	end
	G.sluggishIterator = next(G.sluggishJobs, G.sluggishIterator)
	if G.sluggishIterator then
		G.sluggishJobs[G.sluggishIterator]()
	end
	
	local now = core.getSimulationTime()
	if now < nextUpdate then return end
	nextUpdate = now + UPDATE_INTERVAL
	scanActiveSpells()
end

I.Combat.addOnHitHandler(function(attack)
	for _, fn in pairs(G.onHitJobs) do fn(attack) end
end)

input.bindAction('Use', async:callback(function(dt, use, sneak, run)
	local override
	for _, fn in pairs(G.onUseAction) do
		local r = fn(dt, use, sneak, run)
		if r ~= nil then override = r end
	end
	if override ~= nil then return override end
	return use
end), {})

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

local function uiModeChanged(data)
	G.currentUiMode = data.newMode
	for _, fn in pairs(G.uiModeChangedJobs) do fn(data) end
end

local function onTeleported()
	for _, fn in pairs(G.onTeleportedJobs) do fn() end
end

-- console command for the spell tomes
local function onConsoleCommand(mode, command)
	if command == "lua trtomes" then
		core.sendGlobalEvent('TD_GiveStartingTomes', { player = self.object })
		ui.showMessage("Spell tomes have been added to your inventory.")
	end
end

------------------------- RETURN -------------------------

local eventHandlers = {
	UiModeChanged = uiModeChanged,
}
for name, fn in pairs(G.eventHandlers) do
	eventHandlers[name] = fn
end

--eventHandlers.TD_onProjectileHitWorld = function(data)
--	print(data.spellId or data.itemId, data.hitObject)
--end

return {
	interfaceName = "TRSpells",
	interface     = {
		version = 2,  -- TD_SpellAdded / TD_SpellRemoved / TD_onSpellCast / TD_onTouchHit / TD_onProjectileHitWorld
	},
	engineHandlers = {
		onFrame          = onFrame,
		onSave           = onSave,
		onLoad           = onLoad,
		onInit           = onLoad,
		onConsoleCommand = onConsoleCommand,
		onTeleported     = onTeleported,
	},
	eventHandlers = eventHandlers,
}
-- Custom events:
-- Player + Global: TD_SpellAdded / TD_SpellRemove (spell was added to ANY actor in the world)
-- Player only: TD_onSpellCast / TD_onTouchHit / TD_onProjectileHitWorld (only for spells cast by the player)