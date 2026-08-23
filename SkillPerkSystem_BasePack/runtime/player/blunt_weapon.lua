-- Blunt Weapon player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_animation = require("scripts.SkillPerkSystem_BasePack.runtime.animation")
local multiplyAnimationSpeed = __basepack_animation.multiplyAnimationSpeed
local registerBasepackAnimationHandler = __basepack_animation.registerHandler
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local STRENGTH_IN_ARMS_PERK_ID = "bluntweapon_strength_in_arms"
local PLATEBREAKER_PERK_ID = "bluntweapon_platebreaker"
local BREATHSTEALER_PERK_ID = "bluntweapon_breathstealer"
local HEAVY_HITTER_PERK_ID = "bluntweapon_heavy_hitter"
local GUARDED_STAMINA_PERK_ID = "bluntweapon_placeholder_guarded_stance"
local STAGGERING_BLOW_PERK_ID = "bluntweapon_placeholder_staggering_blow"
local IRON_BELL_PERK_ID = "bluntweapon_iron_bell"
local STATE_EVENT = "SkillPerkSystem_BluntWeaponStrengthInArmsState"
local GUARDED_STAMINA_REFUND_MULTIPLIER = 0.25
local GUARDED_STAMINA_ATTACK_WINDOW = 5.0
local STAGGERING_BLOW_CHOP_ATTACK_SPEED_MULTIPLIER = 0.70

local bluntStateDirty = true
local lastStateKey = nil
local lastAnimationLogKey = nil
local guardedStaminaAttackState = nil

local function hasEnabledPerk(perkID)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end

    if not playerApi.hasPerk(perkID) then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkID)
    end

    return true
end

local function getStrengthDamageBonus()
    local attributes = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.attributes or nil
    local strengthAccessor = attributes ~= nil and attributes.strength or nil
    if type(strengthAccessor) ~= "function" then
        return 0
    end

    local stat = strengthAccessor(pself)
    local strength = stat ~= nil and tonumber(stat.modified) or nil
    if strength == nil then
        strength = stat ~= nil and tonumber(stat.base) or 0
    end

    return math.max(0, math.floor(strength / 10))
end

local function getEquippedItem(actor, slot)
    local Actor = types.Actor
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getWeaponRecord(item)
    local Weapon = types.Weapon
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local okRecord, record = pcall(Weapon.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Weapon.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function weaponTypeEquals(record, typeName)
    local Weapon = types.Weapon
    if record == nil or Weapon == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE[typeName])
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isBluntWeaponRecord(record)
    return weaponTypeEquals(record, "BluntOneHand")
        or weaponTypeEquals(record, "BluntTwoClose")
        or weaponTypeEquals(record, "BluntTwoWide")
end

local function getEquippedBluntWeaponRecord()
    local Actor = types.Actor
    local Weapon = types.Weapon
    if Actor == nil or Weapon == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil
    end

    local weapon = getEquippedItem(pself, Actor.EQUIPMENT_SLOT.CarriedRight)
    if weapon == nil then
        return nil
    end

    if type(Weapon.objectIsInstance) == "function" and not Weapon.objectIsInstance(weapon) then
        return nil
    end

    local record = getWeaponRecord(weapon)
    if not isBluntWeaponRecord(record) then
        return nil
    end

    return record
end

local function getCurrentFatigue()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return nil
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return nil
    end

    return tonumber(fatigue.current), fatigue
end

local function getMaxFatigue(fatigue)
    if fatigue == nil then
        return nil
    end

    local base = tonumber(fatigue.base) or 0
    local modifier = tonumber(fatigue.modifier) or 0
    return math.max(0, base + modifier)
end

local function isAttackReleaseTextKey(key)
    if type(key) ~= "string" then
        return false
    end

    local normalized = string.lower(key)
    return normalized == "chop max attack"
        or normalized == "slash max attack"
        or normalized == "thrust max attack"
        or normalized:find(" max attack$") ~= nil
        or (normalized:find("hit$") ~= nil and normalized:find("min hit$") == nil)
end

local function armGuardedStaminaRefund(event)
    local current = getCurrentFatigue()
    if current == nil then
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState = {
        elapsed = 0,
        lastFatigue = current,
        releaseSeen = isAttackReleaseTextKey(event.stopKey),
    }
end

local function clearInvalidGuardedStaminaState(bluntWeapon)
    if guardedStaminaAttackState == nil then
        return
    end
    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or bluntWeapon == nil then
        guardedStaminaAttackState = nil
    end
end

local function handleBluntAnimation(event)
    local needsBluntWeapon = event.isBluntAttackShape or event.isChopAttackWindup
    local bluntWeapon = nil

    if guardedStaminaAttackState ~= nil or needsBluntWeapon then
        bluntWeapon = getEquippedBluntWeaponRecord()
    end

    clearInvalidGuardedStaminaState(bluntWeapon)

    if event.isBluntAttackShape and hasEnabledPerk(GUARDED_STAMINA_PERK_ID) and bluntWeapon ~= nil then
        armGuardedStaminaRefund(event)
    end

    if event.isChopAttackWindup and hasEnabledPerk(STAGGERING_BLOW_PERK_ID) and bluntWeapon ~= nil then
        multiplyAnimationSpeed(event.options, STAGGERING_BLOW_CHOP_ATTACK_SPEED_MULTIPLIER)
    end
