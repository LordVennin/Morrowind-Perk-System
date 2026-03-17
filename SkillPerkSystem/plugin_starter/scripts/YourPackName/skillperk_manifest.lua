-- Copy this folder as: scripts/<YourPackName>/
-- Keep this file path exactly: scripts/<YourPackName>/skillperk_manifest.lua

local EFFECT_MODULES = {
    "scripts.YourPackName.effects.10_bonus_damage",
}

local PERK_MODULES = {
    "scripts.YourPackName.perks.longblade.01_core",
    "scripts.YourPackName.perks.longblade.10_bleed",
}

local TREE_MODULES = {
    "scripts.YourPackName.trees.longblade.10_starter",
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
        api.registerPerk(require(moduleName))
    end

    for _, moduleName in ipairs(TREE_MODULES) do
        api.registerTreeNode(require(moduleName))
    end
end

local modules = {}
extend(modules, EFFECT_MODULES)
extend(modules, PERK_MODULES)
extend(modules, TREE_MODULES)

return {
    register = register,
    modules = modules,
}
