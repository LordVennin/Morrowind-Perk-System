-- Copy this folder as: scripts/<YourPackName>/
-- Keep this file path exactly: scripts/<YourPackName>/skillperk_manifest.lua

local PERK_MODULE = "scripts.YourPackName.perks.longblade"
local EFFECT_MODULE = "scripts.YourPackName.effects.example_bonus_damage"

local function register(api)
    api.assertCompatibleApiVersion(1)

    local effectDef = require(EFFECT_MODULE)
    api.registerEffect(effectDef)

    local perkDef = require(PERK_MODULE)
    api.registerPerk(perkDef)

    -- Optional for tree/map-style UIs.
    api.registerTreeNode({
        id = "yourpack_longblade_bonus_damage",
        skill = "longblade",
        x = 0,
        y = 0,
        requires = {},
        title = "Example: Long Blade Bonus Damage",
        description = "Starter node. Rename IDs/title/position for your mod.",
    })
end

return {
    register = register,
}
