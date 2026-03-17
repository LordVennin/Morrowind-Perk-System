# Built-in perk modules

Built-in perk definitions now use a folder-per-skill layout:

- `perks/longblade/*.lua`
- `perks/block/*.lua`

## Load order

Modules are loaded through `scripts/SkillPerkSystem/skillperk_manifest.lua`.
To keep behavior deterministic, module paths are sorted alphabetically before registration.

Recommended naming convention:

- `01_core.lua`
- `10_branch.lua`
- `20_capstone.lua`

Numeric filename prefixes make progression and load order obvious.

## Backward compatibility

The legacy flat module paths are still present:

- `scripts.SkillPerkSystem.perks.longblade`
- `scripts.SkillPerkSystem.perks.block`

They now return ordered lists of module paths and should be considered compatibility shims while migration completes.
