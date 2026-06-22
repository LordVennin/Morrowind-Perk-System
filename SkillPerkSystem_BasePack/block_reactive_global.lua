-- Superseded by scripts/SkillPerkSystem_BasePack/basepack_global.lua; kept temporarily for save/development compatibility.
local core = require("openmw.core")
local types = require("openmw.types")

local Item = types.Item
local Actor = types.Actor

local REACTIVE_DEFAULT_VFX_MODEL = "meshes\\e\\magic_hit_myst.nif"
local REACTIVE_DEFAULT_SOUND_FILE = "Sound\\Fx\\magic\\mystH.wav"

local PRESENTATION_BY_EFFECT_ID = {
    -- Destruction / elemental damage
    firedamage = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    frostdamage = {
        vfx = "meshes\\e\\magic_hit_frost.nif",
        sound = "Sound\\Fx\\magic\\frstH.wav",
    },
    shockdamage = {
        vfx = "meshes\\e\\magic_hit_s.nif",
        sound = "Sound\\Fx\\magic\\shokH.wav",
    },

    -- Destruction / generic hostile damage-drain effects
    damagehealth = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damagefatigue = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damagemagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damageattribute = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    damageskill = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainhealth = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainfatigue = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainmagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainattribute = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    drainskill = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessfire = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessfrost = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessshock = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessmagicka = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesscommondisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknessblightdisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesscorprusdisease = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    weaknesspoison = {
        vfx = "meshes\\e\\magic_hit_dst.nif",
        sound = "Sound\\Fx\\magic\\destH.wav",
    },
    poison = {
        vfx = "meshes\\e\\magic_hit_poison.nif",
        sound = "Sound\\Fx\\magic\\poisH.wav",
    },

    -- Mysticism
    absorbhealth = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbfatigue = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbmagicka = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbattribute = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    absorbskill = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    telekinesis = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectkey = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectanimal = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    detectenchantment = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    mark = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    recall = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    dispel = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },
    soultrap = {
        vfx = "meshes\\e\\magic_hit_myst.nif",
        sound = "Sound\\Fx\\magic\\mystH.wav",
    },

    -- Restoration / beneficial effects
    restorehealth = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    restorefatigue = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    restoremagicka = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyhealth = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyfatigue = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifymagicka = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyattribute = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fortifyskill = {
        vfx = "meshes\\e\\magic_hit_rest.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },

    -- Illusion
    sanctuary = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    chameleon = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    invisibility = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    blind = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    light = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    nighteye = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmcreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmanimal = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    calmhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    frenzycreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    frenzyhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    demoralizecreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    demoralizehumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    rallycreature = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },
    rallyhumanoid = {
        vfx = "meshes\\e\\magic_hit_ill.nif",
        sound = "Sound\\Fx\\magic\\illuH.wav",
    },

    -- Alteration-ish fallback
    shield = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    fireresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    frostresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    shockresist = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    resistmagicka = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    waterbreathing = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    waterwalking = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    levitate = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    slowfall = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    jump = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    open = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
    lock = {
        vfx = "meshes\\e\\magic_hit_purple.nif",
        sound = "Sound\\Fx\\magic\\restH.wav",
    },
}

local function normalizeEffectId(effectId)
    if type(effectId) ~= "string" then
        return nil
    end
    return string.lower(effectId)
end

local function getEffectId(effect)
    if effect == nil then
        return nil
    end

    local ok, value = pcall(function()
        return effect.id or (effect.effect and effect.effect.id) or effect.effect
    end)
    if ok then
        return normalizeEffectId(value)
    end
    return nil
end

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

local function getPresentationForEnchantment(enchantment)
    local effects = enchantment and enchantment.effects or nil
    if effects ~= nil then
        for _, effect in ipairs(effects) do
            local effectId = getEffectId(effect)
            if effectId ~= nil then
                local mapped = PRESENTATION_BY_EFFECT_ID[effectId]
                if mapped ~= nil then
                    return mapped
                end
            end
        end
    end

    return {
        vfx = REACTIVE_DEFAULT_VFX_MODEL,
        sound = REACTIVE_DEFAULT_SOUND_FILE,
    }
end

local function addVfx(target, model, vfxId)
    if target == nil or type(model) ~= "string" or model == "" then
        return
    end

    target:sendEvent("AddVfx", {
        model = model,
        options = {
            vfxId = vfxId,
            loop = false,
        }
    })
end

local function playSound(target, soundFile)
    if target == nil or type(soundFile) ~= "string" or soundFile == "" then
        return
    end

    core.sound.playSoundFile3d(soundFile, target, {
        volume = 1.0,
        pitch = 1.0,
        loop = false,
    })
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

local function applyPresentation(target, presentation, label)
    if target == nil or presentation == nil then
        return
    end

    addVfx(target, presentation.vfx, "sps_reactive_" .. tostring(label))
    playSound(target, presentation.sound)
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

    local presentation = getPresentationForEnchantment(enchantment)
    local appliedAny = false

    if #selfIndexes > 0 then
        local appliedSelf = addEffectsToTarget(blocker, sourceItemId, selfIndexes, blocker, shield)
        appliedAny = appliedSelf or appliedAny
        if appliedSelf then
            applyPresentation(blocker, presentation, "self")
        end
    end

    if attacker ~= nil and #attackerIndexes > 0 then
        local appliedAttacker = addEffectsToTarget(attacker, sourceItemId, attackerIndexes, blocker, shield)
        appliedAny = appliedAttacker or appliedAny
        if appliedAttacker then
            applyPresentation(attacker, presentation, "target")
        end
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
