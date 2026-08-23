-- Block Runtime player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_shared_state = require("scripts.SkillPerkSystem_BasePack.runtime.shared")
local __basepack_shared = __basepack_shared_state.shared
local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Weapon = types.Weapon
local Lockpick = types.Lockpick
local Probe = types.Probe
local Repair = types.Repair

-- Perk ids, tuning values, and save-state keys live in one table so this
-- module stays clear of Lua's 200-local-per-chunk limit.
local K = {
    PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer",
    LOG_TAG = "[SkillPerkSystem_BasePack][BlockEnchant]",
    HALLOWED_GUARD_PERK_ID = "block_hallowed_guard",
    SHIELD_FUNDAMENTALS_PERK_ID = "block_shield_fundamentals",
    GUARDIANS_HABIT_PERK_ID = "block_guardians_habit",
    STEADY_WALL_PERK_ID = "block_steady_wall",
    BULWARK_OF_LIGHT_PERK_ID = "block_bulwark_of_light",
    AEGIS_RITE_PERK_ID = "block_aegis_rite",
    SPEAR_LONG_GUARD_PERK_ID = "spear_long_guard",
    UNARMORED_UNBURDENED_FORM_PERK_ID = "unarmored_unburdened_form",
    UNARMORED_FLOWING_STEP_PERK_ID = "unarmored_flowing_step",
    UNARMORED_SILK_GUARD_PERK_ID = "unarmored_silk_guard",
    UNARMORED_EMPTY_MAIL_PERK_ID = "unarmored_empty_mail",
    UNARMORED_MASTER_OF_MOTION_PERK_ID = "unarmored_master_of_motion",
    LIGHTARMOR_QUICK_BUCKLE_PERK_ID = "lightarmor_quick_buckle",
    LIGHTARMOR_SOFT_LANDING_PERK_ID = "lightarmor_soft_landing",
    LIGHTARMOR_SKIRMISHER_STRIDE_PERK_ID = "lightarmor_skirmisher_stride",
    LIGHTARMOR_GLANCING_ANGLE_PERK_ID = "lightarmor_glancing_angle",
    LIGHTARMOR_SECOND_SKIN_PERK_ID = "lightarmor_second_skin",
    CONFIG_SECTION_ID = "SkillPerkSystem_BasePack_BlockEnchant",
    DEBUG_LOGGING_KEY = "block.enchant.debug",
    DEFAULT_DEBUG_LOGGING = false,
    STEADY_WALL_MAX_STACKS = 5,
    STEADY_WALL_DURATION = 5.0,
    STEADY_WALL_BLOCK_PER_STACK = 4,
    STEADY_WALL_ARMOR_PER_STACK = 3,
    BLOCK_STATE_REFRESH_INTERVAL = 0.5,
    UNARMORED_FLOWING_STEP_AGILITY_BONUS = 5,
    UNARMORED_FLOWING_STEP_HIGH_FATIGUE_AGILITY_BONUS = 10,
    UNARMORED_FLOWING_STEP_HIGH_FATIGUE_THRESHOLD = 0.75,
    UNARMORED_SILK_GUARD_ATTRIBUTE_BONUS = 3,
    UNARMORED_SILK_GUARD_HIGH_FATIGUE_ATTRIBUTE_BONUS = 5,
    UNARMORED_SILK_GUARD_HIGH_FATIGUE_THRESHOLD = 0.75,
    UNARMORED_MASTER_OF_MOTION_FATIGUE_RESTORE_PER_SECOND = 1,
    UNARMORED_MASTER_OF_MOTION_MIN_FATIGUE_THRESHOLD = 0.5,
    LIGHTARMOR_SOFT_LANDING_ACROBATICS_BONUS = 10,
    LIGHTARMOR_SKIRMISHER_STRIDE_FATIGUE_RESTORE = 10,
    LIGHTARMOR_GLANCING_ANGLE_MAX_STACKS = 3,
    LIGHTARMOR_GLANCING_ANGLE_DURATION = 5.0,
    LIGHTARMOR_GLANCING_ANGLE_AGILITY_PER_STACK = 5,
    UNARMORED_FLOWING_STEP_APPLIED_KEY = "unarmored.flowing_step.applied_agility_bonus",
    UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY = "unarmored.silk_guard.applied_endurance_bonus",
    UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY = "unarmored.silk_guard.applied_willpower_bonus",
    LIGHTARMOR_SOFT_LANDING_ACROBATICS_APPLIED_KEY = "lightarmor.soft_landing.applied_acrobatics_bonus",
    LIGHTARMOR_GLANCING_ANGLE_AGILITY_APPLIED_KEY = "lightarmor.glancing_angle.applied_agility_bonus",
    LIGHTARMOR_GLANCING_ANGLE_STACKS_SAVE_KEY = "lightarmor.glancing_angle.stack_remaining_times",
    LIGHTARMOR_SECOND_SKIN_FEATHER_APPLIED_KEY = "lightarmor.second_skin.applied_feather_bonus",
    HALLOWED_GUARD_ABILITY_ID = "sps_hallowedguard",
    UNARMORED_EMPTY_MAIL_ABILITY_ID = "sps_unarmoredbuff",
    BULWARK_SELF_SPELL_ID = "sps_bullightself",
    AEGIS_RITE_WINDOW = 3.0,
    AEGIS_RITE_MAGICKA_COST = 5,
}






local configSection = storage.playerSection(K.CONFIG_SECTION_ID)
local baseCombatInterface = nil
local momentumExpirations = {}
local runtimeTime = 0
local hallowedGuardApplied = false
local hallowedGuardAddFailureLogged = false
local hallowedGuardRemoveFailureLogged = false
local unarmoredEmptyMailApplied = false
local unarmoredEmptyMailAddFailureLogged = false
local unarmoredEmptyMailRemoveFailureLogged = false
local hallowedGuardSpellBookFailureState = nil
local blockStateRefreshTimer = K.BLOCK_STATE_REFRESH_INTERVAL
local blockStateRefreshDue = false
local appliedUnarmoredFlowingStepAgilityBonus = 0
local appliedUnarmoredSilkGuardEnduranceBonus = 0
local appliedUnarmoredSilkGuardWillpowerBonus = 0
local appliedSoftLandingAcrobaticsBonus = 0
local appliedGlancingAngleAgilityBonus = 0
local appliedSecondSkinFeatherBonus = 0
local glancingAngleExpirations = {}

local function logDebug(message)
    if configSection:get(K.DEBUG_LOGGING_KEY) == true then
        print(string.format("%s[debug] %s", K.LOG_TAG, tostring(message)))
    end
end

local function getBaseCombatFunction(name)
    if baseCombatInterface == nil then
        return nil
    end

    local fn = baseCombatInterface[name]
    if type(fn) == "function" then
        return fn
    end

    return nil
end

local function passthrough(name)
    return function(...)
        local fn = getBaseCombatFunction(name)
        if fn ~= nil then
            return fn(...)
        end
        return nil
    end
end

