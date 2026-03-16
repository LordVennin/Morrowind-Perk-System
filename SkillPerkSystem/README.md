# SkillPerkSystem

A new OpenMW perk framework where each skill grants its own perk points:

- 1 perk point at 25 in a skill
- 1 more at 50
- 1 more at 75
- 1 more at 100

Perk points are tracked per skill and cannot be spent on other skills.
Each perk may define a `cost` (default `1`) as a positive integer spent from that perk's skill pool when added and refunded when removed.

## Install

Add this folder to your OpenMW `data=` paths and include:

```ini
content=SkillPerkSystem.omwscripts
```

## Console commands

- `skillperks` — prints the full skill perk menu to the console (preferred direct form).
- `skillperks <skillId>` — prints one skill section (preferred direct form).
- `lua skillperks` — compatibility form that prints the full skill perk menu.
- `lua skillperks <skillId>` — compatibility form that prints one skill section.
- `lua skillperksrespec` — removes all active perks, resets spent points to 0 for every skill, and prints a per-skill refund summary.

OpenMW versions differ in Lua console context behavior; if `lua ...` prints context usage text, use the direct command forms above.

## UI hotkey

- Press `P` to toggle the perk UI by default.
- You can change this in `scripts/SkillPerkSystem/settings.lua` via `TOGGLE_UI_KEY` (single letter key names such as `"k"`, `"o"`, etc.).
- The perk UI uses three rows of skill tabs across the top and includes a boxed `Exit` button in the bottom-right corner.

## Registering perks from another mod

Register in a PLAYER script:

```lua
local interfaces = require("openmw.interfaces")

interfaces.SkillPerkSystem.registerPerk({
  id = "MyMod_longblade_power_attack",
  skill = "longblade",
  requirements = {},
  cost = 2, -- optional, defaults to 1
  onAdd = function()
    -- apply perk effect
  end,
  onRemove = function()
    -- remove perk effect
  end,
})
```

Registration validation note: `registerPerk` requires `skill` to match a valid `openmw.core.stats.Skill.records` ID and raises an error that includes both the perk ID and invalid skill ID when it does not. The optional `cost` field must be a positive integer.

## Notes

- Milestones are retroactive. If a save already has a skill above 25/50/75/100, points are granted on load.
- Earned milestones are not reduced when a skill temporarily drops.
- Save reconciliation runs on load: active perks missing from the currently registered perk list are dropped with a warning, spent points are recomputed from remaining perks, and per-skill spent points are clamped to earned points.
