# SkillPerkSystem_BasePack

Bundled default perk content pack for SkillPerkSystem.

## What this pack contains

- Default Long Blade and Block perk modules under `scripts/SkillPerkSystem_BasePack/perks/`.
- Bootstrap script at `scripts/SkillPerkSystem_BasePack/bootstrap.lua`.

## How it loads

1. Enable `content=SkillPerkSystem.omwscripts` (core framework).
2. Enable `content=SkillPerkSystem_BasePack.omwscripts` (this pack).

`SkillPerkSystem_BasePack.omwscripts` loads the base-pack bootstrap directly (`PLAYER:scripts/SkillPerkSystem_BasePack/bootstrap.lua`), and that bootstrap explicitly registers the base perk modules through `openmw.interfaces.SkillPerkSystem`.

## Authoring guidance for addon packs

Follow the same structure used here:

```text
<PackName>.omwscripts
scripts/<PackName>/
  bootstrap.lua
  perks/
    <skillId>/
      <module>.lua
```

No core file edits are required to add another pack.
