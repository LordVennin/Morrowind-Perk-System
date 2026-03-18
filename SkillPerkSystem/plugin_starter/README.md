# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a **self-contained addon pack** for SkillPerkSystem using the unified perks schema.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  YourPackName.omwscripts
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

Also copy `YourPackName.omwscripts`, rename it to your pack name, and keep only:

```text
PLAYER:scripts/<YourPackName>/skillperk_manifest.lua
```

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

## Install steps (author-facing)

1. Place your pack folder (`scripts/<YourPackName>/`) in an OpenMW data path.
2. Place your pack content file (`<YourPackName>.omwscripts`) in an OpenMW data path.
3. Enable your `.omwscripts` entry **after** the framework.
4. If your pack depends on base trees/content, enable it **after** the base pack too.

Recommended order:

1. `content=SkillPerkSystem.omwscripts` (framework)
2. `content=SkillPerkSystem_BasePack.omwscripts` (bundled base trees, optional/recommended)
3. `content=<YourPackName>.omwscripts` (your self-contained addon pack)

That order keeps framework initialization first so addon packs can register after the core runtime.

## Self-contained addon pack contract

Your pack should provide:

```text
<YourPackName>.omwscripts
scripts/<PackName>/
  skillperk_manifest.lua
  perks/
    <skillId>/
      <module>.lua
  effects/                  <-- optional
```

Expected manifest call pattern:

```lua
for _, moduleName in ipairs(PERK_MODULES) do
  api.registerPerkModule(require(moduleName), "<skillId>")
end
```

`api.registerPerkModule` is the supported registration path for modular, self-contained addon packs.

## Multiple packs targeting the same skill

Supported. Multiple addon packs can register perk modules for the same skill as long as perk IDs and effect IDs stay globally unique.
