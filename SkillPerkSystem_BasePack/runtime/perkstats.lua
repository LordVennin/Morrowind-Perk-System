-- Shared stat and player-state helpers for SkillPerkSystem_BasePack runtimes.
--
-- Every perk tree needs the same handful of primitives: is this perk active,
-- reach a skill/attribute/dynamic stat, apply a revertible modifier, and read
-- cheap player state such as encumbrance or sneak. Keeping them here means a new
-- tree module spends its local budget on the perk logic rather than on
-- boilerplate, and there is one place to fix an API accessor if OpenMW moves it.
--
-- Required from the player script only, so all tree modules share one instance.

local pself = require("openmw.self")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local Actor = types.Actor
local NPC = types.NPC
local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"

local M = {}

-- A perk counts as active only when it is both owned and not refunded/disabled.
function M.enabled(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end
    if type(playerApi.hasPerk) == "function" and not playerApi.hasPerk(perkId) then
        return false
    end
    if type(playerApi.isPerkEffectEnabled) == "function" and not playerApi.isPerkEffectEnabled(perkId) then
        return false
    end
    return true
end

function M.skillStat(skillId)
    local skills = NPC ~= nil and NPC.stats ~= nil and NPC.stats.skills or nil
    local accessor = skills ~= nil and skills[skillId] or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

function M.attributeStat(attributeId)
    local attributes = Actor ~= nil and Actor.stats ~= nil and Actor.stats.attributes or nil
    local accessor = attributes ~= nil and attributes[attributeId] or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

function M.dynamicStat(name)
    local dynamic = Actor ~= nil and Actor.stats ~= nil and Actor.stats.dynamic or nil
    local accessor = dynamic ~= nil and dynamic[name] or nil
    return type(accessor) == "function" and accessor(pself) or nil
end

function M.fatigueStat()
    return M.dynamicStat("fatigue")
end

-- Adjusts stat.modifier by the delta between what this subsystem last applied
-- and what it wants applied now, so other contributors are left untouched and a
-- refunded perk reverts exactly its own share. Returns the new applied amount.
function M.setModifier(stat, current, desired)
    desired = math.max(0, math.floor(tonumber(desired) or 0))
    current = math.max(0, math.floor(tonumber(current) or 0))
    if desired == current then
        return current
    end
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end
    stat.modifier = stat.modifier - current + desired
    return desired
end

-- Fraction of carrying capacity in use, 0 when capacity is unavailable.
function M.encumbranceRatio()
    if Actor == nil or type(Actor.getEncumbrance) ~= "function" or type(Actor.getCapacity) ~= "function" then
        return 0
    end
    local okLoad, load = pcall(Actor.getEncumbrance, pself)
    local okCapacity, capacity = pcall(Actor.getCapacity, pself)
    if not okLoad or not okCapacity then
        return 0
    end
    capacity = tonumber(capacity) or 0
    if capacity <= 0 then
        return 0
    end
    return (tonumber(load) or 0) / capacity
end

-- Fraction of maximum fatigue remaining, plus the maximum itself.
--
-- ownModifier is this subsystem's own contribution to maximum fatigue; it is
-- excluded from the denominator so that a perk which raises maximum fatigue does
-- not silently move every fatigue threshold in its own tree.
function M.fatigueRatio(fatigue, ownModifier)
    if fatigue == nil then
        return 0, 0
    end
    local maxFatigue = math.max(0, (tonumber(fatigue.base) or 0) + (tonumber(fatigue.modifier) or 0))
    local naturalMax = math.max(0, maxFatigue - math.max(0, tonumber(ownModifier) or 0))
    if naturalMax <= 0 then
        return 0, maxFatigue
    end
    return (tonumber(fatigue.current) or 0) / naturalMax, maxFatigue
end

-- Reads a boolean-ish player control field (sneak, run, jump, use).
function M.controlActive(key)
    local ok, value = pcall(function() return pself.controls[key] end)
    return ok and value ~= nil and value ~= false and value ~= 0
end

function M.isSneaking()
    return M.controlActive("sneak")
end

function M.isOnGround()
    if Actor == nil or type(Actor.isOnGround) ~= "function" then
        return true
    end
    local ok, grounded = pcall(Actor.isOnGround, pself)
    return not ok or grounded ~= false
end

function M.isSwimming()
    if Actor == nil or type(Actor.isSwimming) ~= "function" then
        return false
    end
    local ok, swimming = pcall(Actor.isSwimming, pself)
    return ok and swimming == true
end

function M.position()
    local ok, position = pcall(function() return pself.position end)
    return ok and position or nil
end

-- Squared distance between two positions, or nil when either is missing.
function M.distanceSquared(a, b)
    if a == nil or b == nil then
        return nil
    end
    local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
    local dy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
    local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
    return dx * dx + dy * dy + dz * dz
end

-- True when an item is equipped in the given slot and passes the optional test.
function M.equippedInSlot(slotName, test)
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    local slot = slots ~= nil and slots[slotName] or nil
    if slot == nil or type(Actor.getEquipment) ~= "function" then
        return false
    end
    local ok, item = pcall(Actor.getEquipment, pself, slot)
    if not ok or item == nil then
        return false
    end
    if test == nil then
        return true
    end
    local okTest, result = pcall(test, item)
    return okTest and result == true
end

return M
