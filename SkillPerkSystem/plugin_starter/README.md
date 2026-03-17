# SkillPerkSystem plugin starter pack

This folder is a ready-to-copy scaffold for creating a new SkillPerkSystem plugin.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  scripts/
    YourPackName/
      skillperk_manifest.lua        <-- required
      perks/                        <-- optional
        longblade.lua               <-- example module
      effects/                      <-- optional
        example_bonus_damage.lua    <-- example module
```

Copy `scripts/YourPackName/` into your mod, then rename `YourPackName` and all sample IDs.

## Module paths expected by `plugin_loader.lua`

`scripts/SkillPerkSystem/plugin_loader.lua` auto-discovers pack names from enabled content files and then attempts to `require(...)` these module paths:

- `scripts.<PackName>.skillperk_manifest` (required for manifest-based registration)
- `scripts.<PackName>.perks.<skillId>` (optional; attempted for every OpenMW skill ID)
- `scripts.<PackName>.effects.<effectId>` (optional; attempted for every OpenMW magic effect ID)

Practical implication: keep exact path/case for your pack folder and manifest file:

- `scripts/<PackName>/skillperk_manifest.lua`

## Example `register(api)` implementation

The included manifest demonstrates the typical registration flow:

1. `api.assertCompatibleApiVersion(1)`
2. `api.registerEffect(...)` (if needed)
3. `api.registerPerk(...)`
4. `api.registerTreeNode(...)` (optional)

Open `scripts/YourPackName/skillperk_manifest.lua` and replace module paths/IDs.

## Required perk fields validated in `plugin_api.lua`

When you call `api.registerPerk(data)`, `scripts/SkillPerkSystem/plugin_api.lua` validates:

- `data` must be a table.
- `id` is required and must be a string.
- `skill` is required, must be a string, and must match a valid OpenMW skill record ID.
- `effectId` is required and must be a non-empty string.
- `requirements` defaults to `{}` if omitted, and must be a table if provided.
- `cost` defaults to `1` if omitted, and must be a positive integer if provided.

## Naming and ID conventions (collision avoidance)

Use a mod-unique prefix for every identifier, such as `yourmod_` or `myguild_`.

- Perk IDs: `yourmod_longblade_bonus_damage`
- Effect IDs: `yourmod_bonus_damage_effect`
- Tree node IDs: `yourmod_longblade_bonus_damage_node`
- Point source IDs (if used): `yourmod_quest_rewards`

Recommendations:

- Keep IDs lowercase with underscores.
- Never reuse vanilla IDs.
- Keep pack folder, content filename, and ID prefix logically aligned.

## Minimal install + activation checklist (OpenMW)

1. Copy your finished plugin scripts so the manifest is at:
   - `scripts/<PackName>/skillperk_manifest.lua`
2. Install/enable `SkillPerkSystem` in OpenMW.
3. Add and enable your plugin content file in `openmw.cfg` (Launcher can do this).
4. Launch the game and check logs for successful load lines from plugin loader.
5. Use perk UI/console to confirm your perk appears and can be applied.

If registration fails, check:

- folder/name casing mismatches in `scripts/<PackName>/...`
- invalid `skill` ID in `registerPerk`
- missing/empty `effectId`
- duplicate IDs already used by another plugin
