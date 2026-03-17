# SkillPerkSystem

A new OpenMW perk framework with a global perk-point ledger and pluggable point sources.

Built-in point sources include:

- level-up rewards,
- skill milestone rewards (50/75/100 by default),
- quest completion rewards (event-driven).

Each perk may define a `cost` (default `1`) as a positive integer spent from the global pool when added and refunded when removed.

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
- The perk UI uses a compact skill selector across the top (with previous/next controls) and includes a boxed `Exit` button in the bottom-right corner.

### UI settings

Perk UI pane layout can be tuned in `scripts/SkillPerkSystem/settings.lua`:

- `PERK_UI_LEFT_PANE_WIDTH` (default `540`)
- `PERK_UI_RIGHT_PANE_WIDTH` (default `408`)
- `PERK_UI_SIDE_PADDING` (default `8`)
- `PERK_UI_GUTTER_WIDTH` (default `16`)

These values are used together to compute the total UI row width internally, keeping left/right pane sizing, spacing, and bottom-row `Exit` alignment consistent.

## Point source API

Use `registerPointSource(sourceId, handlers)` to define custom, event-driven reward sources.

```lua
interfaces.SkillPerkSystem.registerPointSource("MyModBossKills", {
  onBossKilled = function(data)
    -- integrate with your own event and add points via the player interface
  end,
})
```

Built-in sources are registered by the player script and use one-time claim IDs persisted in save data.

### Quest completion integration point

Send this event from your quest system to trigger the built-in quest source:

```lua
self:sendEvent("SkillPerkSystemquestCompleted", {
  questId = "my_unique_quest_id",
  points = 2, -- optional; falls back to settings quest default
})
```

Each `questId` is rewarded once per save.

### Configuring built-in sources

Edit `scripts/SkillPerkSystem/settings.lua` under `POINT_SOURCES`:

- `levelUpRewards.enabled`, `pointsPerLevel`, `firstRewardLevel`
- `skillMilestoneRewards.enabled`, `rewardsBySkillLevel`
- `questCompletionRewards.enabled`, `defaultPoints`

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


## Plugin validation report

At startup, plugin discovery now emits a compact validator summary:

```
[SkillPerkSystem] plugin validation summary: packs=<detected> registered=<success> with_errors=<failures>
[SkillPerkSystem] plugin error: pack='<PackName>' module='<module.path>' reason='<first error>'
```

- `packs` counts all detected content-file name variants scanned for plugins.
- `registered` counts packs with no module/manifest errors during discovery.
- `with_errors` counts packs with at least one manifest or module failure.
- For each failing pack, the first error line includes the failing source module path for quick triage.

### Verbose diagnostics (optional)

Set `PLUGIN_VALIDATION_VERBOSE = true` in `scripts/SkillPerkSystem/settings.lua` to print per-pack details and every captured failure, including a simple error class (`validation` vs `runtime`).

### Troubleshooting tips

- Errors prefixed with `VALIDATION_ERROR:` indicate plugin API contract issues (missing/invalid fields, duplicate IDs under strict mode, incompatible API declaration).
- Runtime errors usually indicate require path issues, script syntax errors, or exceptions inside plugin code.
- If `manifest_found=false` in verbose output, verify your pack exposes `scripts/<PackName>/skillperk_manifest.lua` and that content file naming matches your scripts folder.
- Keep module names in `skillperk_manifest.modules` fully-qualified Lua require paths.

## Create your own plugin

Use the starter pack at [`plugin_starter/`](plugin_starter/README.md).

It includes:

- a ready-to-copy `scripts/YourPackName/skillperk_manifest.lua` scaffold,
- optional `scripts/YourPackName/perks/` and `scripts/YourPackName/effects/` folders,
- an example `register(api)` flow (`assertCompatibleApiVersion`, `registerPerk`, optional `registerTreeNode`),
- OpenMW install + activation checklist.

## Notes

- Built-in rewards are retroactive because sources are evaluated on load and tracked with one-time claims in save data.
- Claimed milestone/quest rewards are persistent and are not granted twice.
- Save reconciliation runs on load: active perks missing from the currently registered perk list are dropped with a warning, and spent totals are recomputed from remaining perks.

## Reference-only folders (policy)

For **SkillPerkSystem feature work**, the following folders are reference-only and must not be edited as part of implementation:

- `example_Mod/`
- `Advanced world map mod example/`

Required work location:

- All active feature implementation, refactors, and bug fixes for SkillPerkSystem must be made under `SkillPerkSystem/`.

PR/task confirmation requirement:

- Every SkillPerkSystem PR or task handoff must explicitly confirm that no files were added, edited, or removed under either reference-only folder above.
- Use `SkillPerkSystem/TASK_TEMPLATE.md` for planning/new tasks so this policy is inherited by default.

## Experimental tree layout data (modder-facing)

The framework now includes an experimental, data-driven tree-node registry for future map-style perk UIs.

- Put per-skill node files in `scripts/SkillPerkSystem/trees/<skillId>.lua`
- See `scripts/SkillPerkSystem/trees/README.md` for schema
- Example included: `scripts/SkillPerkSystem/trees/block.lua`

Node files support `id`, `skill`, `x`, `y`, and `requires` so chains/branches can be authored in script files without editing core UI code.

### Demo tree content toggle

`settings.lua` now includes `ENABLE_DEMO_TREE_PERKS` (default `true`) which registers no-effect Long Blade demo perks used for testing the tree UI.

Set it to `false` to disable demo perk registration.
