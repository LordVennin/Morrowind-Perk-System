# SkillPerkSystem_BasePack

Bundled default perk content pack for SkillPerkSystem.

## What this pack contains

- Default Long Blade and Block perk modules under `scripts/SkillPerkSystem_BasePack/perks/`.
- Direct registration script at `scripts/SkillPerkSystem_BasePack/register.lua`.

## How it loads

1. Enable `content=SkillPerkSystem.omwscripts` (framework).
2. Enable `content=SkillPerkSystem_BasePack.omwscripts` (base pack).

`SkillPerkSystem_BasePack.omwscripts` explicitly loads:

```text
PLAYER:scripts/SkillPerkSystem_BasePack/register.lua
```

`register.lua` runs in PLAYER context and directly registers module content with `openmw.interfaces.SkillPerkSystem`, matching the `example_Mod` loading style.

## Authoring guidance for addon packs

Follow the same structure used here:

```text
<PackName>.omwscripts
scripts/<PackName>/
  register.lua
  perks/
    <skillId>/
      <module>.lua
```

No core file edits are required to add another pack.
