local EFFECT_ID = "t_mysticism_banishdae"

local RECHARGE_PER_SEC = 0.05

local lastRechargeTime = nil

local function findSummoner()
	local summoner
	I.AI.forEachPackage(function(p)
		if p and p.type == "Follow" and p.target then
			summoner = p.target
		end
	end)
	if not summoner then return nil end
	for _, spell in pairs(types.Actor.activeSpells(summoner)) do
		if spell.caster and types.Player.objectIsInstance(spell.caster) then
			for _, eff in pairs(spell.effects) do
				if eff.id and eff.id:find("summon") then
					return summoner
				end
			end
		end
	end
	return nil
end

local function getBarMax()
	local level = types.Actor.stats.level(self).current
	local health = types.Actor.stats.dynamic.health(self)
	local barMax = level/2.5 + health.current/25
	return barMax
end

local function updateBanishDisplay(barMax)
	local progress = math.floor((1 - saveData.banishBar / barMax) * 100)
	if progress < 0 then progress = 0 elseif progress > 100 then progress = 100 end
	local delta = progress - (saveData.banishChameleon or 0)
	if delta ~= 0 then
		activeEffects:modify(delta, "chameleon")
		--print(activeEffects:getEffect("chameleon").magnitude)
		saveData.banishChameleon = progress
	end
end

local function clearBanishDisplay()
	local applied = saveData.banishChameleon or 0
	if applied ~= 0 then
		activeEffects:modify(-applied, "chameleon")
		saveData.banishChameleon = 0
	end
end

local function banishRegen()
	if saveData.banished or G.isDead or saveData.banishBar == nil then
		clearBanishDisplay()
		saveData.banishBar = nil
		G.sluggishJobs["banishRegen"] = nil
		lastRechargeTime = nil
		return
	end

	local barMax = getBarMax()
	local now = core.getSimulationTime()
	local elapsed = now - (lastRechargeTime or now)
	if elapsed < 0 then elapsed = 0 end
	lastRechargeTime = now
	saveData.banishBar = saveData.banishBar + barMax * RECHARGE_PER_SEC * elapsed

	if saveData.banishBar >= barMax then
		saveData.banishBar = nil
		clearBanishDisplay()
		G.sluggishJobs["banishRegen"] = nil
		lastRechargeTime = nil
		return
	end

	updateBanishDisplay(barMax)
end

G.onMgefAdded[EFFECT_ID] = function(key, eff, activeSpell, entry)
	if not types.Creature.objectIsInstance(self) then return end
	local rec = types.Creature.record(self)
	if not rec or rec.type ~= types.Creature.TYPE.Daedra then return end

	entry.isTarget = true

	local caster = activeSpell and activeSpell.caster or nil
	local summoner = findSummoner()
	local isOwnSummon = summoner and caster and summoner == caster
	entry.mult = isOwnSummon and 2 or 1

	local barMax = getBarMax()
	if saveData.banishBar == nil then
		saveData.banishBar = isOwnSummon and barMax * 0.5 or barMax
		lastRechargeTime = core.getSimulationTime()
	end

	G.sluggishJobs["banishRegen"] = banishRegen
	updateBanishDisplay(barMax)

	local area = eff.area or 0
	if area > 0 then
		local areaStatic = eff.effect and eff.effect.areaStatic or nil
		local areaRec = areaStatic and types.Static.records[areaStatic] or nil
		if areaRec then
			core.sendGlobalEvent('SpawnVfx', {
				model = areaRec.model,
				position = self.position,
				options = { scale = area * 1.1 },
			})
		end
	end
end

G.onMgefTick[EFFECT_ID] = function(key, eff, activeSpell, entry, interval)
	if not entry.isTarget then return end
	if saveData.banished then return end

	local barMax = getBarMax()
	if saveData.banishBar == nil then
		saveData.banishBar = barMax
		lastRechargeTime = core.getSimulationTime()
	end
	
	local baseMag = eff.magnitudeThisFrame or entry.avgMagnitude or 10
	local tickMag = baseMag * interval * entry.mult
	
	local health = types.Actor.stats.dynamic.health(self)
	health.current = health.current - tickMag * 1.5
	
	G.sluggishJobs["banishRegen"] = banishRegen

	local mag = eff.magnitudeThisFrame or entry.avgMagnitude or 10
	saveData.banishBar = saveData.banishBar - mag * interval * entry.mult

	if saveData.banishBar <= 0 then
		saveData.banishBar = 0
		saveData.banished = true
		G.sluggishJobs["banishRegen"] = nil
		--types.Actor.stats.dynamic.health(self).current = 0
		local banishVfx = types.Static.records["t_vfx_banish"]
		if banishVfx then animation.addVfx(self, banishVfx.model) end
		core.sound.playSound3d("mysticism area", self)
		async:newUnsavableSimulationTimer(0.1, function()
			core.sendGlobalEvent('TD_BanishDelete', { actor = self.object, caster = activeSpell.caster })
		end)
		return
	end

	updateBanishDisplay(barMax)
end

if G.onInactiveJobs then
	G.onInactiveJobs.banish = function()
		clearBanishDisplay()
		G.sluggishJobs["banishRegen"] = nil
	end
end

if G.onSaveRevert then
	G.onSaveRevert.banish = clearBanishDisplay
end
