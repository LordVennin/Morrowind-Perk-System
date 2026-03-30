local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")
local paladinConfig = require("scripts.SkillPerkSystem_BasePack.perks.block.paladin_shielding_config")

local Actor = types.Actor
local Armor = types.Armor

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local LOG_TAG = "[SkillPerkSystem_BasePack][BlockEnchant]"
local BLOCK_PERKS = {
    "block_basic_guard",
    "block_reactive_guard",
    "block_bulwark_stance",
    "block_iron_wall",
}

local CONFIG_SECTION_ID = "SkillPerkSystem_BasePack_BlockEnchant"
local DEBUG_LOGGING_KEY = "block.enchant.debug"
local ENABLE_PROC_SCALING_KEY = "block.enchant.proc_scaling"
local BASE_PROC_CHANCE_KEY = "block.enchant.base_proc_chance"
local PROC_PER_RANK_KEY = "block.enchant.proc_per_rank"
local COOLDOWN_SECONDS_KEY = "block.enchant.cooldown_seconds"

local DEFAULT_DEBUG_LOGGING = false
local DEFAULT_ENABLE_PROC_SCALING = true
local DEFAULT_BASE_PROC_CHANCE = 0.15
local DEFAULT_PROC_PER_RANK = 0.08
local DEFAULT_COOLDOWN_SECONDS = 0.75

local PALADIN_PERKS = {
    arcaneBulwark = "block_arcane_bulwark",
    wardedRebuke = "block_warded_rebuke",
    mirrorAegis = "block_mirror_aegis",
    guardiansPulse = "block_guardians_pulse",
}

local configSection = storage.playerSection(CONFIG_SECTION_ID)
local paladinSection = paladinConfig.section()
local pairCooldowns = {}
local wardExpiresAt = 0
local supportPulseReadyAt = 0
local runtimeTime = 0

local function logDebug(message)
    if configSection:get(DEBUG_LOGGING_KEY) == true then
        print(string.format("%s[debug] %s", LOG_TAG, tostring(message)))
    end
end

local function readConfigNumber(key, fallback)
    local value = tonumber(configSection:get(key))
    if type(value) ~= "number" then
        return fallback
    end
    return value
end

local function readConfigBoolean(key, fallback)
    local value = configSection:get(key)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

local function readPaladinNumber(keyName)
    local key = paladinConfig.KEYS[keyName]
    local fallback = paladinConfig.DEFAULTS[keyName]
    local value = tonumber(paladinSection:get(key))
    if type(value) ~= "number" then
        return fallback
    end
    return value
end

local function debugPaladin(message)
    local debugKey = paladinConfig.KEYS.debugLogging
    if paladinSection:get(debugKey) == true then
        print(string.format("[SkillPerkSystem_BasePack][BlockPaladin][debug] %s", tostring(message)))
    end
end

local function resolveObjectKey(object)
    if object == nil then
        return "<nil>"
    end

    if type(object.id) == "string" and object.id ~= "" then
        return object.id
    end

    if type(object.recordId) == "string" and object.recordId ~= "" then
        return object.recordId .. "@" .. tostring(object)
    end

    return tostring(object)
end

local function blockPerkRank()
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil then
        return 0
    end

    local rank = 0
    for _, perkId in ipairs(BLOCK_PERKS) do
        local hasPerk = type(playerApi.hasPerk) == "function" and playerApi.hasPerk(perkId)
        if hasPerk then
            local enabled = true
            if type(playerApi.isPerkEffectEnabled) == "function" then
                enabled = playerApi.isPerkEffectEnabled(perkId)
            end
            if enabled then
                rank = rank + 1
            end
        end
    end

    return rank
end

local function getEquippedShield(actor)
    if actor == nil or Actor == nil or type(Actor.getEquipment) ~= "function" then
        return nil
    end

    local carriedLeftSlot = Actor.EQUIPMENT_SLOT ~= nil and Actor.EQUIPMENT_SLOT.CarriedLeft or nil
    if carriedLeftSlot == nil then
        return nil
    end

    local ok, equipped = pcall(Actor.getEquipment, actor, carriedLeftSlot)
    if not ok or equipped == nil then
        return nil
    end

    if Armor ~= nil and type(Armor.objectIsInstance) == "function" and not Armor.objectIsInstance(equipped) then
        return nil
    end

    local record = nil
    if equipped.type ~= nil and type(equipped.type.record) == "function" then
        local okRecord, value = pcall(equipped.type.record, equipped)
        if okRecord then
            record = value
        end
    end

    if record == nil or record.type ~= Armor.TYPE.Shield then
        return nil
    end

    return equipped, record
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

