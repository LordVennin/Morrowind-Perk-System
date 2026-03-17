# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a new SkillPerkSystem plugin using the recommended folder-based layout.

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
      effects/
        10_bonus_damage.lua
      trees/                     <-- optional
        longblade/
          10_starter.lua
```

Copy `scripts/YourPackName/` into your mod, then rename `YourPackName` and all sample IDs.

## Manifest-first loading

`skillperk_manifest.lua` should be your source of truth for load order. Keep file names prefixed with sortable numbers so intent is obvious:

- `01_core.lua` for base perks
- `10_bleed.lua` for follow-up perks
- `20_finisher.lua` for later chain entries

The starter manifest demonstrates ordered module lists for effects, perks, and optional tree nodes.

## Recommended module conventions

- Perks: `scripts.<PackName>.perks.<skillId>.<module>`
- Effects: `scripts.<PackName>.effects.<module>`
- Trees (optional): `scripts.<PackName>.trees.<skillId>.<module>`

## Migration from old flat layout

If your pack currently uses flat modules like `scripts.<PackName>.perks.longblade`:

1. Move it to `scripts/<PackName>/perks/longblade/01_core.lua` (or similar).
2. Split large files into focused modules (`10_bleed.lua`, `20_crit.lua`, etc.).
3. Update `skillperk_manifest.lua` to require the new paths in order.
4. Keep perk/effect IDs unchanged unless you intentionally want a breaking save migration.

## Minimal install + activation checklist (OpenMW)

1. Copy your finished plugin scripts so the manifest is at `scripts/<PackName>/skillperk_manifest.lua`.
2. Install/enable `SkillPerkSystem` in OpenMW.
3. Add and enable your plugin content file in `openmw.cfg` (Launcher can do this).
4. Launch the game and check logs for successful load lines from plugin loader.
