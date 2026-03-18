# SkillPerkSystem_BasePack

Bundled default perk content pack for SkillPerkSystem.

## What this pack contains

- Default Long Blade and Block perk modules under `scripts/SkillPerkSystem_BasePack/perks/`.
- Pack manifest at `scripts/SkillPerkSystem_BasePack/skillperk_manifest.lua`.

## How it loads

1. Enable `content=SkillPerkSystem.omwscripts` (core framework).
2. Enable `content=SkillPerkSystem_BasePack.omwscripts` (this pack).

The core framework discovers this pack by content file name and loads it through the same manifest/module flow used by third-party addon packs.

## Authoring guidance for addon packs

Follow the same structure used here:

```text
<PackName>.omwscripts
scripts/<PackName>/
  skillperk_manifest.lua
  perks/
    <skillId>/
      <module>.lua
```

No core file edits are required to add another pack.
