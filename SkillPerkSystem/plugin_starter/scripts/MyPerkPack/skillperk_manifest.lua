-- This is the file that plugin_loader.lua auto-discovers.
-- Keep this path exactly: scripts/<PackName>/skillperk_manifest.lua

local EFFECT_MODULE = "scripts.MyPerkPack.effects.example_bonus_damage"
local PERK_MODULE = "scripts.MyPerkPack.perks.longblade"

local function register(api)
    api.assertCompatibleApiVersion(1)

    local effectDef = require(EFFECT_MODULE)
    api.registerEffect(effectDef)

    local perkDef = require(PERK_MODULE)
    api.registerPerk(perkDef)

    -- Optional: if you are using the tree-map style UI, register a node.
    api.registerTreeNode({
        id = "mypack_longblade_bonus_damage",
        skill = "longblade",
        x = 0,
        y = 0,
        requires = {},
        title = "Example: Long Blade Bonus Damage",
        description = "Starter node. Replace coordinates/title to fit your tree.",
    })
end

return {
    register = register,
}
