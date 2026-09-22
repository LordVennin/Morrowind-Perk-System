-- kills an actor by turning it into a skeleton
-- t_de_uni_staffveloth

if isPlayer then return end

local EFFECT_ID = "t_destruction_gazeofveloth"

G.onMgefAdded[EFFECT_ID] = function(key, eff, activeSpell, entry)
	local caster = activeSpell and activeSpell.caster
	local name = self.type.record(self).name
	
	-- dead - fail
	if types.Actor.isDead(self) then
		table.insert(G.pendingActiveSpellRemovals, activeSpell.activeSpellId)
		return
	end
	
	-- explicitly immune - fail
	if trData.GAZE_VELOTH_IMMUNE[self.recordId:lower()] then
		if caster then
			caster:sendEvent('ShowMessage', { message = name .. " transcends the Face of Veloth!" })
		end
		table.insert(G.pendingActiveSpellRemovals, activeSpell.activeSpellId)
		return
	end
	
	-- creatures - fail
	if not types.NPC.objectIsInstance(self) then
		local id = self.recordId:lower()
		local ctype = types.Creature.record(self).type
		local message
		if id:find("dagoth_ur") then
			message = "Dagoth Ur laughs at the Face of Veloth!"
		elseif ctype == types.Creature.TYPE.Humanoid
			and (id:find("ash_") or id:find("dagoth_") or id:find("corprus_") or id == "ascended_sleeper")
		then
			message = name .. " has no mortal link to the Face of Veloth!"
		elseif ctype == types.Creature.TYPE.Daedra then
			message = name .. " does not care about the Face of Veloth!"
		else
			message = name .. " cannot comprehend the Face of Veloth!"
		end
		if caster then
			caster:sendEvent('ShowMessage', { message = message })
		end
		table.insert(G.pendingActiveSpellRemovals, activeSpell.activeSpellId)
		return
	end
	
	-- humanoid
	core.sound.playSound3d("destruction hit", self)
	types.Actor.stats.dynamic.health(self).current = 0
	
	core.sendGlobalEvent('TD_GazeOfVeloth', {
		actor  = self.object,
		caster = caster,
		race   = types.NPC.record(self).race:lower(),
	})
	table.insert(G.pendingActiveSpellRemovals, activeSpell.activeSpellId)
end
