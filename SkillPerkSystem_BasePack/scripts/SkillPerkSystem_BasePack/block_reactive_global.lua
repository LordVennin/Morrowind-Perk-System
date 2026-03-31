local core = require("openmw.core")
local types = require("openmw.types")

local Item = types.Item
local Actor = types.Actor

local function resolveRange(effect)
    if effect == nil then
        return nil
    end

    local okRaw, rawRange = pcall(function()
        return effect.range or effect.castType
    end)
    if not okRaw then
        return nil
    end

    if type(rawRange) == "string" then
        local normalized = string.lower(rawRange)
        if normalized == "self" or normalized == "touch" or normalized == "target" then
            return normalized
        end
    end

    local rangeType = core.magic and (core.magic.RANGE or core.magic.RANGE_TYPE) or nil
    if rangeType ~= nil then
        if rawRange == rangeType.Self then return "self" end
        if rawRange == rangeType.Touch then return "touch" end
        if rawRange == rangeType.Target then return "target" end
    end

    return nil
end

local function getEnchantmentRecord(enchantmentId)
    local records = core.magic and core.magic.enchantments and core.magic.enchantments.records or nil
    if records == nil then
        return nil
    end

    local direct = records[enchantmentId]
    if direct ~= nil then
        return direct
    end

    local lowerId = type(enchantmentId) == "string" and string.lower(enchantmentId) or enchantmentId
    local lowered = records[lowerId]
    if lowered ~= nil then
        return lowered
    end

    for _, rec in pairs(records) do
        if rec ~= nil then
            local recId = rec.id
            if recId == enchantmentId then
                return rec
            end
            if type(recId) == "string" and type(enchantmentId) == "string" and string.lower(recId) == string.lower(enchantmentId) then
                return rec
            end
        end
    end

    return nil
end

local function splitEffectIndexes(enchantment)
    local selfIndexes = {}
    local attackerIndexes = {}
    local effects = enchantment and enchantment.effects or nil

    if effects == nil then
        return selfIndexes, attackerIndexes
    end

    for index, effect in ipairs(effects) do
        local range = resolveRange(effect)
        local zeroIndex = index - 1

        if range == "self" then
            table.insert(selfIndexes, zeroIndex)
        elseif range == "touch" or range == "target" then
            table.insert(attackerIndexes, zeroIndex)
        end
    end

    return selfIndexes, attackerIndexes
end

local function addEffectsToTarget(target, sourceItemId, effectIndexes, caster, item)
    if target == nil then
        return false
    end
    if type(sourceItemId) ~= "string" or sourceItemId == "" then
        return false
    end
    if type(effectIndexes) ~= "table" or #effectIndexes == 0 then
        return true
    end

    local ok, result = pcall(function()
        Actor.activeSpells(target):add({
            id = sourceItemId,
            effects = effectIndexes,
            caster = caster,
            item = item,
            stackable = true,
        })
        return true
    end)

    if not ok then
        return false
    end

    return result == true
end

local function onApplyReactiveShieldEnchant(e)
    if type(e) ~= "table" then
        return
    end

    local blocker = e.blocker
    local attacker = e.attacker
    local shield = e.shield
    local enchantmentId = e.enchantmentId

    if blocker == nil or shield == nil or type(enchantmentId) ~= "string" or enchantmentId == "" then
        return
    end

    local sourceItemId = shield.recordId
    if type(sourceItemId) ~= "string" or sourceItemId == "" then
        return
    end

    local enchantment = getEnchantmentRecord(enchantmentId)
    if enchantment == nil then
        return
    end

    local constantEffectType = core.magic and core.magic.ENCHANTMENT_TYPE and core.magic.ENCHANTMENT_TYPE.ConstantEffect or nil
    if constantEffectType ~= nil and enchantment.type == constantEffectType then
        return
    end

    local itemData = Item and type(Item.itemData) == "function" and Item.itemData(shield) or nil
    if itemData == nil then
        return
    end

    local enchantCost = tonumber(enchantment.cost or enchantment.enchantmentCost or enchantment.castCost) or 0
    local maxCharge = tonumber(enchantment.charge or enchantment.maxCharge or enchantment.enchantmentCharge)
    local currentCharge = tonumber(itemData.enchantmentCharge)
    if currentCharge == nil and type(maxCharge) == "number" then
        currentCharge = maxCharge
    end

    if currentCharge == nil then
        return
    end
    if enchantCost > 0 and currentCharge < enchantCost then
        return
    end

    local selfIndexes, attackerIndexes = splitEffectIndexes(enchantment)
    if #selfIndexes == 0 and #attackerIndexes == 0 then
        return
    end

    local appliedAny = false
    if #selfIndexes > 0 then
        appliedAny = addEffectsToTarget(blocker, sourceItemId, selfIndexes, blocker, shield) or appliedAny
    end
    if attacker ~= nil and #attackerIndexes > 0 then
        appliedAny = addEffectsToTarget(attacker, sourceItemId, attackerIndexes, blocker, shield) or appliedAny
    end

    if not appliedAny then
        return
    end

    if enchantCost > 0 then
        local nextCharge = math.max(0, currentCharge - enchantCost)
        itemData.enchantmentCharge = nextCharge
    end
end

return {
    eventHandlers = {
        SkillPerkSystem_ApplyReactiveShieldEnchant = onApplyReactiveShieldEnchant,
    },
}