local function resolveEnchantmentRecord(shieldRecord)
    if type(shieldRecord) ~= "table" then
        return nil, nil
    end

    local enchantmentId = shieldRecord.enchant or shieldRecord.enchantment
    if type(enchantmentId) == "table" and type(enchantmentId.id) == "string" then
        enchantmentId = enchantmentId.id
    end
    if type(enchantmentId) ~= "string" or enchantmentId == "" then
        return nil, nil
    end

    local records = core.magic ~= nil and core.magic.enchantments ~= nil and core.magic.enchantments.records or nil
    if type(records) ~= "table" then
        return nil, nil
    end

    local enchantment = records[enchantmentId]
    return enchantment, enchantmentId
end

local function resolveRange(effect)
    local rawRange = type(effect) == "table" and (effect.range or effect.castType) or nil
    if rawRange == nil then
        return "self"
    end

    if type(rawRange) == "string" then
        local normalized = string.lower(rawRange)
        if normalized == "self" or normalized == "touch" or normalized == "target" then
            return normalized
        end
    end

    local magic = core.magic or {}
    local rangeType = magic.RANGE_TYPE or magic.RANGE or {}
    if rawRange == rangeType.Self then
        return "self"
    end
    if rawRange == rangeType.Touch then
        return "touch"
    end
    if rawRange == rangeType.Target then
        return "target"
    end

    return nil
end

local EFFECT_TO_STAT = {
    damagedhealth = "health",
    damagedmagicka = "magicka",
    damagedfatigue = "fatigue",
    restorehealth = "health",
    restoremagicka = "magicka",
    restorefatigue = "fatigue",
    drainhealth = "health",
    drainmagicka = "magicka",
    drainfatigue = "fatigue",
    firedamage = "health",
    frostdamage = "health",
    shockdamage = "health",
    poisondamage = "health",
    sundamage = "health",
}

local POSITIVE_EFFECTS = {
    restorehealth = true,
    restoremagicka = true,
    restorefatigue = true,
}

local function resolveEffectKey(effect)
    if type(effect) ~= "table" then
        return nil
    end

    local raw = effect.id or effect.effect
    if type(raw) == "table" then
        raw = raw.id
    end

    if type(raw) ~= "string" then
        return nil
    end

    local normalized = string.lower(raw)
    normalized = normalized:gsub("[^a-z]", "")
    return normalized
end

local function rollMagnitude(effect)
    local minValue = tonumber(effect.magnitudeMin or effect.minMagnitude or effect.min) or 0
    local maxValue = tonumber(effect.magnitudeMax or effect.maxMagnitude or effect.max) or minValue
    if maxValue < minValue then
        minValue, maxValue = maxValue, minValue
    end

    if maxValue == minValue then
        return minValue
    end

    return minValue + math.random() * (maxValue - minValue)
end

local function applySupportedEffect(effect, blocker, attacker)
    local key = resolveEffectKey(effect)
    local stat = key ~= nil and EFFECT_TO_STAT[key] or nil
    if key == nil or stat == nil then
        return false, "unsupported-effect"
    end

    local range = resolveRange(effect)
    if range == nil then
        return false, "unsupported-cast-type"
    end

    local recipient = blocker
    if range == "touch" or range == "target" then
        recipient = attacker
    end

    if recipient == nil or type(recipient.sendEvent) ~= "function" then
        return false, "recipient-unavailable"
    end

    local magnitude = rollMagnitude(effect)
    local duration = tonumber(effect.duration) or 1
    if duration < 1 then
        duration = 1
    end

    local amount = magnitude * duration
    if not POSITIVE_EFFECTS[key] then
        amount = -amount
    end

    recipient:sendEvent("ModifyStat", {
        name = stat,
        amount = amount,
    })

    return true, string.format("target=%s stat=%s amount=%.2f", resolveObjectKey(recipient), stat, amount)
end

local function getCurrentCharge(shield, enchantment)
    local itemData = (types.Item ~= nil and type(types.Item.itemData) == "function") and types.Item.itemData(shield) or nil
    if type(itemData) ~= "table" then
        return nil, nil
    end

    local maxCharge = tonumber(enchantment.charge or enchantment.maxCharge or enchantment.enchantmentCharge)
    local currentCharge = tonumber(itemData.enchantmentCharge)

    if currentCharge == nil and type(maxCharge) == "number" then
        currentCharge = maxCharge
    end

    return currentCharge, maxCharge
end

local function perkActive(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then
        return false
    end
    if not playerApi.hasPerk(perkId) then
        return false
    end
    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkId)
    end
    return true
end

