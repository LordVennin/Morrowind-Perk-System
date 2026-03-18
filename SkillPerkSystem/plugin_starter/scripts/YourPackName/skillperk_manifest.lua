-- Copy this folder as: scripts/<YourPackName>/
-- Keep this file path exactly: scripts/<YourPackName>/skillperk_manifest.lua
--
-- Recommended self-contained addon pack convention:
--   scripts/<PackName>/perks/<skillId>/<file>.lua

local EFFECT_MODULES = {
    "scripts.YourPackName.effects.10_bonus_damage", -- optional
}

local PERK_MODULES = {
    "scripts.YourPackName.perks.longblade.01_core",
    "scripts.YourPackName.perks.longblade.10_bleed",
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
        api.registerPerkModule(require(moduleName), "longblade")
    end
end

local modules = {}
extend(modules, EFFECT_MODULES)
extend(modules, PERK_MODULES)

return {
    register = register,
    modules = modules,
}