end
registerBasepackAnimationHandler(handleBluntAnimation)

__basepack_animation.setTextKeyHandler(function(_, key)
    if guardedStaminaAttackState == nil then
        return
    end
    if not isAttackReleaseTextKey(key) then
        return
    end
    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or getEquippedBluntWeaponRecord() == nil then
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState.releaseSeen = true
end)

local function processGuardedStaminaRefund(dt)
    if guardedStaminaAttackState == nil then
        return
    end

    guardedStaminaAttackState.elapsed = (tonumber(guardedStaminaAttackState.elapsed) or 0) + (tonumber(dt) or 0)

    local current, fatigue = getCurrentFatigue()
    if current == nil then
        guardedStaminaAttackState = nil
        return
    end

    if not hasEnabledPerk(GUARDED_STAMINA_PERK_ID) or getEquippedBluntWeaponRecord() == nil then
        guardedStaminaAttackState = nil
        return
    end

    local before = tonumber(guardedStaminaAttackState.lastFatigue) or current
    local spent = before - current
    if spent > 0 then
        local refund = spent * GUARDED_STAMINA_REFUND_MULTIPLIER
        local maxFatigue = getMaxFatigue(fatigue) or before
        fatigue.current = math.min(maxFatigue, before, current + refund)
        guardedStaminaAttackState = nil
        return
    end

    guardedStaminaAttackState.lastFatigue = math.max(before, current)

    if guardedStaminaAttackState.elapsed >= GUARDED_STAMINA_ATTACK_WINDOW then
        guardedStaminaAttackState = nil
    end
end

local BLUNT_STATE_PERKS = {
    bluntweapon_strength_in_arms = true,
    bluntweapon_platebreaker = true,
    bluntweapon_breathstealer = true,
    bluntweapon_heavy_hitter = true,
    bluntweapon_placeholder_guarded_stance = true,
    bluntweapon_placeholder_staggering_blow = true,
    bluntweapon_iron_bell = true,
}

local function markBluntStateDirty()
    bluntStateDirty = true
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or BLUNT_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markBluntStateDirty()
end

local function shouldUpdateBlunt()
    return bluntStateDirty or guardedStaminaAttackState ~= nil
end

local function publishState(force)
    local strengthInArmsEnabled = hasEnabledPerk(STRENGTH_IN_ARMS_PERK_ID)
    local damageBonus = strengthInArmsEnabled and getStrengthDamageBonus() or 0
    local platebreakerEnabled = hasEnabledPerk(PLATEBREAKER_PERK_ID)
    local breathstealerEnabled = hasEnabledPerk(BREATHSTEALER_PERK_ID)
    local heavyHitterEnabled = hasEnabledPerk(HEAVY_HITTER_PERK_ID)
    local guardedStaminaEnabled = hasEnabledPerk(GUARDED_STAMINA_PERK_ID)
    local staggeringBlowEnabled = hasEnabledPerk(STAGGERING_BLOW_PERK_ID)
    local ironBellEnabled = hasEnabledPerk(IRON_BELL_PERK_ID)
    local stateKey = tostring(strengthInArmsEnabled)
        .. ":"
        .. tostring(damageBonus)
        .. ":"
        .. tostring(platebreakerEnabled)
        .. ":"
        .. tostring(breathstealerEnabled)
        .. ":"
        .. tostring(heavyHitterEnabled)
        .. ":"
        .. tostring(guardedStaminaEnabled)
        .. ":"
        .. tostring(staggeringBlowEnabled)
        .. ":"
        .. tostring(ironBellEnabled)
    if not force and stateKey == lastStateKey then
        return
    end

    lastStateKey = stateKey
    core.sendGlobalEvent(STATE_EVENT, {
        playerId = pself.id,
        strengthInArmsEnabled = strengthInArmsEnabled,
        enabled = strengthInArmsEnabled,
        damageBonus = damageBonus,
        platebreakerEnabled = platebreakerEnabled,
        breathstealerEnabled = breathstealerEnabled,
        heavyHitterEnabled = heavyHitterEnabled,
        guardedStaminaEnabled = guardedStaminaEnabled,
        staggeringBlowEnabled = staggeringBlowEnabled,
        ironBellEnabled = ironBellEnabled,
    })
end

__basepack_subsystem_result = {
    engineHandlers = {
        onUpdate = function(dt)
            if guardedStaminaAttackState ~= nil then
                processGuardedStaminaRefund(dt)
            end
            if bluntStateDirty then
                bluntStateDirty = false
                publishState(false)
            end
        end,
        shouldUpdate = shouldUpdateBlunt,
        onLoad = function()
            lastStateKey = nil
            bluntStateDirty = true
            publishState(true)
            bluntStateDirty = false
        end,
    },
    eventHandlers = {
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_BluntWeaponStateDirty = function() markBluntStateDirty() end,
        UiModeChanged = function() markBluntStateDirty() end,
    },
}


return __basepack_subsystem_result
