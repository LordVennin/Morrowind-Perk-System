-- Copy this folder as: scripts/<YourPackName>/
-- Keep this file path exactly: scripts/<YourPackName>/skillperk_manifest.lua
--
-- Official vNext pattern:
--   - Keep this manifest file present so the pack is detected.
--   - Put perk modules under scripts/<PackName>/perks/<skillId>/<file>.lua.
--   - List those modules in `modules = { ... }` for sandbox-safe loading.

local function register(api)
    api.assertCompatibleApiVersion(1)
end

return {
    register = register,
    modules = {
        -- "scripts.YourPackName.perks.longblade.01_core",
        -- "scripts.YourPackName.perks.longblade.10_bleed",
    },
}
