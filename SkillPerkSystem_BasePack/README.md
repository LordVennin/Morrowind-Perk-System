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

`register.lua` runs in PLAYER context and directly calls `openmw.interfaces.SkillPerkSystem.registerPerk` / `registerTreeNode`, matching the `example_Mod` direct registration style.

Registration in `register.lua` is retry-safe within a single game session:

- A module-level `alreadyRegistered` sentinel skips all registration work if the script is started again after a successful run.
- `registerPerk`, `registerTreeNode`, and `registerEffect` calls are wrapped to ignore only strict duplicate errors where both `id` and `source` match exactly.
- Any other registration error (including duplicate IDs from different sources) is rethrown.

For addon packs, follow the same pattern: reruns should never create duplicate IDs, and duplicate suppression must only apply to identical (`id`, `source`) pairs.

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