local function isLikelyHostileSpellAttack(attack)
    if type(attack) ~= "table" then
        return false
    end
    local sourceText = string.lower(string.format(
        "%s %s %s %s",
        tostring(attack.type or ""),
        tostring(attack.attackType or ""),
        tostring(attack.source or ""),
        tostring(attack.hitSource or "")
    ))
    if sourceText:find("spell", 1, true) ~= nil or sourceText:find("magic", 1, true) ~= nil then
        return true
    end

    local damage = type(attack.damage) == "table" and attack.damage or {}
    return (tonumber(damage.magicka) or 0) > 0
end

local function restoreBlockedDamage(attack, multiplier)
    local damage = type(attack.damage) == "table" and attack.damage or {}
    local health = (tonumber(damage.health) or 0) * multiplier
    local magicka = (tonumber(damage.magicka) or 0) * multiplier
    local fatigue = (tonumber(damage.fatigue) or 0) * multiplier

    if health > 0 then
        pself:sendEvent("ModifyStat", { name = "health", amount = health })
    end
    if magicka > 0 then
        pself:sendEvent("ModifyStat", { name = "magicka", amount = magicka })
    end
    if fatigue > 0 then
        pself:sendEvent("ModifyStat", { name = "fatigue", amount = fatigue })
    end
end

local function applyPaladinShielding(attack)
    if not wasSuccessfulShieldBlock(attack) then
        return
    end

    local hostileSpell = isLikelyHostileSpellAttack(attack)
    if hostileSpell and perkActive(PALADIN_PERKS.arcaneBulwark) then
        local passiveResist = math.max(0, math.min(0.95, readPaladinNumber("passiveMagicResist")))
        restoreBlockedDamage(attack, passiveResist)
        debugPaladin(string.format("Arcane Bulwark mitigated hostile spell by %.2f%%", passiveResist * 100))
    end

    if perkActive(PALADIN_PERKS.wardedRebuke) then
        wardExpiresAt = runtimeTime + math.max(0, readPaladinNumber("wardDurationSeconds"))
        if hostileSpell and runtimeTime <= wardExpiresAt then
            local absorbPercent = math.max(0, math.min(0.95, readPaladinNumber("wardAbsorbPercent")))
            local damage = type(attack.damage) == "table" and attack.damage or {}
            local total = (tonumber(damage.health) or 0) + (tonumber(damage.magicka) or 0) + (tonumber(damage.fatigue) or 0)
            if total > 0 then
                pself:sendEvent("ModifyStat", { name = "magicka", amount = total * absorbPercent })
                debugPaladin(string.format("Warded Rebuke absorbed %.2f magicka", total * absorbPercent))
            end
        end
    end

    if hostileSpell and runtimeTime <= wardExpiresAt and perkActive(PALADIN_PERKS.mirrorAegis) then
        local reflectionChance = math.max(0, math.min(1, readPaladinNumber("reflectionChance")))
        if math.random() <= reflectionChance then
            local reflectionPercent = math.max(0, math.min(0.95, readPaladinNumber("reflectionPercent")))
            local damage = type(attack.damage) == "table" and attack.damage or {}
            local reflected = ((tonumber(damage.health) or 0) + (tonumber(damage.magicka) or 0)) * reflectionPercent
            local attacker = attack.attacker
            if reflected > 0 and attacker ~= nil and type(attacker.sendEvent) == "function" then
                attacker:sendEvent("ModifyStat", { name = "health", amount = -reflected })
                debugPaladin(string.format("Mirror Aegis reflected %.2f damage", reflected))
            end
        end
    end

    if perkActive(PALADIN_PERKS.guardiansPulse) and runtimeTime >= supportPulseReadyAt then
        local healAmount = math.max(0, readPaladinNumber("supportPulseHeal"))
        if healAmount > 0 then
            pself:sendEvent("ModifyStat", { name = "health", amount = healAmount })
        end
        supportPulseReadyAt = runtimeTime + math.max(0, readPaladinNumber("supportPulseCooldownSeconds"))
    end
end

local function getEnchantmentCost(enchantment)
    local cost = tonumber(enchantment.cost or enchantment.enchantmentCost or enchantment.castCost)
    if type(cost) ~= "number" or cost <= 0 then
        return 0
    end
    return cost
end