local function getEquippedItem(actor, slot)
    if actor == nil or Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local ok, equipped = pcall(Actor.getEquipment, actor, slot)
    if not ok then
        return nil
    end

    return equipped
end

local function getEquippedShield(actor)
    if actor == nil or Actor == nil then
        return nil, nil
    end

    local carriedLeftSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedLeft or nil
    if carriedLeftSlot == nil then
        return nil, nil
    end

    local equipped = getEquippedItem(actor, carriedLeftSlot)
    if equipped == nil then
        return nil, nil
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return nil, nil
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, equipped)
        if okRecord then
            record = value
        end
    end

    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil, nil
    end

    return equipped, record
end

local function getEquippedRightHand(actor)
    if actor == nil or Actor == nil then
        return nil
    end

    local rightSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedRight or nil
    if rightSlot == nil then
        return nil
    end

    return getEquippedItem(actor, rightSlot)
end

local function getWeaponRecord(item)
    if item == nil or Weapon == nil then
        return nil
    end

    if type(Weapon.record) == "function" then
        local ok, record = pcall(Weapon.record, item)
        if ok and record ~= nil then
            return record
        end
    end

    if type(item.recordId) == "string" and type(Weapon.records) == "table" then
        return Weapon.records[item.recordId]
    end

    return nil
end

local function isOneHandedWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil then
        return true
    end

    local weaponType = tonumber(record.type)
    if weaponType == nil then
        return true
    end

    if weaponType == 2 then return false end
    if weaponType == 4 then return false end
    if weaponType == 5 then return false end
    if weaponType == 6 then return false end
    if weaponType == 8 then return false end
    if weaponType == 9 then return false end
    if weaponType == 10 then return false end
    if weaponType == 11 then return false end
    if weaponType == 12 then return false end
    if weaponType == 13 then return false end

    return true
end

local function isSpearWeapon(item)
    if item == nil or Weapon == nil or type(Weapon.objectIsInstance) ~= "function" or not Weapon.objectIsInstance(item) then
        return false
    end

    local record = getWeaponRecord(item)
    if record == nil or Weapon.TYPE == nil then
        return false
    end

    local expected = tonumber(Weapon.TYPE.SpearTwoWide)
    local actual = tonumber(record.type)
    return expected ~= nil and actual ~= nil and actual == expected
end

local function isTool(item)
    if item == nil then
        return false
    end

    if Lockpick ~= nil and type(Lockpick.objectIsInstance) == "function" and Lockpick.objectIsInstance(item) then
        return true
    end
    if Probe ~= nil and type(Probe.objectIsInstance) == "function" and Probe.objectIsInstance(item) then
        return true
    end
    if Repair ~= nil and type(Repair.objectIsInstance) == "function" and Repair.objectIsInstance(item) then
        return true
    end

    return false
end

local function perkOwned(perkId)
    local playerApi = interfaces[K.PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    return type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId) or false
end

local function perkEffectEnabled(perkId)
    if not perkOwned(perkId) then
        return false
    end

    local playerApi = interfaces[K.PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkId)
    end

    return true
end

local function hallowedGuardEnabled()
    return perkEffectEnabled(K.HALLOWED_GUARD_PERK_ID)
end

local function shieldFundamentalsEnabled()
    return perkEffectEnabled(K.SHIELD_FUNDAMENTALS_PERK_ID)
end

local function guardiansHabitEnabled()
    return perkEffectEnabled(K.GUARDIANS_HABIT_PERK_ID)
end

local function steadyWallEnabled()
    return perkEffectEnabled(K.STEADY_WALL_PERK_ID)
end

local function bulwarkOfLightEnabled()
    return perkEffectEnabled(K.BULWARK_OF_LIGHT_PERK_ID)
end

local function aegisRiteEnabled()
    return perkEffectEnabled(K.AEGIS_RITE_PERK_ID)
end

local function spearLongGuardEnabled()
    return perkEffectEnabled(K.SPEAR_LONG_GUARD_PERK_ID)
end

local function unarmoredUnburdenedFormEnabled()
    return perkEffectEnabled(K.UNARMORED_UNBURDENED_FORM_PERK_ID)
end

local function unarmoredFlowingStepEnabled()
    return perkEffectEnabled(K.UNARMORED_FLOWING_STEP_PERK_ID)
end

local function unarmoredSilkGuardEnabled()
    return perkEffectEnabled(K.UNARMORED_SILK_GUARD_PERK_ID)
end

local function unarmoredEmptyMailEnabled()
    return perkEffectEnabled(K.UNARMORED_EMPTY_MAIL_PERK_ID)
end

local function unarmoredMasterOfMotionEnabled()
    return perkEffectEnabled(K.UNARMORED_MASTER_OF_MOTION_PERK_ID)
end

local function lightArmorQuickBuckleEnabled()
    return perkEffectEnabled(K.LIGHTARMOR_QUICK_BUCKLE_PERK_ID)
end

local function lightArmorSoftLandingEnabled()
    return perkEffectEnabled(K.LIGHTARMOR_SOFT_LANDING_PERK_ID)
end

local function lightArmorSkirmisherStrideEnabled()
    return perkEffectEnabled(K.LIGHTARMOR_SKIRMISHER_STRIDE_PERK_ID)
end

local function lightArmorGlancingAngleEnabled()
    return perkEffectEnabled(K.LIGHTARMOR_GLANCING_ANGLE_PERK_ID)
end

local function lightArmorSecondSkinEnabled()
    return perkEffectEnabled(K.LIGHTARMOR_SECOND_SKIN_PERK_ID)
end

local function hasValidShieldSetup()
    local shield = getEquippedShield(pself)
    if shield == nil then
        return false
    end

    local rightHand = getEquippedRightHand(pself)
    if rightHand == nil then
        return false
    end

    return isOneHandedWeapon(rightHand) or isTool(rightHand)
end

local function getPlayerSpells()
    if Actor == nil or type(Actor.spells) ~= "function" then
        if hallowedGuardSpellBookFailureState ~= "unavailable" then
            hallowedGuardSpellBookFailureState = "unavailable"
            logDebug("Actor.spells(pself) unavailable; cannot adjust hallowed guard state")
        end
        return nil
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells then
        if hallowedGuardSpellBookFailureState ~= "error" then
            hallowedGuardSpellBookFailureState = "error"
            logDebug("Actor.spells(pself) errored; cannot adjust hallowed guard state")
        end
        return nil
    end

    hallowedGuardSpellBookFailureState = nil
    return spells
end

local function resolveHallowedGuardSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[K.HALLOWED_GUARD_ABILITY_ID]
end

