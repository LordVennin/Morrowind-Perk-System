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
[SkillPerkSystem] plugin validation summary: packs=<detected> loaded=<success> failed_or_skipped=<failures> strict_validation_failures=<validation errors>
[SkillPerkSystem] !!! STRICT SCHEMA VALIDATION FAILURES DETECTED !!!
[SkillPerkSystem] STRICT validation failure: pack='<PackName>' module='<module.path>' reason='<validation detail>'
```

- `packs` counts all detected content-file name variants scanned for plugins.
- `loaded` counts packs with no module/manifest errors during discovery.
- `failed_or_skipped` counts packs with at least one manifest/module failure or missing manifest.
- For each failing pack, the first error line includes the failing source module path for quick triage.

### Verbose diagnostics (optional)

Set `PLUGIN_VALIDATION_VERBOSE = true` in `scripts/SkillPerkSystem/settings.lua` to print per-pack details and every captured failure, including a simple error class (`validation` vs `runtime`).

### Troubleshooting tips

- Errors prefixed with `VALIDATION_ERROR:` indicate plugin API contract issues. Missing `schema = "skillperks.vNext"` in perk modules is now a hard failure by design.
- Runtime errors usually indicate require path issues, script syntax errors, or exceptions inside plugin code.
- If `manifest_found=false` in verbose output, verify your pack exposes `scripts/<PackName>/skillperk_manifest.lua` and that content file naming matches your scripts folder.
- Keep module names in `skillperk_manifest.modules` fully-qualified Lua require paths.

## Create your own plugin

Use the starter pack at [`plugin_starter/`](plugin_starter/README.md). Recommended pack layout is **one file per skill** (default for new modders):

```text
scripts/<PackName>/
  skillperk_manifest.lua
  perks/
    <skillId>.lua              <-- primary convention (single file per skill)
  effects/                     <-- optional
    <effectId>.lua
```

### Loader behavior (strict by design)

Plugin discovery now supports **only** one skill module path per skill:

- `scripts.<PackName>.perks.<skillId>`

Strict rules:

- The module must return a table with `schema = "skillperks.vNext"`.
- The module must provide `perks` and/or `nodes`.
- Old flat-tree module data, old split module-set patterns (`modules.lua` + numbered files), and legacy nested module discovery are unsupported.
- Missing required schema is treated as a strict validation failure and surfaced prominently in startup output.

### Migration notes (required)

If your plugin still uses older layouts, migrate to one module per skill (`scripts/<PackName>/perks/<skillId>.lua`) and add `schema = "skillperks.vNext"` at the module root.

Example:

```lua
return {
  schema = "skillperks.vNext",
  perks = {
    {
      id = "mypack_longblade_core",
      skill = "longblade",
      effectId = "mypack_bonus_damage",
      requires = {},
      cost = 1,
    },
  },
}
```

### Deterministic merge behavior across packs (same skill)

Multiple packs can define perks for the same `skill` ID. Merging is deterministic by registration order and perk ID policy:

1. Packs are discovered from enabled content files.
2. Skill modules are loaded per pack.
3. Perks are merged into the shared registry by unique perk ID.

Uniqueness policy is controlled by `ALLOW_DUPLICATE_REGISTRATION_OVERRIDE` in `scripts/SkillPerkSystem/settings.lua`:

- `false` (default): duplicate perk IDs are validation errors (`strict(error)`).
- `true`: duplicate IDs are allowed with `override(last-write-wins)` behavior.

Recommended practice: keep perk IDs globally unique (for example `<pack>_<skill>_<name>`) to avoid accidental overrides.

### Copy/paste examples (one-skill-file packs)

Manifest module list:

```lua
local PERK_MODULES = {
  "scripts.MyPack.perks.longblade",
  "scripts.MyPack.perks.block",
}

for _, moduleName in ipairs(PERK_MODULES) do
  local moduleData = require(moduleName)
  for _, perk in ipairs(moduleData.perks or {}) do
    api.registerPerk(perk)
  end
end
```

Single skill file:

```lua
-- scripts/MyPack/perks/longblade.lua
return {
  schema = "skillperks.vNext",
  perks = {
    {
      id = "mypack_longblade_core",
      skill = "longblade",
      effectId = "mypack_bonus_damage",
      requirements = {},
      cost = 1,
    },
    {
      id = "mypack_longblade_bleed",
      skill = "longblade",
      effectId = "mypack_bonus_damage",
      requires = { "mypack_longblade_core" },
      cost = 1,
    },
  },
}
```

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

## Unified perks schema (modder-facing)

The framework uses a perks-only schema where each perk module can include both perk behavior and tree layout metadata.

- Canonical module location: `scripts/<PackName>/perks/<skillId>/<file>.lua`
- Module contract: return one table with perk fields (`id`, `skill`, `effectId`, `cost`, `requires`/`requirements`) plus node fields (`x`, `y`, `title`, `description`) or a nested `node` table.
- Register modules with `api.registerPerkModule(require(moduleName), "<skillId>")`.
- See `scripts/SkillPerkSystem/perks/README.md` for schema details.

### Built-in content layout (Long Blade + Block)

Shipped built-in content is organized under `scripts/SkillPerkSystem/perks/` and registered from unified perk modules.

### Demo tree content toggle

`settings.lua` now includes `ENABLE_DEMO_TREE_PERKS` (default `true`) which registers no-effect built-in demo perks (currently Long Blade + Block) through `scripts/SkillPerkSystem/skillperk_manifest.lua`.

Built-in perk modules are organized under `scripts/SkillPerkSystem/perks/<skillId>/` and loaded in deterministic alphabetical order (`01_core.lua`, `10_branch.lua`, ...). Set the toggle to `false` to disable demo perk registration.
