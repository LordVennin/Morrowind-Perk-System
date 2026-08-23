-- Hand To Hand player runtime for SkillPerkSystem_BasePack.
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

local Actor = types.Actor
local Armor = types.Armor
local Clothing = types.Clothing
local NPC = types.NPC
local Weapon = types.Weapon

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local CENTERED_STANCE_PERK_ID = "handtohand_centered_stance"
local OPEN_PALM_PERK_ID = "handtohand_open_palm"
local IRON_KNUCKLES_PERK_ID = "handtohand_iron_knuckles"
local FLOWING_COUNTER_PERK_ID = "handtohand_flowing_counter"
local EMPTY_BODY_MASTERY_PERK_ID = "handtohand_empty_body_mastery"
local BREAKING_FIST_PERK_ID = "handtohand_breaking_fist"
local CENTERED_STANCE_BONUS = 3
local FLOWING_COUNTER_ABILITY_ID = "sps_DeflectingPalm"
local FLOWING_COUNTER_HEAVY_AGILITY_PENALTY = 10
local FLOWING_COUNTER_HEAVY_ATTACK_SPEED_MULTIPLIER = 0.80
local OPEN_PALM_BONUS_PER_STACK = 3
local OPEN_PALM_MAX_STACKS = 5
local OPEN_PALM_DURATION = 6.0
local HAND_TO_HAND_STATE_EVENT = "SkillPerkSystem_HandToHandState"
local HAND_TO_HAND_IDLE_REFRESH_INTERVAL = 0.5

local appliedBonuses = {}
local flowingCounterAppliedAgilityPenalty = 0
local flowingCounterAbilityApplied = false
local resolveAttributeStat
local openPalmStacks = 0
local openPalmRemaining = 0
local appliedOpenPalmBonus = 0
local handToHandStateDirty = true
local handToHandIdleRefreshTimer = HAND_TO_HAND_IDLE_REFRESH_INTERVAL
local handToHandDirty = true
local handToHandScanRemaining = 0
local handToHandScanTimer = 0
local HAND_TO_HAND_SCAN_WINDOW = 1.5
local HAND_TO_HAND_SCAN_INTERVAL = 0.25
local DEFAULT_HAND_TO_HAND_STATE_KEY = "false:false:none"
local lastHandToHandStateKey = nil
local handToHandEquipmentCache = {
    key = nil,
    hasWeaponOrShield = true,
    flowingCounterMode = "none",
}
local lastEmptyBodyAttackShape = nil
local EMPTY_BODY_DEBUG = true

local function logEmptyBodyDebug(message)
    if EMPTY_BODY_DEBUG then
        print("[SkillPerkSystem_BasePack][EmptyBody][Player][debug] " .. tostring(message))
    end
end

local ATTRIBUTES = {
    "agility",
    "endurance",
    "willpower",
}

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

