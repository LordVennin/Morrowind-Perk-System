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

-- ---- Call of the Wild (Conjuration hidden perk) ------------------------------
-- The wolves come from the conjuration runtime: while this effect is active
-- on the player it holds Summon Wolf instances on them, as many as their
-- Conjuration allows. Templated on Summon Wolf where Bloodmoon provides it,
-- Summon Scamp otherwise, so the effect always has a school and an icon.
local WILD_EFFECT = "sps_callofthewild"
local WILD_SPELL = "sps_callofthewild"

if effectRecord(WILD_EFFECT) == nil then
    local template = effectRecord("summonwolf") or effectRecord("summonscamp")
    if template ~= nil then
        local okDefine, err = pcall(function()
            content.magicEffects.records[WILD_EFFECT] = {
                template = template,
                name = "Call of the Wild",
                baseCost = 20,
                description = "Calls a pack of wolves to the caster's side for the duration. "
                    .. "The pack grows with the caster's Conjuration.",
            }
            content.spells.records[WILD_SPELL] = {
                name = "Call of the Wild",
                type = content.spells.TYPE.Spell,
                cost = 30,
                isAutocalc = false,
                starterSpellFlag = false,
                effects = {
                    {
                        id = WILD_EFFECT,
                        range = content.RANGE.Self,
                        area = 0,
                        duration = 60,
                        magnitudeMin = 1,
                        magnitudeMax = 1,
                    },
                },
            }
        end)
        if okDefine then
            print(LOG_TAG .. " defined effect and spell " .. WILD_SPELL)
        else
            print(LOG_TAG .. " could not define " .. WILD_SPELL .. ": " .. tostring(err))
        end
    else
        print(LOG_TAG .. " no summon effect to template Call of the Wild on")
    end
end
