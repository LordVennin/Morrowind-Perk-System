# SkillPerkSystem

A new OpenMW perk framework where each skill grants its own perk points:

- 1 perk point at 25 in a skill
- 1 more at 50
- 1 more at 75
- 1 more at 100

Perk points are tracked per skill and cannot be spent on other skills.

## Install

Add this folder to your OpenMW `data=` paths and include:

```ini
content=SkillPerkSystem.omwscripts
```

## Console commands

- `lua skillperks` — prints the full skill perk menu to the console.
- `lua skillperks <skillId>` — prints one skill section.

## Registering perks from another mod

Register in a PLAYER script:

```lua
local interfaces = require("openmw.interfaces")

interfaces.SkillPerkSystem.registerPerk({
  id = "MyMod_longblade_power_attack",
  skill = "longblade",
  requirements = {},
  onAdd = function()
    -- apply perk effect
  end,
  onRemove = function()
    -- remove perk effect
  end,
})
```

## Notes

- Milestones are retroactive. If a save already has a skill above 25/50/75/100, points are granted on load.
- Earned milestones are not reduced when a skill temporarily drops.
