local interfaces = require("openmw.interfaces")

local api = interfaces.SkillPerkSystem
if type(api) ~= "table" then
    local keys = {}
    for key, _ in pairs(interfaces) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    if #keys == 0 then
        print("[SkillPerkSystem_BasePack] visible interfaces snapshot: <none>")
    else
        print("[SkillPerkSystem_BasePack] visible interfaces snapshot: " .. table.concat(keys, ", "))
    end
    error("[SkillPerkSystem_BasePack] interfaces.SkillPerkSystem unavailable", 2)
end

api.assertCompatibleApiVersion(1)

local modules = {
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.block.block",
        data = require("scripts.SkillPerkSystem_BasePack.perks.block.block"),
    },
    {
        source = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
        data = require("scripts.SkillPerkSystem_BasePack.perks.longblade.longblade"),
    },
}

for _, entry in ipairs(modules) do
    for _, perk in ipairs(entry.data.perks or {}) do
        api.registerPerk({
            id = perk.id,
            skill = perk.skill,
            effectId = perk.effectId,
            cost = perk.cost,
            requirements = perk.requirements or {},
        }, entry.source)

        api.registerTreeNode({
            id = perk.id,
            skill = perk.skill,
            x = perk.x,
            y = perk.y,
            requires = perk.requires or {},
            title = perk.title,
            description = perk.description,
        }, entry.source)
    end
end

return {}
