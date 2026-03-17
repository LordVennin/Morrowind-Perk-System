# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a new SkillPerkSystem plugin using the recommended **one-skill-file** layout.

For advanced/large packs, folder-split skill modules are also supported, but one-file-per-skill should remain your default.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  scripts/
    YourPackName/
      skillperk_manifest.lua
      perks/
        longblade.lua           <-- one file for all longblade perks
      effects/                  <-- optional
        10_bonus_damage.lua
      trees/                    <-- optional
        longblade/
          10_starter.lua
```

Copy `scripts/YourPackName/` into your mod, then rename `YourPackName` and all sample IDs.

## Copy/paste manifest pattern

```lua
local PERK_MODULES = {
  "scripts.YourPackName.perks.longblade",
  "scripts.YourPackName.perks.block",
}

for _, moduleName in ipairs(PERK_MODULES) do
  local moduleData = require(moduleName)
  for _, perk in ipairs(moduleData.perks or {}) do
    api.registerPerk(perk)
  end
end
```

Each skill module should return one table with a `perks` list.

## Copy/paste one-skill-file pattern

```lua
-- scripts/YourPackName/perks/longblade.lua
return {
  perks = {
    {
      id = "yourpack_longblade_core_training",
      skill = "longblade",
      effectId = "yourpack_bonus_damage",
      requirements = {},
      cost = 1,
      x = 0,
      y = 0,
      title = "Core Training",
      description = "Starter tree node example co-located with perk data.",
    },
    {
      id = "yourpack_longblade_bleed_strikes",
      skill = "longblade",
      effectId = "yourpack_bonus_damage",
      requires = { "yourpack_longblade_core_training" },
      cost = 1,
      x = 120,
      y = 120,
      title = "Bleed Strikes",
      description = "Branch example with node fields embedded directly in perk.",
    },
  },
}
```

## Minimal install + activation checklist (OpenMW)

1. Copy your finished plugin scripts so the manifest is at `scripts/<PackName>/skillperk_manifest.lua`.
2. Install/enable `SkillPerkSystem` in OpenMW.
3. Add and enable your plugin content file in `openmw.cfg` (Launcher can do this).
4. Launch the game and check logs for successful load lines from plugin loader.
