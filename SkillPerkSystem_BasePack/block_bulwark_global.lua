-- Superseded by scripts/SkillPerkSystem_BasePack/basepack_global.lua; kept temporarily for save/development compatibility.
local core = require("openmw.core")
local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local Creature = types.Creature

local BULWARK_DAMAGE_SPELL_ID = "sps_Bullareadmg"
local BULWARK_RADIUS = 384

-- If these do not resolve in your setup, try the full asset paths instead:
-- "meshes\\magic_hit_dst.nif" and "Sound\\Fx\\destH.wav"
local BULWARK_HIT_VFX_MODEL = "meshes\\e\\magic_hit_dst.nif"
local BULWARK_HIT_SOUND_FILE = "Sound\\Fx\\magic\\destH.wav"

local function isUndeadOrDaedra(actor)
    if actor == nil then
        return false
    end
    if not Creature.objectIsInstance(actor) then
        return false
    end

    local record = Creature.record(actor)
    if record == nil then
        return false
    end

    return record.type == Creature.TYPE.Undead or record.type == Creature.TYPE.Daedra
end

local function isWithinRadius(source, target, radius)
    if source == nil or target == nil then
        return false
    end

    local sourcePos = source.position
    local targetPos = target.position
    if sourcePos == nil or targetPos == nil then
        return false
    end

    local dx = targetPos.x - sourcePos.x
    local dy = targetPos.y - sourcePos.y
    local dz = targetPos.z - sourcePos.z
    local distanceSquared = dx * dx + dy * dy + dz * dz
    return distanceSquared <= (radius * radius)
end

local function addHitVfx(target)
    if target == nil then
        return
    end

    target:sendEvent("AddVfx", {
        model = BULWARK_HIT_VFX_MODEL,
        options = {
            vfxId = "sps_bulwark_hit_vfx",
            loop = false,
        }
    })
end

local function playHitSound(target)
    if target == nil then
        return
    end

    core.sound.playSoundFile3d(BULWARK_HIT_SOUND_FILE, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
end

local function applyBulwarkSmite(blocker, target)
    Actor.activeSpells(target):add({
        id = BULWARK_DAMAGE_SPELL_ID,
        effects = { 0 },
        caster = blocker,
        stackable = true,
    })

    addHitVfx(target)
    playHitSound(target)
end

local function onApplyBulwarkOfLight(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    if blocker == nil then
        return
    end

    for _, actor in ipairs(world.activeActors) do
        if actor ~= nil
            and actor ~= blocker
            and not Actor.isDead(actor)
            and isUndeadOrDaedra(actor)
            and isWithinRadius(blocker, actor, BULWARK_RADIUS)
        then
            applyBulwarkSmite(blocker, actor)
        end
    end
end

return {
    eventHandlers = {
        SkillPerkSystem_ApplyBulwarkOfLight = onApplyBulwarkOfLight,
    },
}
