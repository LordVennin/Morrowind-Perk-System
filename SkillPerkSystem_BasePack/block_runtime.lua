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

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LOG_TAG = "[SkillPerkSystem_BasePack][BlockEnchant]"

local HALLOWED_GUARD_PERK_ID = "block_hallowed_guard"
local SHIELD_FUNDAMENTALS_PERK_ID = "block_shield_fundamentals"
local GUARDIANS_HABIT_PERK_ID = "block_guardians_habit"
local STEADY_WALL_PERK_ID = "block_steady_wall"
local BULWARK_OF_LIGHT_PERK_ID = "block_bulwark_of_light"
local AEGIS_RITE_PERK_ID = "block_aegis_rite"

local CONFIG_SECTION_ID = "SkillPerkSystem_BasePack_BlockEnchant"
local DEBUG_LOGGING_KEY = "block.enchant.debug"

local DEFAULT_DEBUG_LOGGING = false

local STEADY_WALL_MAX_STACKS = 5
local STEADY_WALL_DURATION = 5.0
local STEADY_WALL_BLOCK_PER_STACK = 4
local STEADY_WALL_ARMOR_PER_STACK = 3

local HALLOWED_GUARD_ABILITY_ID = "sps_hallowedguard"
local BULWARK_SELF_SPELL_ID = "sps_bullightself"
local AEGIS_RITE_WINDOW = 3.0
local AEGIS_RITE_MAGICKA_COST = 5

local configSection = storage.playerSection(CONFIG_SECTION_ID)
local baseCombatInterface = nil
local momentumExpirations = {}
local runtimeTime = 0
local hallowedGuardApplied = false
local hallowedGuardAddFailureLogged = false
local hallowedGuardRemoveFailureLogged = false
local hallowedGuardSpellBookFailureState = nil

local function logDebug(message)
    if configSection:get(DEBUG_LOGGING_KEY) == true then
        print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
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
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    return type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId) or false
end

local function perkEffectEnabled(perkId)
    if not perkOwned(perkId) then
        return false
    end

    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return false
    end

    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkId)
    end

    return true
end

local function hallowedGuardEnabled()
    return perkEffectEnabled(HALLOWED_GUARD_PERK_ID)
end

local function shieldFundamentalsEnabled()
    return perkEffectEnabled(SHIELD_FUNDAMENTALS_PERK_ID)
end

local function guardiansHabitEnabled()
    return perkEffectEnabled(GUARDIANS_HABIT_PERK_ID)
end

local function steadyWallEnabled()
    return perkEffectEnabled(STEADY_WALL_PERK_ID)
end

local function bulwarkOfLightEnabled()
    return perkEffectEnabled(BULWARK_OF_LIGHT_PERK_ID)
end

local function aegisRiteEnabled()
    return perkEffectEnabled(AEGIS_RITE_PERK_ID)
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

    return records[HALLOWED_GUARD_ABILITY_ID]
end

local function spellBookHasHallowedGuard(spells)
    if spells == nil then
        return false
    end

    if type(spells.has) == "function" then
        local okHasById, valueById = pcall(function()
            return spells:has(HALLOWED_GUARD_ABILITY_ID)
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
        if type(spell) == "table" and spell.id == HALLOWED_GUARD_ABILITY_ID then
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
        spells:add(HALLOWED_GUARD_ABILITY_ID)
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
        spells:remove(HALLOWED_GUARD_ABILITY_ID)
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
                logDebug(string.format("failed to add %s: %s", HALLOWED_GUARD_ABILITY_ID, tostring(addError)))
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
                logDebug(string.format("failed to remove %s: %s", HALLOWED_GUARD_ABILITY_ID, tostring(removeError)))
            end
            return
        end
        hallowedGuardRemoveFailureLogged = false
        hallowedGuardApplied = false
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
    return getMomentumStackCount() * STEADY_WALL_ARMOR_PER_STACK
end

local function getMomentumBlockBonus()
    if not steadyWallEnabled() then
        return 0
    end
    if not hasValidShieldSetup() then
        return 0
    end
    return getMomentumStackCount() * STEADY_WALL_BLOCK_PER_STACK
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

    local bonusArmor = 0
    if shouldApplyShieldFundamentalsBonus() then
        bonusArmor = bonusArmor + getBlockSkillBonus()
    end
    bonusArmor = bonusArmor + getMomentumArmorBonus()

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
    if not trySpendMagicka(AEGIS_RITE_MAGICKA_COST) then
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
    if #momentumExpirations < STEADY_WALL_MAX_STACKS then
        momentumExpirations[#momentumExpirations + 1] = runtimeTime + STEADY_WALL_DURATION
    else
        local oldestIndex = 1
        local oldestTime = momentumExpirations[1]
        for i = 2, #momentumExpirations do
            if momentumExpirations[i] < oldestTime then
                oldestTime = momentumExpirations[i]
                oldestIndex = i
            end
        end
        momentumExpirations[oldestIndex] = runtimeTime + STEADY_WALL_DURATION
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
        duration = AEGIS_RITE_WINDOW,
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
        id = BULWARK_SELF_SPELL_ID,
        effects = { 0 },
        caster = pself,
        stackable = false,
    })

    core.sendGlobalEvent("SkillPerkSystem_ApplyBulwarkOfLight", {
        blocker = pself,
    })
end

local function initializeDefaults()
    if configSection:get(DEBUG_LOGGING_KEY) == nil then
        configSection:set(DEBUG_LOGGING_KEY, DEFAULT_DEBUG_LOGGING)
    end
end

local function processBlockPerks(attack)
    applyGuardiansHabit(attack)
    applySteadyWallMomentum(attack)
    primeAegisRite(attack)
    applyBulwarkOfLight(attack)
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(processBlockPerks)
end

return {
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
        onLoad = function()
            initializeDefaults()
            runtimeTime = 0
            momentumExpirations = {}
            hallowedGuardApplied = false
            applyMomentumBlockModifier()
            updateHallowedGuardAbility()
        end,
        onUpdate = function(dt)
            runtimeTime = runtimeTime + (tonumber(dt) or 0)
            pruneMomentumStacks()
            applyMomentumBlockModifier()
            updateHallowedGuardAbility()
        end,
        onInterfaceOverride = function(base)
            baseCombatInterface = base
        end,
    },
}
