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

### Content files and load order

- `content=SkillPerkSystem.omwscripts` is the framework runtime (required).
- `content=SkillPerkSystem_BasePack.omwscripts` is the bundled default perk pack and should be enabled after the framework.
- External add-on packs each ship their own content file: `content=<PackName>.omwscripts`. Load these after the framework and after the base pack.
- The framework no longer auto-loads internal demo trees; official perk content now comes from content packs via `scripts/<PackName>/skillperk_manifest.lua`.

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



### Core vs content-pack boundary

- `SkillPerkSystem` (core framework) provides runtime systems, validation, registry state, and content-pack discovery/registration behavior.
- `SkillPerkSystem_BasePack` (bundled content pack) provides the default perk trees and follows the same content-pack contract as third-party addons.
- Addon packs should mirror the base-pack structure and must not require edits to core files or shared indexes.

### Migration note

- **Deprecated:** relying on `scripts/SkillPerkSystem/perks/internal_module_index.lua` for shipping bundled gameplay trees in core.
- **Official path:** ship perks in a pack folder with `scripts/<PackName>/skillperk_manifest.lua` and `scripts/<PackName>/perks/<skillId>/<module>.lua`, then enable `content=<PackName>.omwscripts`.

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

Use the starter pack at [`plugin_starter/`](plugin_starter/README.md). Recommended pack layout is **one folder per skill with drop-in modules**:

```text
scripts/<PackName>/
  skillperk_manifest.lua
  perks/
    <skillId>/
      <module>.lua             <-- independent drop-in modules merged into one registry
  effects/                     <-- optional
    <effectId>.lua
```

Concrete multi-file example for one skill tree:

```text
scripts/<PackName>/perks/block/VenninBlock.lua
scripts/<PackName>/perks/block/JohnsBlock.lua
```

All files listed in `skillperk_manifest.modules` are merged into that one skill's perk tree UI.

### Add-on pack contract

Every external pack should follow this contract:

```text
scripts/<PackName>/
  skillperk_manifest.lua                  <-- required
  perks/
    <skillId>/
      <module>.lua                        <-- required per module contribution
  effects/                                <-- optional
    <effectId>.lua
```

Manifest expectations:

- Keep `scripts/<PackName>/skillperk_manifest.lua` present so the pack is detectable.
- Put perk modules under `scripts/<PackName>/perks/<skillId>/<module>.lua`; they are discovered automatically and merged deterministically by filename.
- If your runtime/content setup does not expose the pack via loader discovery, register modules from `skillperk_manifest.lua` via `openmw.interfaces.SkillPerkSystem.registerPerkModule(...)` (see `plugin_starter` template).
- Load order matters: enable `SkillPerkSystem.omwscripts` first, then `SkillPerkSystem_BasePack.omwscripts`, then your add-on pack `.omwscripts`.

Concrete explicit-bootstrap addon example:

```text
MyPerkPack.omwscripts
scripts/MyPerkPack/bootstrap.lua
scripts/MyPerkPack/perks/longblade/01_core.lua
scripts/MyPerkPack/perks/longblade/10_bleed.lua
```

`MyPerkPack.omwscripts`:

```text
PLAYER:scripts/MyPerkPack/bootstrap.lua
```

`scripts/MyPerkPack/bootstrap.lua`:

```lua
local interfaces = require("openmw.interfaces")
local api = interfaces.SkillPerkSystem

if api ~= nil then
    api.assertCompatibleApiVersion(1)
    api.registerPerkModule(require("scripts.MyPerkPack.perks.longblade.01_core"), "longblade")
    api.registerPerkModule(require("scripts.MyPerkPack.perks.longblade.10_bleed"), "longblade")
end
```

### Loader behavior (strict by design)

Plugin discovery supports unified modules under the canonical path:

- `scripts.<PackName>.perks.<skillId>.<module>`

Strict rules:

- The module must return a table with `schema = "skillperks.vNext"`.
- The module must provide `perks` and/or `nodes`.
- Old flat-tree module data and pre-schema legacy formats are unsupported.
- Missing required schema is treated as a strict validation failure and surfaced prominently in startup output.

Deterministic merge order for modules in the same skill folder is alphabetical by `<module>` filename. Use numeric prefixes to control order, for example:

- `01_core.lua`
- `20_finishers.lua`
- `90_experimental.lua`

For readability in larger teams, author prefixes are also a good option (for example `vennin_core.lua`, `john_finishers.lua`) and can be combined with numeric ordering (for example `10_vennin_core.lua`, `20_john_finishers.lua`).

Node coordinate (`x`, `y`) overlap across files is allowed. The loader intentionally does not resolve layout collisions for you; pack authors are responsible for arranging nodes so the final merged tree is readable.

Minimal two-file contribution example (same `block` skill tree):

```lua
-- scripts/MyPack/perks/block/VenninBlock.lua
return {
  schema = "skillperks.vNext",
  nodes = {
    { id = "mypack_block_start", x = 0, y = 0, perkId = "mypack_block_guard" },
  },
  perks = {
    { id = "mypack_block_guard", skill = "block", effectId = "mypack_guard", requirements = {}, cost = 1 },
  },
}
```

```lua
-- scripts/MyPack/perks/block/JohnsBlock.lua
return {
  schema = "skillperks.vNext",
  nodes = {
    { id = "mypack_block_followup", x = 1, y = 0, perkId = "mypack_block_counter", requires = { "mypack_block_start" } },
  },
  perks = {
    { id = "mypack_block_counter", skill = "block", effectId = "mypack_counter", requirements = { "mypack_block_guard" }, cost = 1 },
  },
}
```

Both files contribute entries to the same merged `block` tree at runtime.

### Migration notes (required)

If your plugin still uses older layouts, migrate to `scripts/<PackName>/perks/<skillId>/<module>.lua` modules and add `schema = "skillperks.vNext"` at each module root.

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

### Copy/paste example (folder-based skill module)

Minimal manifest (detection only):

```lua
return {}
```

Single module file:

```lua
-- scripts/MyPack/perks/longblade/01_core.lua
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
- Register modules by placing them under `scripts/<PackName>/perks/<skillId>/`; loader discovery handles registration automatically.
- See `scripts/SkillPerkSystem/perks/README.md` for schema details.

### Bundled base pack layout (Long Blade + Block)

Bundled default trees now live in the standalone pack:

- `SkillPerkSystem_BasePack/scripts/SkillPerkSystem_BasePack/perks/longblade/longblade.lua`
- `SkillPerkSystem_BasePack/scripts/SkillPerkSystem_BasePack/perks/block/block.lua`

They are loaded by `SkillPerkSystem_BasePack/SkillPerkSystem_BasePack.omwscripts`, which points directly to `scripts/SkillPerkSystem_BasePack/bootstrap.lua`. That bootstrap explicitly registers the base modules with `openmw.interfaces.SkillPerkSystem`.

## Migration note (modular installation model)

- Core no longer relies on `scripts/SkillPerkSystem/perks/internal_module_index.lua` to ship default perk trees.
- Enable `content=SkillPerkSystem_BasePack.omwscripts` to get bundled defaults.
- External packs should ship `scripts/<PackName>/bootstrap.lua` plus `scripts/<PackName>/perks/<skillId>/<module>.lua`, keep `scripts/<PackName>/skillperk_manifest.lua` as loader metadata (`selfManaged = true`), and be enabled via their own `.omwscripts` file.