local function processShieldEnchantProc(attack)
    local rank = blockPerkRank()
    if rank <= 0 then
        return
    end

    local attacker = attack.attacker
    if attacker == nil then
        return
    end

    local shield, shieldRecord = getEquippedShield(pself)
    if shield == nil then
        return
    end

    if not wasSuccessfulShieldBlock(attack) then
        logDebug("block ignored: event did not qualify as successful shield block")
        return
    end

    applyPaladinShielding(attack)

    local cooldown = math.max(0, readConfigNumber(COOLDOWN_SECONDS_KEY, DEFAULT_COOLDOWN_SECONDS))
    local pairKey = resolveObjectKey(pself) .. "|" .. resolveObjectKey(attacker)
    local readyAt = pairCooldowns[pairKey] or 0
    if runtimeTime < readyAt then
        logDebug(string.format("cooldown active pair=%s readyIn=%.2f", pairKey, readyAt - runtimeTime))
        return
    end

    local baseProc = readConfigNumber(BASE_PROC_CHANCE_KEY, DEFAULT_BASE_PROC_CHANCE)
    local procPerRank = readConfigNumber(PROC_PER_RANK_KEY, DEFAULT_PROC_PER_RANK)
    local scalingEnabled = readConfigBoolean(ENABLE_PROC_SCALING_KEY, DEFAULT_ENABLE_PROC_SCALING)
    local procChance = baseProc
    if scalingEnabled then
        procChance = baseProc + procPerRank * math.max(rank - 1, 0)
    end
    procChance = math.max(0, math.min(1, procChance))

    local roll = math.random()
    if roll > procChance then
        logDebug(string.format("proc failed by chance roll=%.3f chance=%.3f rank=%d", roll, procChance, rank))
        return
    end

    local enchantment, enchantmentId = resolveEnchantmentRecord(shieldRecord)
    if enchantment == nil then
        logDebug("shield has no enchantment record")
        return
    end

    local enchantCost = getEnchantmentCost(enchantment)
    local currentCharge, maxCharge = getCurrentCharge(shield, enchantment)
    if currentCharge == nil then
        logDebug(string.format("could not resolve shield charge for enchantment=%s", tostring(enchantmentId)))
        return
    end

    if enchantCost > 0 and currentCharge < enchantCost then
        logDebug(string.format(
            "insufficient charge enchantment=%s current=%.2f required=%.2f",
            tostring(enchantmentId),
            currentCharge,
            enchantCost
        ))
        return
    end

    local effects = type(enchantment.effects) == "table" and enchantment.effects or {}
    local appliedEffects = 0
    for _, effect in ipairs(effects) do
        local applied, detail = applySupportedEffect(effect, pself, attacker)
        if applied then
            appliedEffects = appliedEffects + 1
            logDebug("effect applied " .. tostring(detail))
        else
            logDebug("effect skipped reason=" .. tostring(detail))
        end
    end

    if appliedEffects <= 0 then
        return
    end

    if enchantCost > 0 then
        local itemData = types.Item.itemData(shield)
        local nextCharge = math.max(0, currentCharge - enchantCost)
        itemData.enchantmentCharge = nextCharge
        logDebug(string.format(
            "charge consumed enchantment=%s before=%.2f after=%.2f max=%.2f cost=%.2f",
            tostring(enchantmentId),
            currentCharge,
            nextCharge,
            tonumber(maxCharge) or -1,
            enchantCost
        ))
    else
        logDebug(string.format("zero enchantment cost for %s; no charge consumed", tostring(enchantmentId)))
    end

    pairCooldowns[pairKey] = runtimeTime + cooldown
end

local function initializeDefaults()
    if configSection:get(DEBUG_LOGGING_KEY) == nil then
        configSection:set(DEBUG_LOGGING_KEY, DEFAULT_DEBUG_LOGGING)
    end
    if configSection:get(ENABLE_PROC_SCALING_KEY) == nil then
        configSection:set(ENABLE_PROC_SCALING_KEY, DEFAULT_ENABLE_PROC_SCALING)
    end
    if configSection:get(BASE_PROC_CHANCE_KEY) == nil then
        configSection:set(BASE_PROC_CHANCE_KEY, DEFAULT_BASE_PROC_CHANCE)
    end
    if configSection:get(PROC_PER_RANK_KEY) == nil then
        configSection:set(PROC_PER_RANK_KEY, DEFAULT_PROC_PER_RANK)
    end
    if configSection:get(COOLDOWN_SECONDS_KEY) == nil then
        configSection:set(COOLDOWN_SECONDS_KEY, DEFAULT_COOLDOWN_SECONDS)
    end
    paladinConfig.initializeDefaults()
end

interfaces.Combat.addOnHitHandler(processShieldEnchantProc)

return {
    engineHandlers = {
        onUpdate = function(dt)
            runtimeTime = runtimeTime + (tonumber(dt) or 0)
        end,
        onLoad = function()
            runtimeTime = 0
            pairCooldowns = {}
            wardExpiresAt = 0
            supportPulseReadyAt = 0
            initializeDefaults()
        end,
    },
}
