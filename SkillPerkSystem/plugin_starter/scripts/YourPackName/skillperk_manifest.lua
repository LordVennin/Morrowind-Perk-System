-- Copy this folder as: scripts/<YourPackName>/
-- Keep this file path exactly: scripts/<YourPackName>/skillperk_manifest.lua
--
-- Recommended pack convention:
--   scripts/<PackName>/perks/<skillId>.lua (one file per skill)
--
-- Copy/paste and rename the module paths below.

local EFFECT_MODULES = {
    "scripts.YourPackName.effects.10_bonus_damage", -- optional
}

local PERK_MODULES = {
    "scripts.YourPackName.perks.longblade", -- one module per skill
}

local function extend(into, values)
    for _, value in ipairs(values) do
        table.insert(into, value)
    end
end

local function register(api)
    api.assertCompatibleApiVersion(1)

    for _, moduleName in ipairs(EFFECT_MODULES) do
        api.registerEffect(require(moduleName))
    end

    for _, moduleName in ipairs(PERK_MODULES) do
        local moduleData = require(moduleName)
        for _, perk in ipairs(moduleData.perks or {}) do
            api.registerPerk(perk)
            if type(perk.x) == "number" and type(perk.y) == "number" then
                api.registerTreeNode({
                    id = perk.id,
                    skill = perk.skill,
                    x = perk.x,
                    y = perk.y,
                    requires = perk.requires,
                    title = perk.title,
                    description = perk.description,
                })
            end
        end
    end
end

local modules = {}
extend(modules, EFFECT_MODULES)
extend(modules, PERK_MODULES)

return {
    register = register,
    modules = modules,
}
