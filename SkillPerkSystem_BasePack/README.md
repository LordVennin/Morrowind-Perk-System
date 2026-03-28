# SkillPerkSystem_BasePack

Bundled default perk content pack for SkillPerkSystem.

## What this pack contains

- Default Long Blade and Block perk modules under `scripts/SkillPerkSystem_BasePack/perks/`.
- Direct registration script at `scripts/SkillPerkSystem_BasePack/register.lua`.
- GLOBAL runtime bootstrap at `scripts/SkillPerkSystem_BasePack/global.lua` for non-consume item handlers.
- Additional security runtime handlers in `treasure_sense_runtime.lua` and `lucky_find_runtime.lua`.

## How it loads

1. Enable `content=SkillPerkSystem.omwscripts` (framework).
2. Enable `content=SkillPerkSystem_BasePack.omwscripts` (base pack).

`SkillPerkSystem_BasePack.omwscripts` explicitly loads:

```text
GLOBAL:scripts/SkillPerkSystem_BasePack/global.lua
PLAYER:scripts/SkillPerkSystem_BasePack/steady_hands_runtime.lua
PLAYER:scripts/SkillPerkSystem_BasePack/tumbler_sense_runtime.lua
PLAYER:scripts/SkillPerkSystem_BasePack/quick_pick_runtime.lua
GLOBAL:scripts/SkillPerkSystem_BasePack/treasure_sense_runtime.lua
GLOBAL:scripts/SkillPerkSystem_BasePack/lucky_find_runtime.lua
PLAYER:scripts/SkillPerkSystem_BasePack/register.lua
```

`global.lua` runs in GLOBAL context and initializes Steady Hands runtime item usage hooks.

`register.lua` runs in PLAYER context and directly calls `openmw.interfaces.SkillPerkSystem.registerPerk` / `registerTreeNode`, matching the `example_Mod` direct registration style. Effect state toggling remains authored in `perks/security/steady_hands_effect.lua` through `onAcquire`/`onRemove`.

Lucky Find expects a `Miscellaneous` record with ID `sps_lucky_coin` in enabled content files. The record should mirror `gold_001` mesh/icon/texture and use weight `0.01`.

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