local function getEquippedItem(slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, pself, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getArmorRecord(item)
    if item == nil or Armor == nil then
        return nil
    end

    if type(Armor.record) == "function" then
        local okRecord, record = pcall(Armor.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Armor.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Armor.records) == "table" then
        return Armor.records[item.recordId]
    end

    if item.type ~= nil and type(item.type.records) == "table" and type(item.recordId) == "string" then
        return item.type.records[item.recordId]
    end

    return nil
end

local function getClothingRecord(item)
    if item == nil or Clothing == nil then
        return nil
    end

    if type(Clothing.record) == "function" then
        local okRecord, record = pcall(Clothing.record, item)
        if okRecord and record ~= nil then
            return record
        end
        if type(item.recordId) == "string" then
            local okRecordId, recordFromId = pcall(Clothing.record, item.recordId)
            if okRecordId and recordFromId ~= nil then
                return recordFromId
            end
        end
    end

    if type(item.recordId) == "string" and type(Clothing.records) == "table" then
        return Clothing.records[item.recordId]
    end

    return nil
end

local function itemIsWeapon(item)
    return item ~= nil and Weapon ~= nil and type(Weapon.objectIsInstance) == "function" and Weapon.objectIsInstance(item)
end

local function itemIsShield(item)
    if item == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return false
    end

    local record = getArmorRecord(item)
    return record ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE.Shield
end

local function armorTypeEquals(record, typeName)
    return record ~= nil and Armor ~= nil and Armor.TYPE ~= nil and record.type == Armor.TYPE[typeName]
end

local function clothingTypeEquals(record, typeName)
    return record ~= nil and Clothing ~= nil and Clothing.TYPE ~= nil and record.type == Clothing.TYPE[typeName]
end

local function getGloveRecordFromItem(item)
    if item == nil then
        return nil
    end
    if Armor == nil or type(Armor.objectIsInstance) ~= "function" or not Armor.objectIsInstance(item) then
        return nil
    end

    return getArmorRecord(item)
end

local function getEmptyBodyHandRecord(item, hand)
    if item == nil then
        return nil, nil
    end

    if Armor ~= nil and type(Armor.objectIsInstance) == "function" and Armor.objectIsInstance(item) then
        local record = getArmorRecord(item)
        local expectedGauntletType = hand == "right" and "RGauntlet" or "LGauntlet"
        local expectedBracerType = hand == "right" and "RBracer" or "LBracer"

        if armorTypeEquals(record, expectedGauntletType) or armorTypeEquals(record, expectedBracerType) then
            return record, "armor"
        end
    end

    if Clothing ~= nil and type(Clothing.objectIsInstance) == "function" and Clothing.objectIsInstance(item) then
        local record = getClothingRecord(item)
        local expectedGloveType = hand == "right" and "RGlove" or "LGlove"

        if clothingTypeEquals(record, expectedGloveType) then
            return record, "clothing"
        end
    end

    return nil, nil
end

local function normalizedRecordText(record)
    local parts = {}
    if type(record.id) == "string" then
        parts[#parts + 1] = record.id
    end
    if type(record.name) == "string" then
        parts[#parts + 1] = record.name
    end
    if type(record.icon) == "string" then
        parts[#parts + 1] = record.icon
    end
    if type(record.model) == "string" then
        parts[#parts + 1] = record.model
    end

    return string.lower(table.concat(parts, " "))
end

local function gloveArmorClass(record)
    if record == nil then
        return "none"
    end

    local recordText = normalizedRecordText(record)
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
            return "light"
        end
    end

    local mediumArmorHints = {
        "adamantium",
        "bonemold",
        "chain",
        "ice armor",
        "imperial chain",
        "orcish",
        "royal guard",
        "scale",
        "snow bear",
        "snow wolf",
    }
    for _, hint in ipairs(mediumArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return "medium"
        end
    end

    local heavyArmorHints = {
        "daedric",
        "dwemer",
        "ebony",
        "her hand",
        "imperial steel",
        "iron",
        "nordic mail",
        "steel",
    }
    for _, hint in ipairs(heavyArmorHints) do
        if string.find(recordText, hint, 1, true) ~= nil then
            return "heavy"
        end
    end

    -- OpenMW exposes the armor body-part type but not the TES3 armor skill
    -- class through ArmorRecord, so use the record's weight as a final
    -- fallback for modded gloves that do not include vanilla material names.
    local weight = tonumber(record.weight) or 0
    if weight <= 2 then
        return "light"
    elseif weight <= 6 then
        return "medium"
    end

    return "heavy"
end

local function itemCacheKey(item)
    if item == nil then
        return ""
    end

    return tostring(item.recordId or item.id or "")
end

local function readHandToHandEquipmentSnapshot()
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil then
        return {
            key = "equipment-slots-unavailable",
            carriedRight = nil,
            carriedLeft = nil,
            leftGlove = nil,
            rightGlove = nil,
        }
    end

    local carriedRight = getEquippedItem(slots.CarriedRight)
    local carriedLeft = getEquippedItem(slots.CarriedLeft)
    local leftGlove = getEquippedItem(slots.LeftGauntlet)
    local rightGlove = getEquippedItem(slots.RightGauntlet)

    return {
        key = table.concat({
            itemCacheKey(carriedRight),
            itemCacheKey(carriedLeft),
            itemCacheKey(leftGlove),
            itemCacheKey(rightGlove),
            tostring(hasEnabledPerk(FLOWING_COUNTER_PERK_ID)),
        }, "|"),
        carriedRight = carriedRight,
        carriedLeft = carriedLeft,
        leftGlove = leftGlove,
        rightGlove = rightGlove,
    }
end

local function computeHasEquippedWeaponOrShield(snapshot)
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return true
    end

    return itemIsWeapon(snapshot.carriedRight)
        or itemIsShield(snapshot.carriedRight)
        or itemIsWeapon(snapshot.carriedLeft)
        or itemIsShield(snapshot.carriedLeft)
end

local function computeFlowingCounterMode(snapshot)
    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) or Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return "none"
    end

    local leftRecord = getGloveRecordFromItem(snapshot.leftGlove)
    local rightRecord = getGloveRecordFromItem(snapshot.rightGlove)
    local leftHasGlove = leftRecord ~= nil and (armorTypeEquals(leftRecord, "LGauntlet") or armorTypeEquals(leftRecord, "LBracer"))
    local rightHasGlove = rightRecord ~= nil and (armorTypeEquals(rightRecord, "RGauntlet") or armorTypeEquals(rightRecord, "RBracer"))

    if not leftHasGlove and not rightHasGlove then
        return "bare"
    end
    if not leftHasGlove or not rightHasGlove then
        return "none"
    end

    local leftClass = gloveArmorClass(leftRecord)
    local rightClass = gloveArmorClass(rightRecord)
    if leftClass == rightClass then
        return leftClass
    end

    return "none"
end

local function refreshHandToHandEquipmentCache(force)
    local snapshot = readHandToHandEquipmentSnapshot()
    if not force and handToHandEquipmentCache.key == snapshot.key then
        return
    end

    handToHandEquipmentCache = {
        key = snapshot.key,
        hasWeaponOrShield = computeHasEquippedWeaponOrShield(snapshot),
        flowingCounterMode = computeFlowingCounterMode(snapshot),
    }
end

local function cachedHasEquippedWeaponOrShield()
    return handToHandEquipmentCache.hasWeaponOrShield == true
end

local function cachedFlowingCounterMode()
    return type(handToHandEquipmentCache.flowingCounterMode) == "string" and handToHandEquipmentCache.flowingCounterMode or "none"
end

local function resolveAbilityRecord(abilityId)
    local okRecords, records = pcall(function()
        return core.magic.spells.records
    end)
    if okRecords and type(records) == "table" then
        return records[abilityId]
    end
    return nil
end

local function playerHasAbility(spells, abilityId)
    if spells == nil then
        return false
    end
    if type(spells.has) == "function" then
        local okHasById, hasById = pcall(function()
            return spells:has(abilityId)
        end)
        if okHasById and hasById == true then
            return true
        end

        local record = resolveAbilityRecord(abilityId)
        if record ~= nil then
            local okHasByRecord, hasByRecord = pcall(function()
                return spells:has(record)
            end)
            if okHasByRecord and hasByRecord == true then
                return true
            end
        end
    end

    for _, spell in pairs(spells) do
        if type(spell) == "table" and spell.id == abilityId then
            return true
        end
    end

    return false
end

local function setPlayerAbility(abilityId, shouldHave)
    if Actor == nil or type(Actor.spells) ~= "function" then
        return shouldHave and flowingCounterAbilityApplied or false
    end

    local okSpells, spells = pcall(Actor.spells, pself)
    if not okSpells or spells == nil then
        return shouldHave and flowingCounterAbilityApplied or false
    end

    local hasAbility = playerHasAbility(spells, abilityId)
    if shouldHave and not hasAbility and type(spells.add) == "function" then
        local ok = pcall(function()
            spells:add(abilityId)
        end)
        if not ok then
            local record = resolveAbilityRecord(abilityId)
            if record ~= nil then
                ok = pcall(function()
                    spells:add(record)
                end)
            end
        end
        return ok or flowingCounterAbilityApplied
    elseif not shouldHave and type(spells.remove) == "function" then
        local ok = pcall(function()
            spells:remove(abilityId)
        end)
        if not ok then
            local record = resolveAbilityRecord(abilityId)
            if record ~= nil then
                ok = pcall(function()
                    spells:remove(record)
                end)
            end
        end
        return not ok and flowingCounterAbilityApplied or false
    end

    return shouldHave and hasAbility
end

local function applyFlowingCounterAgilityPenalty(targetPenalty)
    local desired = math.max(0, math.floor(tonumber(targetPenalty) or 0))
    local current = math.max(0, math.floor(tonumber(flowingCounterAppliedAgilityPenalty) or 0))
    if desired == current then
        return
    end

    local stat = resolveAttributeStat("agility")
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier + current - desired
    flowingCounterAppliedAgilityPenalty = desired
end

function resolveAttributeStat(attributeID)
    local accessor = Actor ~= nil
        and Actor.stats ~= nil
        and Actor.stats.attributes ~= nil
        and Actor.stats.attributes[attributeID]
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyAttributeBonus(attributeID, targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedBonuses[attributeID]) or 0))
    if desired == current then
        return
    end

    local stat = resolveAttributeStat(attributeID)
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedBonuses[attributeID] = desired
end


local function resolveHandToHandStat()
    local accessor = NPC ~= nil
        and NPC.stats ~= nil
        and NPC.stats.skills ~= nil
        and NPC.stats.skills.handtohand
    if type(accessor) ~= "function" then
        return nil
    end

    return accessor(pself)
end

local function applyOpenPalmBonus(targetBonus)
    local desired = math.max(0, math.floor(tonumber(targetBonus) or 0))
    local current = math.max(0, math.floor(tonumber(appliedOpenPalmBonus) or 0))
    if desired == current then
        return
    end

    local stat = resolveHandToHandStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        return
    end

    stat.modifier = stat.modifier - current + desired
    appliedOpenPalmBonus = desired
end

local function clearOpenPalmStacks()
    openPalmStacks = 0
    openPalmRemaining = 0
    applyOpenPalmBonus(0)
end

local function tryApplyOpenPalm(data)
    if type(data) ~= "table" or data.target == nil then
        return
    end
    refreshHandToHandEquipmentCache(true)
    if not hasEnabledPerk(OPEN_PALM_PERK_ID) or cachedHasEquippedWeaponOrShield() then
        clearOpenPalmStacks()
        return
    end

    openPalmStacks = math.min(OPEN_PALM_MAX_STACKS, math.max(0, math.floor(tonumber(openPalmStacks) or 0)) + 1)
    openPalmRemaining = OPEN_PALM_DURATION
    applyOpenPalmBonus(openPalmStacks * OPEN_PALM_BONUS_PER_STACK)
end

local function updateOpenPalm(dt)
    if openPalmStacks <= 0 then
        if appliedOpenPalmBonus ~= 0 then
            applyOpenPalmBonus(0)
        end
        return
    end

    if not hasEnabledPerk(OPEN_PALM_PERK_ID) or cachedHasEquippedWeaponOrShield() then
        clearOpenPalmStacks()
        return
    end

    openPalmRemaining = math.max(0, (tonumber(openPalmRemaining) or 0) - (tonumber(dt) or 0))
    if openPalmRemaining <= 0 then
        clearOpenPalmStacks()
    else
        applyOpenPalmBonus(openPalmStacks * OPEN_PALM_BONUS_PER_STACK)
    end
end

local function refreshHandToHandState(force)
    local openPalmEnabled = hasEnabledPerk(OPEN_PALM_PERK_ID)
    local ironKnucklesEnabled = hasEnabledPerk(IRON_KNUCKLES_PERK_ID)
    local breakingFistEnabled = hasEnabledPerk(BREAKING_FIST_PERK_ID)
    local emptyBodyMasteryEnabled = hasEnabledPerk(EMPTY_BODY_MASTERY_PERK_ID)
    local flowingCounterMode = hasEnabledPerk(FLOWING_COUNTER_PERK_ID) and cachedFlowingCounterMode() or "none"
    local stateKey = tostring(openPalmEnabled) .. ":"
        .. tostring(ironKnucklesEnabled) .. ":"
        .. tostring(breakingFistEnabled) .. ":"
        .. tostring(emptyBodyMasteryEnabled) .. ":"
        .. tostring(flowingCounterMode)
    if not force and stateKey == lastHandToHandStateKey then
        return
    end

    lastHandToHandStateKey = stateKey
    core.sendGlobalEvent(HAND_TO_HAND_STATE_EVENT, {
        player = pself,
        playerId = pself.id,
        openPalmEnabled = openPalmEnabled,
        ironKnucklesEnabled = ironKnucklesEnabled,
        breakingFistEnabled = breakingFistEnabled,
        emptyBodyMasteryEnabled = emptyBodyMasteryEnabled,
        flowingCounterMode = flowingCounterMode,
    })
end

local function refreshFlowingCounter()
    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) then
        if flowingCounterAbilityApplied then
            flowingCounterAbilityApplied = setPlayerAbility(FLOWING_COUNTER_ABILITY_ID, false)
        end
        if flowingCounterAppliedAgilityPenalty ~= 0 then
            applyFlowingCounterAgilityPenalty(0)
        end
        return
    end

    local mode = cachedFlowingCounterMode()
    flowingCounterAbilityApplied = setPlayerAbility(FLOWING_COUNTER_ABILITY_ID, mode == "bare")
    applyFlowingCounterAgilityPenalty(mode == "heavy" and FLOWING_COUNTER_HEAVY_AGILITY_PENALTY or 0)
end

local function hasAppliedCenteredStanceBonus()
    for _, attributeID in ipairs(ATTRIBUTES) do
        if math.max(0, math.floor(tonumber(appliedBonuses[attributeID]) or 0)) ~= 0 then
            return true
        end
    end
    return false
end

local function refreshCenteredStance()
    local centeredStanceEnabled = hasEnabledPerk(CENTERED_STANCE_PERK_ID)
    if not centeredStanceEnabled and not hasAppliedCenteredStanceBonus() then
        return
    end

    local desiredBonus = 0
    if centeredStanceEnabled and not cachedHasEquippedWeaponOrShield() then
        desiredBonus = CENTERED_STANCE_BONUS
    end

    for _, attributeID in ipairs(ATTRIBUTES) do
        applyAttributeBonus(attributeID, desiredBonus)
    end
end

local HAND_TO_HAND_STATE_PERKS = {
    handtohand_centered_stance = true,
    handtohand_open_palm = true,
    handtohand_iron_knuckles = true,
    handtohand_flowing_counter = true,
    handtohand_empty_body_mastery = true,
    handtohand_breaking_fist = true,
}

local function markHandToHandDirty(scanWindow)
    handToHandDirty = true
    handToHandStateDirty = true
    handToHandScanRemaining = math.max(handToHandScanRemaining, tonumber(scanWindow) or HAND_TO_HAND_SCAN_WINDOW)
    handToHandScanTimer = HAND_TO_HAND_SCAN_INTERVAL
end

local function showVitalStrikeMessage()
    ui.showMessage(VITAL_STRIKE_CRITICAL_MESSAGE, { showInDialogue = false })
end

local function handlePerkStateChanged(data)
    if type(data) ~= "table" or HAND_TO_HAND_STATE_PERKS[data.perkID] ~= true then
        return
    end
    markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
end

local function shouldRunHandToHandUpdate(dt)
    if handToHandDirty
        or handToHandStateDirty
        or openPalmStacks > 0
        or appliedOpenPalmBonus ~= 0
        or (hasAppliedCenteredStanceBonus() and not hasEnabledPerk(CENTERED_STANCE_PERK_ID))
        or ((flowingCounterAbilityApplied or flowingCounterAppliedAgilityPenalty ~= 0) and not hasEnabledPerk(FLOWING_COUNTER_PERK_ID)) then
        return true
    end

    handToHandScanRemaining = math.max(0, handToHandScanRemaining - (tonumber(dt) or 0))
    if handToHandScanRemaining <= 0 then
        return false
    end

    handToHandScanTimer = handToHandScanTimer + (tonumber(dt) or 0)
    if handToHandScanTimer < HAND_TO_HAND_SCAN_INTERVAL then
        return false
    end

    handToHandScanTimer = 0
    return true
end

local function resolveAttackShapeFromText(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = string.lower(value)
    if string.find(normalized, "thrust", 1, true) ~= nil then
        return "thrust"
    end
    if string.find(normalized, "slash", 1, true) ~= nil then
        return "slash"
    end
    if string.find(normalized, "chop", 1, true) ~= nil then
        return "chop"
    end

    return nil
end

local function resolveAttackShapeFromType(value)
    local attackTypes = interfaces.Combat ~= nil and interfaces.Combat.ATTACK_TYPES or nil
    if attackTypes ~= nil then
        if value == attackTypes.Chop then
            return "chop"
        end
        if value == attackTypes.Slash then
            return "slash"
        end
        if value == attackTypes.Thrust then
            return "thrust"
        end
    end

    return resolveAttackShapeFromText(value)
end

local function resolveHandToHandAttackShape(attack)
    if type(attack) ~= "table" then
        return lastEmptyBodyAttackShape
    end

    local candidates = {
        attack.attackType,
        attack.type,
        attack.attack,
        attack.attackKind,
        attack.attackSource,
        attack.source,
        attack.animation,
        attack.animationName,
        attack.groupName,
        attack.startKey,
        attack.stopKey,
    }

    for _, candidate in ipairs(candidates) do
        local shape = resolveAttackShapeFromType(candidate)
        if shape ~= nil then
            return shape
        end
    end

    return lastEmptyBodyAttackShape
end

local function getEnchantedGloveForAttackShape(shape)
    if Actor == nil or Actor.EQUIPMENT_SLOT == nil then
        return nil, nil, nil
    end

    local slot = nil
    local hand = nil
    if shape == "chop" or shape == "slash" then
        slot = Actor.EQUIPMENT_SLOT.RightGauntlet
        hand = "right"
    elseif shape == "thrust" then
        slot = Actor.EQUIPMENT_SLOT.LeftGauntlet
        hand = "left"
    end

    if slot == nil then
        logEmptyBodyDebug("no glove slot for shape=" .. tostring(shape))
        return nil, nil, nil
    end

    local glove = getEquippedItem(slot)
    local record, recordKind = getEmptyBodyHandRecord(glove, hand)
    if record == nil then
        logEmptyBodyDebug("no matching hand item equipped for hand=" .. tostring(hand))
        return nil, nil, nil
    end

    local enchantmentId = record.enchant or record.enchantment
    if type(enchantmentId) == "table" and type(enchantmentId.id) == "string" then
        enchantmentId = enchantmentId.id
    end
    if type(enchantmentId) ~= "string" or enchantmentId == "" then
        logEmptyBodyDebug("matching glove/bracer has no enchantment for hand=" .. tostring(hand))
        return nil, nil, nil
    end

    logEmptyBodyDebug("resolved hand=" .. tostring(hand) .. " kind=" .. tostring(recordKind) .. " enchantmentId=" .. tostring(enchantmentId))
    return glove, enchantmentId, hand
end

local function tryApplyEmptyBodyMastery(attack, target)
    if target == nil or not hasEnabledPerk(EMPTY_BODY_MASTERY_PERK_ID) then
        logEmptyBodyDebug("skipped missing target or disabled perk")
        return false
    end

    local shape = resolveHandToHandAttackShape(attack)
    if shape == nil then
        logEmptyBodyDebug("skipped unresolved attack shape")
        return false
    end
    logEmptyBodyDebug("resolved attackShape=" .. tostring(shape))

    local glove, enchantmentId, hand = getEnchantedGloveForAttackShape(shape)
    if glove == nil then
        return false
    end

    core.sendGlobalEvent("SkillPerkSystem_ApplyEmptyBodyGloveEnchant", {
        attacker = pself,
        target = target,
        glove = glove,
        enchantmentId = enchantmentId,
        hand = hand,
        attackShape = shape,
    })

    logEmptyBodyDebug("sent global enchant event hand=" .. tostring(hand))
    return true
end

local function handleTryEmptyBodyMastery(data)
    if type(data) ~= "table" then
        return
    end
    if data.target == nil then
        logEmptyBodyDebug("target-side request missing target")
        lastEmptyBodyAttackShape = nil
        return
    end

    tryApplyEmptyBodyMastery({
        type = data.attackType or data.type,
        attackType = data.attackType or data.type,
        attack = data.attack,
        attackKind = data.attackKind,
        attackSource = data.attackSource,
        source = data.source,
        animation = data.animation,
        animationName = data.animationName,
        groupName = data.groupName,
        startKey = data.startKey,
        stopKey = data.stopKey,
    }, data.target)
    lastEmptyBodyAttackShape = nil
end

local function handleHandToHandAnimation(event)
    markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
    if not event.isHandToHandAttackShape then
        return
    end

    local emptyBodyAttackShape = resolveAttackShapeFromText(event.startKeyLower)
        or resolveAttackShapeFromText(event.stopKeyLower)
        or resolveAttackShapeFromText(event.groupLower)
    if emptyBodyAttackShape ~= nil then
        lastEmptyBodyAttackShape = emptyBodyAttackShape
    end

    if not hasEnabledPerk(FLOWING_COUNTER_PERK_ID) then
        return
    end

    refreshHandToHandEquipmentCache(false)
    if cachedFlowingCounterMode() ~= "heavy" then
        return
    end
    if cachedHasEquippedWeaponOrShield() then
        return
    end

    multiplyAnimationSpeed(event.options, FLOWING_COUNTER_HEAVY_ATTACK_SPEED_MULTIPLIER)
end
registerBasepackAnimationHandler(handleHandToHandAnimation)


__basepack_subsystem_result = {
    eventHandlers = {
        SkillPerkSystem_TryOpenPalm = tryApplyOpenPalm,
        SkillPerkSystem_TryEmptyBodyMastery = handleTryEmptyBodyMastery,
        SkillPerkSystem_PerkStateChanged = handlePerkStateChanged,
        SkillPerkSystem_HandToHandStateDirty = function() markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW) end,
        UiModeChanged = function()
            markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
        end,
    },
    engineHandlers = {
        onUpdate = function(dt)
            handToHandDirty = false
            refreshHandToHandEquipmentCache(false)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(dt)
            if handToHandStateDirty then
                handToHandStateDirty = false
                refreshHandToHandState(false)
            end
        end,
        shouldUpdate = shouldRunHandToHandUpdate,
        onSave = function()
            refreshHandToHandEquipmentCache(true)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(0)
            refreshHandToHandState(true)
            return {
                centeredStanceAppliedBonuses = appliedBonuses,
                flowingCounterAppliedAgilityPenalty = flowingCounterAppliedAgilityPenalty,
                flowingCounterAbilityApplied = flowingCounterAbilityApplied,
                openPalmStacks = openPalmStacks,
                openPalmRemaining = openPalmRemaining,
                openPalmAppliedBonus = appliedOpenPalmBonus,
                handToHandEquipmentCache = {
                    key = handToHandEquipmentCache.key,
                    hasWeaponOrShield = handToHandEquipmentCache.hasWeaponOrShield == true,
                    flowingCounterMode = cachedFlowingCounterMode(),
                },
            }
        end,
        onLoad = function(data)
            if type(data) == "table" and type(data.centeredStanceAppliedBonuses) == "table" then
                appliedBonuses = data.centeredStanceAppliedBonuses
            else
                appliedBonuses = {}
            end
            flowingCounterAppliedAgilityPenalty = math.max(0, math.floor(tonumber(type(data) == "table" and data.flowingCounterAppliedAgilityPenalty) or 0))
            flowingCounterAbilityApplied = type(data) == "table" and data.flowingCounterAbilityApplied == true
            openPalmStacks = math.max(0, math.floor(tonumber(type(data) == "table" and data.openPalmStacks) or 0))
            openPalmRemaining = math.max(0, tonumber(type(data) == "table" and data.openPalmRemaining) or 0)
            appliedOpenPalmBonus = math.max(0, math.floor(tonumber(type(data) == "table" and data.openPalmAppliedBonus) or 0))
            handToHandIdleRefreshTimer = HAND_TO_HAND_IDLE_REFRESH_INTERVAL
            handToHandStateDirty = true
            markHandToHandDirty(HAND_TO_HAND_SCAN_WINDOW)
            local savedEquipmentCache = type(data) == "table"
                and type(data.handToHandEquipmentCache) == "table"
                and data.handToHandEquipmentCache
                or nil
            local savedFlowingCounterMode = type(savedEquipmentCache) == "table"
                and type(savedEquipmentCache.flowingCounterMode) == "string"
                and savedEquipmentCache.flowingCounterMode
                or "none"
            handToHandEquipmentCache = {
                key = type(savedEquipmentCache) == "table" and savedEquipmentCache.key or nil,
                hasWeaponOrShield = type(savedEquipmentCache) == "table" and savedEquipmentCache.hasWeaponOrShield == true,
                flowingCounterMode = savedFlowingCounterMode,
            }
            refreshHandToHandEquipmentCache(true)
            refreshCenteredStance()
            refreshFlowingCounter()
            updateOpenPalm(0)
            refreshHandToHandState(true)
        end,
    },
}


return __basepack_subsystem_result
