# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a new SkillPerkSystem plugin using the unified perks schema.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  scripts/
    YourPackName/
      skillperk_manifest.lua
      perks/
        longblade/
          01_core.lua
          10_bleed.lua
      effects/                  <-- optional
        10_bonus_damage.lua
```

Copy `scripts/YourPackName/` into your mod, then rename `YourPackName` and sample IDs.

## Manifest registration pattern

```lua
local PERK_MODULES = {
  "scripts.YourPackName.perks.longblade.01_core",
  "scripts.YourPackName.perks.longblade.10_bleed",
}

for _, moduleName in ipairs(PERK_MODULES) do
  api.registerPerkModule(require(moduleName), "longblade")
end
```

## Unified perk module pattern

```lua
return {
  schema = "skillperks.vNext",
  perks = {
    {
      id = "yourpack_longblade_core_training",
  skill = "longblade",
  effectId = "yourpack_bonus_damage",
  requires = {},
  cost = 1,
  x = 0,
  y = 0,
  title = "Core Training",
  description = "Starter node data is co-located with perk behavior.",
    },
  },
}
```
