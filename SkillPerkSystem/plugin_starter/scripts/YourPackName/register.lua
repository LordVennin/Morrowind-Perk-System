local interfaces = require("openmw.interfaces")

local PERK_MODULES = {
    { moduleName = "scripts.YourPackName.perks.longblade.01_core" },
    { moduleName = "scripts.YourPackName.perks.longblade.10_bleed" },
}

local api = interfaces.SkillPerkSystem
if api == nil or type(api.registerPerk) ~= "function" or type(api.registerTreeNode) ~= "function" then
    error("[YourPackName] interfaces.SkillPerkSystem unavailable or missing required methods", 2)
end

api.assertCompatibleApiVersion(1)
for _, entry in ipairs(PERK_MODULES) do
    local moduleData = require(entry.moduleName)
    for _, perk in ipairs(moduleData.perks or {}) do
        api.registerPerk({
            id = perk.id,
            skill = perk.skill,
            effectId = perk.effectId,
            cost = perk.cost,
            requirements = perk.requirements or {},
        }, entry.moduleName)

        api.registerTreeNode({
            id = perk.id,
            skill = perk.skill,
            x = perk.x,
            y = perk.y,
            requires = perk.requires or {},
            title = perk.title,
            description = perk.description,
        }, entry.moduleName)
    end
end

return {}
