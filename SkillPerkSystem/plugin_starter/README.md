# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a **self-contained addon pack** for SkillPerkSystem using the unified perks schema.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  YourPackName.omwscripts
  scripts/
    YourPackName/
      bootstrap.lua
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
PLAYER:scripts/<YourPackName>/bootstrap.lua
```

## Bootstrap + manifest pattern (official)

```lua
-- scripts/<YourPackName>/skillperk_manifest.lua
return { selfManaged = true }
```

`bootstrap.lua` explicitly registers perk modules through `openmw.interfaces.SkillPerkSystem.registerPerkModule(...)`.

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

Recommended order:

1. `content=SkillPerkSystem.omwscripts` (framework)
2. `content=<YourPackName>.omwscripts` (your self-contained addon pack)

That order keeps framework initialization first so addon packs can register after the core runtime.

## Self-contained addon pack contract

Your pack should provide:

```text
<YourPackName>.omwscripts
scripts/<PackName>/
  bootstrap.lua
  skillperk_manifest.lua
  perks/
    <skillId>/
      <module>.lua
  effects/                  <-- optional
```

Expected loader behavior:

- Keep `skillperk_manifest.lua` present so the pack is detected.
- Place perk modules under `perks/<skillId>/` and the framework registers them automatically.
- `manifest.register(api)` remains available for legacy/manual registration packs.

## Multiple packs targeting the same skill

Supported. Multiple addon packs can register perk modules for the same skill as long as perk IDs and effect IDs stay globally unique.
