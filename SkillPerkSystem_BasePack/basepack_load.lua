-- Load-stage script for SkillPerkSystem_BasePack (OpenMW 0.51+).
--
-- Runs once, right after the content files are loaded, and injects the
-- records this pack needs that cannot be minted at runtime: custom magic
-- effects. A custom effect carries the look of the effect it is templated
-- on (school, icon, sounds) and none of its engine behaviour, so what it
-- does is entirely scripted: the player runtime watches for it becoming
-- active and acts. Records injected here are not written to saves, which is
-- fine, because this runs again on every launch.
--
-- Everything is guarded: on a build without the load context this script
-- errors harmlessly, and the runtime checks the record exists before it
-- hands the spell out.

local ok, content = pcall(require, "openmw.content")
if not ok or content == nil or content.magicEffects == nil then
    print("[SkillPerkSystem_BasePack][Load] openmw.content unavailable; custom effects not defined")
    return
end

local LOG_TAG = "[SkillPerkSystem_BasePack][Load]"

local function effectRecord(id)
    local okRecord, record = pcall(function() return content.magicEffects.records[id] end)
    return okRecord and record or nil
end

-- Defines a custom effect templated on an existing one and a spell record
-- carrying it (plus any extra ordinary effects), unless already present.
local function defineEffectSpell(spec)
    if effectRecord(spec.effectId) ~= nil then
        return
    end
    local template = nil
    for _, templateId in ipairs(spec.templates) do
        template = effectRecord(templateId)
        if template ~= nil then break end
    end
    if template == nil then
        print(LOG_TAG .. " no template effect for " .. spec.effectId)
        return
    end
    local okDefine, err = pcall(function()
        content.magicEffects.records[spec.effectId] = {
            template = template,
            name = spec.name,
            baseCost = spec.baseCost,
            description = spec.description,
        }
        local effects = {
            {
                id = spec.effectId, range = content.RANGE.Self, area = 0,
                duration = spec.duration, magnitudeMin = 1, magnitudeMax = 1,
            },
        }
        for _, extra in ipairs(spec.extraEffects or {}) do
            effects[#effects + 1] = extra
        end
        content.spells.records[spec.spellId] = {
            name = spec.name,
            type = spec.spellType == "Power" and content.spells.TYPE.Power or content.spells.TYPE.Spell,
            cost = spec.cost,
            isAutocalc = false,
            starterSpellFlag = false,
            effects = effects,
        }
    end)
    if okDefine then
        print(LOG_TAG .. " defined effect and spell " .. spec.spellId)
    else
        print(LOG_TAG .. " could not define " .. spec.spellId .. ": " .. tostring(err))
    end
end

-- ---- Call of the Wild (Conjuration hidden perk) ------------------------------
-- The wolves come from the conjuration runtime: while this effect is active
-- on the player it holds Summon Wolf instances on them, as many as their
-- Conjuration allows. Templated on Summon Wolf where Bloodmoon provides it,
-- Summon Scamp otherwise, so the effect always has a school and an icon.
defineEffectSpell({
    effectId = "sps_callofthewild", spellId = "sps_callofthewild",
    templates = { "summonwolf", "summonscamp" },
    name = "Call of the Wild", baseCost = 20, cost = 30, duration = 60,
    description = "Calls a pack of wolves to the caster's side for the duration. "
        .. "The pack grows with the caster's Conjuration.",
})

-- ---- Mana Ward (Mysticism hidden perk) ----------------------------------------
-- The mysticism runtime pays incoming damage out of magicka while this holds.
defineEffectSpell({
    effectId = "sps_manaward", spellId = "sps_manaward",
    templates = { "spellabsorption" },
    name = "Mana Ward", baseCost = 15, cost = 15, duration = 30,
    description = "While active, damage the caster takes is paid from magicka first, "
        .. "two points of magicka for each point of damage, until the pool is empty.",
})

-- ---- Warcry (Axe hidden perk) -------------------------------------------------
-- A once-a-day power. The axe runtime sees the marker effect and has every
-- hostile within earshot demoralised; the Fortify Attack rides on the record.
defineEffectSpell({
    effectId = "sps_warcry", spellId = "sps_warcry", spellType = "Power",
    templates = { "demoralizehumanoid" },
    name = "Warcry", baseCost = 0, cost = 0, duration = 10,
    description = "A shout that shakes every enemy within earshot for the duration.",
    extraEffects = {
        {
            id = "fortifyattack", range = content.RANGE.Self, area = 0,
            duration = 10, magnitudeMin = 20, magnitudeMax = 20,
        },
    },
})
