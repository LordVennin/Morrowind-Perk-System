# SkillPerkSystem plugin starter

Use this template as the starting point for a mod that registers perks/effects/tree nodes into SkillPerkSystem.

## Required naming and paths

`plugin_loader.lua` auto-discovers plugin manifests using your enabled content file names, then tries to `require`:

- `scripts.<PackName>.skillperk_manifest`
- `scripts.<PackName>.perks.<skillId>` for every known skill record
- `scripts.<PackName>.effects.<effectId>` for every known magic effect record

That means your on-disk layout should be:

```text
scripts/
  <PackName>/
    skillperk_manifest.lua            <-- required (auto-discovered)
    perks/
      <skillId>.lua                   <-- optional auto-loaded modules
    effects/
      <effectId>.lua                  <-- optional auto-loaded modules
```

The included example uses `MyPerkPack`:

```text
scripts/
  MyPerkPack/
    skillperk_manifest.lua
    perks/longblade.lua
    effects/example_bonus_damage.lua
```

## What to edit first

1. Rename `MyPerkPack` to your real pack folder name.
2. In `skillperk_manifest.lua`, update module paths and IDs.
3. Keep `register(api)` and call:
   - `api.assertCompatibleApiVersion(1)`
   - `api.registerEffect(...)` (if your perk uses a custom effect)
   - `api.registerPerk(...)`
   - `api.registerTreeNode(...)` (optional)

## Unique IDs and source prefixes

Use a consistent prefix for every ID, e.g. `myguild_`:

- perk IDs: `myguild_longblade_bonus_damage`
- effect IDs: `myguild_example_bonus_damage`
- tree node IDs: `myguild_longblade_bonus_damage`

SkillPerkSystem tracks duplicate registrations and includes the source module path in errors. Keeping a unique prefix avoids collisions across mods.

## First-run copy/paste checklist

Paste this into your issue or testing notes:

- [ ] Content file is enabled in `openmw.cfg`.
- [ ] Manifest path exists: `scripts/<PackName>/skillperk_manifest.lua`.
- [ ] Manifest calls `api.assertCompatibleApiVersion(1)`.
- [ ] Perk `skill` is a valid OpenMW skill id (e.g. `longblade`, `block`, `sneak`, ...).
- [ ] Perk has a non-empty `effectId` and that effect is registered.
- [ ] All IDs use my unique prefix (`<YourPrefix>_...`).

Expected logs when loading is successful (examples):

- `[SkillPerkSystem][plugin_loader] loaded pack='<PackName>' module='scripts.<PackName>.skillperk_manifest'`
- `[SkillPerkSystem][plugin_loader] executed manifest register() for pack='<PackName>'`

Common mistakes:

- Wrong folder case/spelling (`scripts/mypack/...` vs `scripts/MyPack/...`).
- Manifest file is named `manifest.lua` instead of `skillperk_manifest.lua`.
- Invalid perk skill ID (fails validation in `registerPerk`).
- Reused ID from another mod (duplicate ID conflict).
- `api.assertCompatibleApiVersion(...)` set to a version not supported by this framework.