local function spellBookHasHallowedGuard(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(K.HALLOWED_GUARD_ABILITY_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveHallowedGuardSpellRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == K.HALLOWED_GUARD_ABILITY_ID then
            return true
        end
    end

    return false
end

local function addHallowedGuardSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(K.HALLOWED_GUARD_ABILITY_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveHallowedGuardSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeHallowedGuardSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(K.HALLOWED_GUARD_ABILITY_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveHallowedGuardSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateHallowedGuardAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHaveAbility = hallowedGuardEnabled() and hasValidShieldSetup()
    local hasSpell = spellBookHasHallowedGuard(spells)

    if shouldHaveAbility and not hasSpell then
        local okAdd, addError = addHallowedGuardSpell(spells)
        if not okAdd then
            if not hallowedGuardAddFailureLogged then
                hallowedGuardAddFailureLogged = true
                logDebug(string.format("failed to add %s: %s", K.HALLOWED_GUARD_ABILITY_ID, tostring(addError)))
            end
            return
        end
        hallowedGuardAddFailureLogged = false
        hallowedGuardApplied = true
    elseif (not shouldHaveAbility) and (hasSpell or hallowedGuardApplied) then
        local okRemove, removeError = removeHallowedGuardSpell(spells)
        if not okRemove then
            if not hallowedGuardRemoveFailureLogged then
                hallowedGuardRemoveFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", K.HALLOWED_GUARD_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        hallowedGuardRemoveFailureLogged = false
        hallowedGuardApplied = false
    end
end

local function resolveUnarmoredEmptyMailSpellRecord()
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if not okRecords or type(records) ~= "table" then
        return nil
    end

    return records[K.UNARMORED_EMPTY_MAIL_ABILITY_ID]
end

local function spellBookHasUnarmoredEmptyMail(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(K.UNARMORED_EMPTY_MAIL_ABILITY_ID)
        end)
        if okHasById and valueById == true then
            return true
        end

        local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
        if spellRecord ~= nil then
            local okHasByRecord, valueByRecord = pcall(function()
                return spells:has(spellRecord)
            end)
            if okHasByRecord and valueByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == K.UNARMORED_EMPTY_MAIL_ABILITY_ID then
            return true
        end
    end

    return false
end

local function addUnarmoredEmptyMailSpell(spells)
    if type(spells.add) ~= "function" then
        return false, "spells.add unavailable"
    end

    local okAddById, errById = pcall(function()
        spells:add(K.UNARMORED_EMPTY_MAIL_ABILITY_ID)
    end)
    if okAddById then
        return true, nil
    end

    local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okAddByRecord, errByRecord = pcall(function()
        spells:add(spellRecord)
    end)
    if okAddByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function removeUnarmoredEmptyMailSpell(spells)
    if type(spells.remove) ~= "function" then
        return false, "spells.remove unavailable"
    end

    local okRemoveById, errById = pcall(function()
        spells:remove(K.UNARMORED_EMPTY_MAIL_ABILITY_ID)
    end)
    if okRemoveById then
        return true, nil
    end

    local spellRecord = resolveUnarmoredEmptyMailSpellRecord()
    if spellRecord == nil then
        return false, errById
    end

    local okRemoveByRecord, errByRecord = pcall(function()
        spells:remove(spellRecord)
    end)
    if okRemoveByRecord then
        return true, nil
    end

    return false, tostring(errById) .. " | " .. tostring(errByRecord)
end

local function updateUnarmoredEmptyMailAbility()
    local spells = getPlayerSpells()
    if spells == nil then
        return
    end

    local shouldHaveAbility = unarmoredEmptyMailEnabled()
    local hasSpell = spellBookHasUnarmoredEmptyMail(spells)

    if shouldHaveAbility and not hasSpell then
        local okAdd, addError = addUnarmoredEmptyMailSpell(spells)
        if not okAdd then
            if not unarmoredEmptyMailAddFailureLogged then
                unarmoredEmptyMailAddFailureLogged = true
                logDebug(string.format("failed to add %s: %s", K.UNARMORED_EMPTY_MAIL_ABILITY_ID, tostring(addError)))
            end
            return
        end
        unarmoredEmptyMailAddFailureLogged = false
        unarmoredEmptyMailApplied = true
    elseif (not shouldHaveAbility) and (hasSpell or unarmoredEmptyMailApplied) then
        local okRemove, removeError = removeUnarmoredEmptyMailSpell(spells)
        if not okRemove then
            if not unarmoredEmptyMailRemoveFailureLogged then
                unarmoredEmptyMailRemoveFailureLogged = true
                logDebug(string.format("failed to remove %s: %s", K.UNARMORED_EMPTY_MAIL_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        unarmoredEmptyMailRemoveFailureLogged = false
        unarmoredEmptyMailApplied = false
    end
end

local function getBlockSkillBonus()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return 0
    end

    local blockStat = blockAccessor(pself)
    local blockSkill = blockStat ~= nil and tonumber(blockStat.base) or 0
    if blockSkill <= 0 then
        return 0
    end

    return math.floor(blockSkill / 7)
end

local function getSpearSkillBonus()
    local spearAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.spear
    if type(spearAccessor) ~= "function" then
        return 0
    end

    local spearStat = spearAccessor(pself)
    local spearSkill = spearStat ~= nil and tonumber(spearStat.base) or 0
    if spearSkill <= 0 then
        return 0
    end

    return math.floor(spearSkill / 10)
end

local function getUnarmoredSkillBonus()
    local unarmoredAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.unarmored
    if type(unarmoredAccessor) ~= "function" then
        return 0
    end

    local unarmoredStat = unarmoredAccessor(pself)
    local unarmoredSkill = unarmoredStat ~= nil and tonumber(unarmoredStat.base) or 0
    if unarmoredSkill <= 0 then
        return 0
    end

    return math.floor(unarmoredSkill / 10)
end

local function getLightArmorSkillBonus()
    local lightArmorAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.lightarmor
    if type(lightArmorAccessor) ~= "function" then
        lightArmorAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.lightArmor
    end
    if type(lightArmorAccessor) ~= "function" then
        return 0
    end

    local lightArmorStat = lightArmorAccessor(pself)
    local lightArmorSkill = lightArmorStat ~= nil and tonumber(lightArmorStat.base) or 0
    if lightArmorSkill <= 0 then
        return 0
    end

    return math.floor(lightArmorSkill / 10)
end

local function getGuardiansHabitFatigueRestore()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return 1
    end

    local blockStat = blockAccessor(pself)
    local blockSkill = blockStat ~= nil and tonumber(blockStat.base) or 0
    return math.max(1, math.floor(blockSkill / 5))
end

local function pruneMomentumStacks()
    local kept = {}
    for _, expiresAt in ipairs(momentumExpirations) do
        if expiresAt > runtimeTime then
            kept[#kept + 1] = expiresAt
        end
    end
    momentumExpirations = kept
end

local function getMomentumStackCount()
    pruneMomentumStacks()
    return #momentumExpirations
end

local function getMomentumArmorBonus()
    if not steadyWallEnabled() then
        return 0
    end
    if not hasValidShieldSetup() then
        return 0
    end
    return getMomentumStackCount() * K.STEADY_WALL_ARMOR_PER_STACK
end

local function getMomentumBlockBonus()
    if not steadyWallEnabled() then
        return 0
    end
    if not hasValidShieldSetup() then
        return 0
    end
    return getMomentumStackCount() * K.STEADY_WALL_BLOCK_PER_STACK
end

local function applyMomentumBlockModifier()
    local blockAccessor = types.NPC ~= nil and types.NPC.stats ~= nil and types.NPC.stats.skills ~= nil and types.NPC.stats.skills.block
    if type(blockAccessor) ~= "function" then
        return
    end

    local blockStat = blockAccessor(pself)
    if blockStat == nil then
        return
    end

    local desiredModifier = getMomentumBlockBonus()
    local currentModifier = tonumber(blockStat.modifier) or 0
    if currentModifier ~= desiredModifier then
        blockStat.modifier = desiredModifier
    end
end

local function shouldApplyShieldFundamentalsBonus()
    if not shieldFundamentalsEnabled() then
        return false
    end

    return hasValidShieldSetup()
end

local function shouldApplySpearLongGuardBonus()
    if not spearLongGuardEnabled() then
        return false
    end

    if getEquippedShield(pself) ~= nil then
        return false
    end

    return isSpearWeapon(getEquippedRightHand(pself))
end


local function normalizedArmorRecordText(record)
    local parts = {}
    if type(record.id) == "string" then parts[#parts + 1] = record.id end
    if type(record.name) == "string" then parts[#parts + 1] = record.name end
    if type(record.icon) == "string" then parts[#parts + 1] = record.icon end
    if type(record.model) == "string" then parts[#parts + 1] = record.model end
    return string.lower(table.concat(parts, " "))
end

local function isLightArmorRecord(record)
    if record == nil then
        return false
    end

    local armorSkill = string.lower(tostring(record.skill or record.armorSkill or record.skillId or ""))
    if armorSkill == "lightarmor" or armorSkill == "light armor" or armorSkill == "light" then
        return true
    elseif armorSkill == "mediumarmor" or armorSkill == "medium armor" or armorSkill == "heavyarmor" or armorSkill == "heavy armor" then
        return false
    end

    local recordText = normalizedArmorRecordText(record)
    local lightArmorHints = {
        "chitin",
        "dreugh",
        "glass",
        "leather",
        "netch",
        "nordic fur",
        "wolv",
    }
    for _, hint in ipairs(lightArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return true
        end
    end

    local nonLightArmorHints = {
        "adamantium",
        "bonemold",
        "chain",
        "daedric",
        "dwemer",
        "ebony",
        "her hand",
        "ice armor",
        "imperial chain",
        "imperial steel",
        "iron",
        "nordic mail",
        "orcish",
        "royal guard",
        "scale",
        "snow bear",
        "snow wolf",
        "steel",
    }
    for _, hint in ipairs(nonLightArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return false
        end
    end

    return (tonumber(record.weight) or 0) <= 10
end

local function isEquippedLightArmorOfType(slot, armorType)
    local equipped = getEquippedItem(pself, slot)
    if equipped == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return false
    end

    local record = nil
    if type(Armor.record) == "function" then
        local okRecord, value = pcall(Armor.record, equipped)
        if okRecord then
            record = value
        end
    end

    return record ~= nil and Armor.TYPE ~= nil and record.type == armorType and isLightArmorRecord(record)
end

local function getEquippedLightArmorWeight()
    if Actor == nil or type(Actor.getEquipment) ~= "function" or Armor == nil or type(Armor.objectIsInstance) ~= "function" then
        return 0
    end

    local okEquipment, equipment = pcall(Actor.getEquipment, pself)
    if not okEquipment or type(equipment) ~= "table" then
        return 0
    end

    local totalWeight = 0
    for _, equipped in pairs(equipment) do
        if equipped ~= nil and Armor.objectIsInstance(equipped) then
            local record = nil
            if type(Armor.record) == "function" then
                local okRecord, value = pcall(Armor.record, equipped)
                if okRecord then
                    record = value
                end
            end
            if record ~= nil and isLightArmorRecord(record) then
                totalWeight = totalWeight + math.max(0, tonumber(record.weight) or 0)
            end
        end
    end

    return totalWeight
end

local function modifyFeatherEffect(delta)
    if Actor == nil or type(Actor.activeEffects) ~= "function" then
        return false
    end

    local effectType = core.magic and core.magic.EFFECT_TYPE and core.magic.EFFECT_TYPE.Feather
    if effectType == nil then
        return false
    end

    local okEffects, activeEffects = pcall(Actor.activeEffects, pself)
    if not okEffects or activeEffects == nil or type(activeEffects.modify) ~= "function" then
        return false
    end

    return pcall(activeEffects.modify, activeEffects, delta, effectType)
end

local function refreshSecondSkinFeatherBonus()
    local targetBonus = 0
    if lightArmorSecondSkinEnabled() then
        targetBonus = getEquippedLightArmorWeight()
    end

    if targetBonus == appliedSecondSkinFeatherBonus then
        return
    end

    local delta = targetBonus - appliedSecondSkinFeatherBonus
    if modifyFeatherEffect(delta) then
        appliedSecondSkinFeatherBonus = targetBonus
    end
end

local function getPlayerRaceId()
    if types.NPC ~= nil and type(types.NPC.record) == "function" then
        local okRecord, record = pcall(types.NPC.record, pself)
        if okRecord and record ~= nil then
            local race = record.race or record.raceId or record.raceID
            if race ~= nil then
                return string.lower(tostring(race))
            end
        end
    end

    local record = pself.record
    if type(record) == "table" then
        local race = record.race or record.raceId or record.raceID
        if race ~= nil then
            return string.lower(tostring(race))
        end
    end

    return ""
end

local function isBeastRaceWithoutBoots()
    local raceId = getPlayerRaceId()
    return string.find(raceId, "argonian", 1, true) ~= nil
        or string.find(raceId, "khajiit", 1, true) ~= nil
end

local function hasSoftLandingLightArmorBoots()
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil or Armor == nil or Armor.TYPE == nil then
        return false
    end

    return isEquippedLightArmorOfType(Actor.EQUIPMENT_SLOT.Boots, Armor.TYPE.Boots)
end

local function hasSoftLandingLightArmorGreaves()
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil or Armor == nil or Armor.TYPE == nil then
        return false
    end

    return isEquippedLightArmorOfType(Actor.EQUIPMENT_SLOT.Greaves, Armor.TYPE.Greaves)
end

local function hasLightArmorCuirassEquipped()
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil or Armor == nil or Armor.TYPE == nil then
        return false
    end

    return isEquippedLightArmorOfType(Actor.EQUIPMENT_SLOT.Cuirass, Armor.TYPE.Cuirass)
end

local function hasSkirmisherStrideLightArmorCuirass()
    return hasLightArmorCuirassEquipped()
end

local function shouldApplySoftLandingAcrobaticsBonus()
    if not lightArmorSoftLandingEnabled() then
        return false
    end

    if isBeastRaceWithoutBoots() then
        return hasSoftLandingLightArmorGreaves()
    end

    return hasSoftLandingLightArmorBoots()
end


local function isArmoredCuirassGreavesOrShield(equipped, slot)
    if equipped == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(equipped) then
        return false
    end

    local armorType = nil
    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, equipped)
        if okRecord and record ~= nil then
            armorType = record.type
        end
    end

    if Armor.TYPE ~= nil then
        if armorType == Armor.TYPE.Cuirass or armorType == Armor.TYPE.Greaves or armorType == Armor.TYPE.Shield then
            return true
        end
    end

    if Actor ~= nil and Actor.EQUIPMENT_SLOT ~= nil then
        return slot == Actor.EQUIPMENT_SLOT.Cuirass
            or slot == Actor.EQUIPMENT_SLOT.Greaves
            or slot == Actor.EQUIPMENT_SLOT.CarriedLeft
    end

    return false
end

local function hasArmoredCuirassGreavesOrShieldEquipped()
    if Actor == nil or type(Actor.getEquipment) ~= "function" then
        return false
    end

    local okEquipment, equipment = pcall(Actor.getEquipment, pself)
    if not okEquipment or type(equipment) ~= "table" then
        return false
    end

    for slot, equipped in pairs(equipment) do
        if isArmoredCuirassGreavesOrShield(equipped, slot) then
            return true
        end
    end

    return false
end

local function isEquippedArmorOrShield(equipped)
    return equipped ~= nil
        and Armor ~= nil
        and type(Armor.objectIsInstance) == "function"
        and Armor.objectIsInstance(equipped)
end

local function hasArmorOrShieldEquipped()
    if Actor == nil or type(Actor.getEquipment) ~= "function" then
        return false
    end

    local okEquipment, equipment = pcall(Actor.getEquipment, pself)
    if not okEquipment or type(equipment) ~= "table" then
        return false
    end

    for _, equipped in pairs(equipment) do
        if isEquippedArmorOrShield(equipped) then
            return true
        end
    end

    return false
end

local function getBlockRuntimeFatiguePercent()
    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return 0
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return 0
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return 0
    end

    return current / maxFatigue
end

local function resolveBlockRuntimeAttributeStat(attributeID)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes[attributeID]
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end


local function restoreUnarmoredMasterOfMotionFatigue(dt)
    if not unarmoredMasterOfMotionEnabled() or hasArmoredCuirassGreavesOrShieldEquipped() then
        return
    end

    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return
    end

    local fatigue = fatigueAccessor(pself)
    if fatigue == nil then
        return
    end

    local current = tonumber(fatigue.current) or 0
    local base = tonumber(fatigue.base) or current
    local modifier = tonumber(fatigue.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 or current <= maxFatigue * K.UNARMORED_MASTER_OF_MOTION_MIN_FATIGUE_THRESHOLD then
        return
    end

    local restoreAmount = math.max(0, tonumber(dt) or 0) * K.UNARMORED_MASTER_OF_MOTION_FATIGUE_RESTORE_PER_SECOND
    if restoreAmount <= 0 then
        return
    end

    fatigue.current = math.min(maxFatigue, current + restoreAmount)
end

local function applyUnarmoredFlowingStepAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedUnarmoredFlowingStepAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveBlockRuntimeAttributeStat("agility")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedUnarmoredFlowingStepAgilityBonus = desired
end

local function getUnarmoredFlowingStepAgilityBonus()
    if not unarmoredFlowingStepEnabled() or hasArmorOrShieldEquipped() then
        return 0
    end

    if getBlockRuntimeFatiguePercent() > K.UNARMORED_FLOWING_STEP_HIGH_FATIGUE_THRESHOLD then
        return K.UNARMORED_FLOWING_STEP_HIGH_FATIGUE_AGILITY_BONUS
    end

    return K.UNARMORED_FLOWING_STEP_AGILITY_BONUS
end

local function refreshUnarmoredFlowingStepAgilityBonus()
    applyUnarmoredFlowingStepAgilityBonus(getUnarmoredFlowingStepAgilityBonus())
end

local function applyUnarmoredSilkGuardAttributeBonus(attributeID, currentBonus, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(currentBonus) or 0))
    if desired == current then
        return current
    end

    local stat = resolveBlockRuntimeAttributeStat(attributeID)
    if stat == nil or type(stat.modifier) ~= "number" then
        return current
    end

    stat.modifier = stat.modifier - current + desired
    return desired
end

local function getUnarmoredSilkGuardAttributeBonus()
    if not unarmoredSilkGuardEnabled() or hasArmoredCuirassGreavesOrShieldEquipped() then
        return 0
    end

    if getBlockRuntimeFatiguePercent() > K.UNARMORED_SILK_GUARD_HIGH_FATIGUE_THRESHOLD then
        return K.UNARMORED_SILK_GUARD_HIGH_FATIGUE_ATTRIBUTE_BONUS
    end

    return K.UNARMORED_SILK_GUARD_ATTRIBUTE_BONUS
end

local function refreshUnarmoredSilkGuardAttributeBonuses()
    local bonus = getUnarmoredSilkGuardAttributeBonus()
    appliedUnarmoredSilkGuardEnduranceBonus = applyUnarmoredSilkGuardAttributeBonus(
        "endurance",
        appliedUnarmoredSilkGuardEnduranceBonus,
        bonus
    )
    appliedUnarmoredSilkGuardWillpowerBonus = applyUnarmoredSilkGuardAttributeBonus(
        "willpower",
        appliedUnarmoredSilkGuardWillpowerBonus,
        bonus
    )
end

local function resolveBlockRuntimeSkillStat(skillID)
    local accessor = types.NPC ~= nil
        and types.NPC.stats ~= nil
        and types.NPC.stats.skills ~= nil
        and types.NPC.stats.skills[skillID]
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function pruneGlancingAngleStacks()
    local kept = {}
    for _, expiresAt in ipairs(glancingAngleExpirations) do
        if expiresAt > runtimeTime then
            kept[#kept + 1] = expiresAt
        end
    end
    glancingAngleExpirations = kept
end

local function getGlancingAngleStackCount()
    if not lightArmorGlancingAngleEnabled() or not hasLightArmorCuirassEquipped() then
        glancingAngleExpirations = {}
        return 0
    end

    pruneGlancingAngleStacks()
    return #glancingAngleExpirations
end

local function applyGlancingAngleAgilityBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedGlancingAngleAgilityBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveBlockRuntimeAttributeStat("agility")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedGlancingAngleAgilityBonus = desired
end

local function refreshGlancingAngleAgilityBonus()
    applyGlancingAngleAgilityBonus(getGlancingAngleStackCount() * K.LIGHTARMOR_GLANCING_ANGLE_AGILITY_PER_STACK)
end

local function applySoftLandingAcrobaticsBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedSoftLandingAcrobaticsBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveBlockRuntimeSkillStat("acrobatics")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedSoftLandingAcrobaticsBonus = desired
end

local function refreshSoftLandingAcrobaticsBonus()
    if shouldApplySoftLandingAcrobaticsBonus() then
        applySoftLandingAcrobaticsBonus(K.LIGHTARMOR_SOFT_LANDING_ACROBATICS_BONUS)
    else
        applySoftLandingAcrobaticsBonus(0)
    end
end

local function shouldApplyUnarmoredUnburdenedFormBonus()
    if not unarmoredUnburdenedFormEnabled() then
        return false
    end

    return not hasArmoredCuirassGreavesOrShieldEquipped()
end

local function shouldApplyLightArmorQuickBuckleBonus()
    if not lightArmorQuickBuckleEnabled() or Actor == nil or Actor.EQUIPMENT_SLOT == nil or Armor == nil or Armor.TYPE == nil then
        return false
    end

    return isEquippedLightArmorOfType(Actor.EQUIPMENT_SLOT.Cuirass, Armor.TYPE.Cuirass)
        and isEquippedLightArmorOfType(Actor.EQUIPMENT_SLOT.Greaves, Armor.TYPE.Greaves)
end

local function getTotalPassiveArmorBonus()
    local bonus = 0
    if shouldApplyShieldFundamentalsBonus() then
        bonus = bonus + getBlockSkillBonus()
    end
    if shouldApplySpearLongGuardBonus() then
        bonus = bonus + getSpearSkillBonus()
    end
    if shouldApplyUnarmoredUnburdenedFormBonus() then
        bonus = bonus + getUnarmoredSkillBonus()
    end
    if shouldApplyLightArmorQuickBuckleBonus() then
        bonus = bonus + getLightArmorSkillBonus()
    end
    if type(__basepack_shared.getMediumArmorArmorBonus) == "function" then
        bonus = bonus + (tonumber(__basepack_shared.getMediumArmorArmorBonus()) or 0)
    end
    if type(__basepack_shared.getHeavyArmorArmorBonus) == "function" then
        bonus = bonus + (tonumber(__basepack_shared.getHeavyArmorArmorBonus()) or 0)
    end
    bonus = bonus + getMomentumArmorBonus()
    return bonus
end

local function adjustDamageForArmorWithShieldBonuses(damage, actor)
    local fn = getBaseCombatFunction("adjustDamageForArmor")
    if fn == nil then
        return damage
    end

    local actualActor = actor or pself
    local adjusted = fn(damage, actualActor)

    if actualActor ~= pself then
        return adjusted
    end

    local bonusArmor = getTotalPassiveArmorBonus()

    if bonusArmor <= 0 then
        return adjusted
    end

    local result = (tonumber(adjusted) or 0) * 100 / (100 + bonusArmor)

    logDebug(string.format(
        "shield bonus damage reduction in=%.3f bonusArmor=%d out=%.3f",
        tonumber(adjusted) or 0,
        bonusArmor,
        result
    ))

    return result
end

local function getArmorRecord(item)
    if item == nil or Armor == nil or type(Armor.record) ~= "function" then
        return nil
    end

    local ok, record = pcall(Armor.record, item)
    if ok then
        return record
    end
    return nil
end

local function getArmorRatingWithShieldBonuses(actor)
    local fn = getBaseCombatFunction("getArmorRating")
    if fn == nil then
        return nil
    end

    local actualActor = actor or pself
    local baseArmor = fn(actualActor)
    if actualActor ~= pself then
        return baseArmor
    end

    local bonus = getTotalPassiveArmorBonus()

    if bonus <= 0 then
        return baseArmor
    end

    return (tonumber(baseArmor) or 0) + bonus
end

local function getEffectiveArmorRatingWithShieldBonuses(item, actor)
    local fn = getBaseCombatFunction("getEffectiveArmorRating")
    if fn == nil then
        return nil
    end

    local actualActor = actor or pself
    local baseArmor = fn(item, actualActor)
    if actualActor ~= pself then
        return baseArmor
    end

    if item == nil then
        return baseArmor
    end

    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return baseArmor
    end

    local record = getArmorRecord(item)
    if record == nil or record.type ~= Armor.TYPE.Shield then
        return baseArmor
    end

    local bonus = 0
    if shouldApplyShieldFundamentalsBonus() then
        bonus = bonus + getBlockSkillBonus()
    end
    bonus = bonus + getMomentumArmorBonus()

    if bonus <= 0 then
        return baseArmor
    end

    return (tonumber(baseArmor) or 0) + bonus
end

local function wasSuccessfulShieldBlock(attack)
    if type(attack) ~= "table" then
        return false
    end

    local blockedFlag = attack.blocked == true or attack.isBlocked == true or attack.block == true
    local blockedBy = string.lower(tostring(attack.blockedBy or attack.blockType or attack.defenseType or ""))
    local isParry = attack.parried == true or attack.isParry == true or blockedBy:find("parry", 1, true) ~= nil

    if isParry then
        return false
    end

    if blockedBy:find("shield", 1, true) ~= nil then
        return true
    end

    if blockedFlag then
        return true
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local healthDamage = tonumber(damage.health) or 0
    local fatigueDamage = tonumber(damage.fatigue) or 0
    local magickaDamage = tonumber(damage.magicka) or 0
    local totalDamage = healthDamage + fatigueDamage + magickaDamage

    if attack.successful == true and totalDamage <= 0 then
        return true
    end

    return false
end

local function trySpendMagicka(amount)
    if amount <= 0 then
        return true
    end

    local magickaAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.magicka

    if type(magickaAccessor) ~= "function" then
        return false
    end

    local magickaStat = magickaAccessor(pself)
    if magickaStat == nil then
        return false
    end

    local current = tonumber(magickaStat.current) or 0
    if current < amount then
        return false
    end

    magickaStat.current = current - amount
    return true
end

local function onTryConsumeAegisRite(data)
    if not aegisRiteEnabled() then
        return
    end
    if type(data) ~= "table" or data.target == nil then
        return
    end
    if not trySpendMagicka(K.AEGIS_RITE_MAGICKA_COST) then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyAegisRiteEffect", {
        attacker = pself,
        target = data.target,
    })
end

local function applyGuardiansHabit(attack)
    if not guardiansHabitEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    local shield = getEquippedShield(pself)
    if shield == nil then
        return
    end

    local fatigueRestore = getGuardiansHabitFatigueRestore()

    local fatigueStatAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue

    if type(fatigueStatAccessor) == "function" then
        local fatigueStat = fatigueStatAccessor(pself)
        if fatigueStat ~= nil then
            local current = tonumber(fatigueStat.current) or 0
            local base = tonumber(fatigueStat.base) or current
            local modifier = tonumber(fatigueStat.modifier) or 0
            local maxFatigue = math.max(0, base + modifier)
            fatigueStat.current = math.min(current + fatigueRestore, maxFatigue)
        end
    end

    core.sendGlobalEvent("ModifyItemCondition", {
        actor = pself,
        item = shield,
        amount = math.max(1, math.floor(getBlockSkillBonus() / 2)),
    })
end

local function applySteadyWallMomentum(attack)
    if not steadyWallEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    pruneMomentumStacks()
    if #momentumExpirations < K.STEADY_WALL_MAX_STACKS then
        momentumExpirations[#momentumExpirations + 1] = runtimeTime + K.STEADY_WALL_DURATION
    else
        local oldestIndex = 1
        local oldestTime = momentumExpirations[1]
        for i = 2, #momentumExpirations do
            if momentumExpirations[i] < oldestTime then
                oldestTime = momentumExpirations[i]
                oldestIndex = i
            end
        end
        momentumExpirations[oldestIndex] = runtimeTime + K.STEADY_WALL_DURATION
    end
end

local function primeAegisRite(attack)
    if not aegisRiteEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    if attack.attacker == nil then
        return
    end

    core.sendGlobalEvent("SkillPerkSystem_PrimeAegisRite", {
        blocker = pself,
        attacker = attack.attacker,
        duration = K.AEGIS_RITE_WINDOW,
    })
end

local function applyBulwarkOfLight(attack)
    if not bulwarkOfLightEnabled() then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    if not hasValidShieldSetup() then
        return
    end

    Actor.activeSpells(pself):add({
        id = K.BULWARK_SELF_SPELL_ID,
        effects = { 0 },
        caster = pself,
        stackable = false,
    })

    core.sendGlobalEvent("SkillPerkSystem_ApplyBulwarkOfLight", {
        blocker = pself,
    })
end

local function initializeDefaults()
    if configSection:get(K.DEBUG_LOGGING_KEY) == nil then
        configSection:set(K.DEBUG_LOGGING_KEY, K.DEFAULT_DEBUG_LOGGING)
    end
end

local function loadGlancingAngleExpirations(data)
    glancingAngleExpirations = {}
    if type(data) ~= "table" or type(data[K.LIGHTARMOR_GLANCING_ANGLE_STACKS_SAVE_KEY]) ~= "table" then
        return
    end

    for _, remainingTime in ipairs(data[K.LIGHTARMOR_GLANCING_ANGLE_STACKS_SAVE_KEY]) do
        local duration = tonumber(remainingTime) or 0
        if duration > 0 then
            glancingAngleExpirations[#glancingAngleExpirations + 1] = runtimeTime + math.min(duration, K.LIGHTARMOR_GLANCING_ANGLE_DURATION)
            if #glancingAngleExpirations >= K.LIGHTARMOR_GLANCING_ANGLE_MAX_STACKS then
                return
            end
        end
    end
end

local function getGlancingAngleRemainingTimesForSave()
    pruneGlancingAngleStacks()
    local remainingTimes = {}
    for _, expiresAt in ipairs(glancingAngleExpirations) do
        local remainingTime = math.max(0, (tonumber(expiresAt) or 0) - runtimeTime)
        if remainingTime > 0 then
            remainingTimes[#remainingTimes + 1] = math.min(remainingTime, K.LIGHTARMOR_GLANCING_ANGLE_DURATION)
        end
    end
    return remainingTimes
end

local function onLoadBlockRuntime(data)
    appliedUnarmoredFlowingStepAgilityBonus = math.max(0, math.floor(tonumber(
        type(data) == "table" and data[K.UNARMORED_FLOWING_STEP_APPLIED_KEY]
    ) or 0))
    appliedUnarmoredSilkGuardEnduranceBonus = math.max(0, math.floor(tonumber(
        type(data) == "table" and data[K.UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY]
    ) or 0))
    appliedUnarmoredSilkGuardWillpowerBonus = math.max(0, math.floor(tonumber(
        type(data) == "table" and data[K.UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY]
    ) or 0))
    appliedSoftLandingAcrobaticsBonus = math.max(0, math.floor(tonumber(
        type(data) == "table" and data[K.LIGHTARMOR_SOFT_LANDING_ACROBATICS_APPLIED_KEY]
    ) or 0))
    appliedGlancingAngleAgilityBonus = math.max(0, math.floor(tonumber(
        type(data) == "table" and data[K.LIGHTARMOR_GLANCING_ANGLE_AGILITY_APPLIED_KEY]
    ) or 0))
    appliedSecondSkinFeatherBonus = math.max(0, tonumber(
        type(data) == "table" and data[K.LIGHTARMOR_SECOND_SKIN_FEATHER_APPLIED_KEY]
    ) or 0)
    loadGlancingAngleExpirations(data)
end

local function onSaveBlockRuntime()
    return {
        [K.UNARMORED_FLOWING_STEP_APPLIED_KEY] = appliedUnarmoredFlowingStepAgilityBonus,
        [K.UNARMORED_SILK_GUARD_ENDURANCE_APPLIED_KEY] = appliedUnarmoredSilkGuardEnduranceBonus,
        [K.UNARMORED_SILK_GUARD_WILLPOWER_APPLIED_KEY] = appliedUnarmoredSilkGuardWillpowerBonus,
        [K.LIGHTARMOR_SOFT_LANDING_ACROBATICS_APPLIED_KEY] = appliedSoftLandingAcrobaticsBonus,
        [K.LIGHTARMOR_GLANCING_ANGLE_AGILITY_APPLIED_KEY] = appliedGlancingAngleAgilityBonus,
        [K.LIGHTARMOR_GLANCING_ANGLE_STACKS_SAVE_KEY] = getGlancingAngleRemainingTimesForSave(),
        [K.LIGHTARMOR_SECOND_SKIN_FEATHER_APPLIED_KEY] = appliedSecondSkinFeatherBonus,
    }
end

local function isDamagingIncomingHit(attack)
    if type(attack) ~= "table" then
        return false
    end

    if attack.attacker == nil or attack.successful == false then
        return false
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local totalDamage = (tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)
    return totalDamage > 0
end

local function addGlancingAngleStack(attack)
    if not lightArmorGlancingAngleEnabled() or not isDamagingIncomingHit(attack) then
        return
    end

    if not hasLightArmorCuirassEquipped() then
        return
    end

    pruneGlancingAngleStacks()
    local expiresAt = runtimeTime + K.LIGHTARMOR_GLANCING_ANGLE_DURATION
    if #glancingAngleExpirations < K.LIGHTARMOR_GLANCING_ANGLE_MAX_STACKS then
        glancingAngleExpirations[#glancingAngleExpirations + 1] = expiresAt
    else
        local oldestIndex = 1
        local oldestTime = glancingAngleExpirations[1]
        for i = 2, #glancingAngleExpirations do
            if glancingAngleExpirations[i] < oldestTime then
                oldestTime = glancingAngleExpirations[i]
                oldestIndex = i
            end
        end
        glancingAngleExpirations[oldestIndex] = expiresAt
    end
    refreshGlancingAngleAgilityBonus()
end

local function restoreSkirmisherStrideFatigue(attack)
    if not lightArmorSkirmisherStrideEnabled() or type(attack) ~= "table" then
        return
    end

    if attack.attacker == nil or attack.successful == false then
        return
    end

    if not hasSkirmisherStrideLightArmorCuirass() then
        return
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local totalDamage = (tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)
    if totalDamage <= 0 then
        return
    end

    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return
    end

    local fatigueStat = fatigueAccessor(pself)
    if fatigueStat == nil then
        return
    end

    local current = tonumber(fatigueStat.current) or 0
    local base = tonumber(fatigueStat.base) or current
    local modifier = tonumber(fatigueStat.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return
    end

    fatigueStat.current = math.min(maxFatigue, current + K.LIGHTARMOR_SKIRMISHER_STRIDE_FATIGUE_RESTORE)
end

local function restoreSkirmisherStrideFatigue(attack)
    if not lightArmorSkirmisherStrideEnabled() or type(attack) ~= "table" then
        return
    end

    if attack.attacker == nil or attack.successful == false then
        return
    end

    if not hasSkirmisherStrideLightArmorCuirass() then
        return
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    local totalDamage = (tonumber(damage.health) or 0) + (tonumber(damage.fatigue) or 0) + (tonumber(damage.magicka) or 0)
    if totalDamage <= 0 then
        return
    end

    local fatigueAccessor = types.Actor ~= nil
        and types.Actor.stats ~= nil
        and types.Actor.stats.dynamic ~= nil
        and types.Actor.stats.dynamic.fatigue
    if type(fatigueAccessor) ~= "function" then
        return
    end

    local fatigueStat = fatigueAccessor(pself)
    if fatigueStat == nil then
        return
    end

    local current = tonumber(fatigueStat.current) or 0
    local base = tonumber(fatigueStat.base) or current
    local modifier = tonumber(fatigueStat.modifier) or 0
    local maxFatigue = math.max(0, base + modifier)
    if maxFatigue <= 0 then
        return
    end

    fatigueStat.current = math.min(maxFatigue, current + K.LIGHTARMOR_SKIRMISHER_STRIDE_FATIGUE_RESTORE)
end

local function processBlockPerks(attack)
    restoreSkirmisherStrideFatigue(attack)
    addGlancingAngleStack(attack)
    applyGuardiansHabit(attack)
    applySteadyWallMomentum(attack)
    primeAegisRite(attack)
    applyBulwarkOfLight(attack)
end

local function shouldUpdateBlock(dt)
    if #momentumExpirations > 0 or #glancingAngleExpirations > 0 or hallowedGuardAddFailureLogged or hallowedGuardRemoveFailureLogged then
        return true
    end

    local needsHallowedGuardRefresh = hallowedGuardApplied or hallowedGuardEnabled()
    local needsFlowingStepRefresh = appliedUnarmoredFlowingStepAgilityBonus ~= 0 or unarmoredFlowingStepEnabled()
    local needsSilkGuardRefresh = appliedUnarmoredSilkGuardEnduranceBonus ~= 0
        or appliedUnarmoredSilkGuardWillpowerBonus ~= 0
        or unarmoredSilkGuardEnabled()
    local needsEmptyMailRefresh = unarmoredEmptyMailApplied or unarmoredEmptyMailEnabled()
    local needsMasterOfMotionRefresh = unarmoredMasterOfMotionEnabled()
    local needsSoftLandingRefresh = appliedSoftLandingAcrobaticsBonus ~= 0 or lightArmorSoftLandingEnabled()
    local needsGlancingAngleRefresh = appliedGlancingAngleAgilityBonus ~= 0 or lightArmorGlancingAngleEnabled()
    local needsSecondSkinRefresh = appliedSecondSkinFeatherBonus ~= 0 or lightArmorSecondSkinEnabled()
    if needsMasterOfMotionRefresh then
        return true
    end

    if not needsHallowedGuardRefresh
        and not needsFlowingStepRefresh
        and not needsSilkGuardRefresh
        and not needsEmptyMailRefresh
        and not needsMasterOfMotionRefresh
        and not needsSoftLandingRefresh
        and not needsGlancingAngleRefresh
        and not needsSecondSkinRefresh then
        return false
    end

    blockStateRefreshTimer = blockStateRefreshTimer + (tonumber(dt) or 0)
    if blockStateRefreshTimer < K.BLOCK_STATE_REFRESH_INTERVAL then
        return false
    end

    blockStateRefreshTimer = 0
    blockStateRefreshDue = true
    return true
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(processBlockPerks)
end

__basepack_subsystem_result = {
    interfaceName = "Combat",
    interface = {
        version = 1,

        addOnHitHandler = passthrough("addOnHitHandler"),
        adjustDamageForArmor = adjustDamageForArmorWithShieldBonuses,
        adjustDamageForDifficulty = passthrough("adjustDamageForDifficulty"),
        applyArmor = passthrough("applyArmor"),

        getArmorRating = getArmorRatingWithShieldBonuses,
        getArmorSkill = passthrough("getArmorSkill"),
        getEffectiveArmorRating = getEffectiveArmorRatingWithShieldBonuses,
        getSkillAdjustedArmorRating = passthrough("getSkillAdjustedArmorRating"),

        onHit = passthrough("onHit"),
        pickRandomArmor = passthrough("pickRandomArmor"),
        spawnBloodEffect = passthrough("spawnBloodEffect"),
    },
    eventHandlers = {
        SkillPerkSystem_TryConsumeAegisRite = onTryConsumeAegisRite,
    },
    engineHandlers = {
        onLoad = function(data)
            initializeDefaults()
            runtimeTime = 0
            momentumExpirations = {}
            onLoadBlockRuntime(data)
            hallowedGuardApplied = false
            unarmoredEmptyMailApplied = false
            blockStateRefreshTimer = K.BLOCK_STATE_REFRESH_INTERVAL
            blockStateRefreshDue = false
            applyMomentumBlockModifier()
            refreshUnarmoredFlowingStepAgilityBonus()
            refreshUnarmoredSilkGuardAttributeBonuses()
            refreshSoftLandingAcrobaticsBonus()
            refreshGlancingAngleAgilityBonus()
            refreshSecondSkinFeatherBonus()
            updateHallowedGuardAbility()
            updateUnarmoredEmptyMailAbility()
        end,
        onUpdate = function(dt)
            runtimeTime = runtimeTime + (tonumber(dt) or 0)
            pruneMomentumStacks()
            applyMomentumBlockModifier()
            refreshUnarmoredFlowingStepAgilityBonus()
            refreshUnarmoredSilkGuardAttributeBonuses()
            refreshSoftLandingAcrobaticsBonus()
            refreshGlancingAngleAgilityBonus()
            refreshSecondSkinFeatherBonus()
            restoreUnarmoredMasterOfMotionFatigue(dt)
            blockStateRefreshTimer = blockStateRefreshTimer + (tonumber(dt) or 0)
            if blockStateRefreshDue
                or blockStateRefreshTimer >= K.BLOCK_STATE_REFRESH_INTERVAL
                or hallowedGuardAddFailureLogged
                or hallowedGuardRemoveFailureLogged
                or unarmoredEmptyMailAddFailureLogged
                or unarmoredEmptyMailRemoveFailureLogged then
                blockStateRefreshTimer = 0
                blockStateRefreshDue = false
                updateHallowedGuardAbility()
                updateUnarmoredEmptyMailAbility()
            end
        end,
        shouldUpdate = shouldUpdateBlock,
        onSave = onSaveBlockRuntime,
        onInterfaceOverride = function(base)
            baseCombatInterface = base
        end,
    },
}


return __basepack_subsystem_result
