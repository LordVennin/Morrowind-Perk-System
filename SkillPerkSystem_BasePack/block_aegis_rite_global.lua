local core = require("openmw.core")

local AEGIS_RITE_TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/aegis_rite_target.lua"
local AEGIS_RITE_SMITE_SPELL_ID = "sps_MeleeSmite"
local AEGIS_RITE_HIT_VFX_MODEL = "meshes\\e\\magic_hit_dst.nif"
local AEGIS_RITE_HIT_SOUND_FILE = "Sound\\Fx\\magic\\destH.wav"

local function addHitVfx(target)
    if target == nil then
        return
    end

    target:sendEvent("AddVfx", {
        model = AEGIS_RITE_HIT_VFX_MODEL,
        options = {
            vfxId = "sps_aegis_rite_hit_vfx",
            loop = false,
        }
    })
end

local function playHitSound(target)
    if target == nil then
        return
    end

    core.sound.playSoundFile3d(AEGIS_RITE_HIT_SOUND_FILE, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
end

local function onPrimeAegisRite(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    local attacker = e.attacker
    local duration = tonumber(e.duration) or 3.0

    if blocker == nil or attacker == nil then
        return
    end
    if not attacker:isValid() then
        return
    end

    local initData = {
        playerId = blocker.id,
        duration = duration,
    }

    if attacker:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        attacker:sendEvent("SkillPerkSystem_AegisRiteRefresh", initData)
    else
        attacker:addScript(AEGIS_RITE_TARGET_SCRIPT, initData)
    end
end

local function onApplyAegisRiteEffect(e)
    if type(e) ~= "table" then
        return
    end

    local attacker = e.attacker
    local target = e.target
    if attacker == nil or target == nil then
        return
    end
    if not target:isValid() then
        return
    end

    local Actor = require("openmw.types").Actor
    Actor.activeSpells(target):add({
        id = AEGIS_RITE_SMITE_SPELL_ID,
        effects = { 0 },
        caster = attacker,
        stackable = true,
    })

    addHitVfx(target)
    playHitSound(target)

    if target:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        target:removeScript(AEGIS_RITE_TARGET_SCRIPT)
    end
end

local function onRemoveAegisRiteTarget(e)
    if type(e) ~= "table" then
        return
    end

    local target = e.target
    if target == nil then
        return
    end
    if not target:isValid() then
        return
    end
    if not target:hasScript(AEGIS_RITE_TARGET_SCRIPT) then
        return
    end

    target:removeScript(AEGIS_RITE_TARGET_SCRIPT)
end

return {
    eventHandlers = {
        SkillPerkSystem_PrimeAegisRite = onPrimeAegisRite,
        SkillPerkSystem_ApplyAegisRiteEffect = onApplyAegisRiteEffect,
        SkillPerkSystem_RemoveAegisRiteTarget = onRemoveAegisRiteTarget,
    },
}
