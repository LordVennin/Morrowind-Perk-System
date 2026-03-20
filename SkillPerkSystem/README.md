# SkillPerkSystem

SkillPerkSystem is an OpenMW perk framework with a global perk-point ledger and explicit content-pack registration.

## Install

Add this folder to an OpenMW `data=` path, then enable:

```ini
content=SkillPerkSystem.omwscripts
```

## Loading model (explicit only)

SkillPerkSystem intentionally mirrors `example_Mod`:

1. `SkillPerkSystem.omwscripts` explicitly loads framework scripts.
2. Every perk pack ships its own explicit `.omwscripts` file.
3. The pack `.omwscripts` loads a PLAYER registration script.
4. That PLAYER script directly registers perk/tree records through `interfaces.SkillPerkSystem`.

There is **no folder scanning**, **no inferred plugin discovery**, and **no manifest auto-loading**.

## Required load order

Enable content files in this order:

```ini
content=SkillPerkSystem.omwscripts
content=SkillPerkSystem_BasePack.omwscripts
content=<AnyOtherPack>.omwscripts
```

Framework must load first. Packs load after it.

## Runtime API (openmw.interfaces.SkillPerkSystem)

Core interface methods:

- `assertCompatibleApiVersion(expectedVersion)`
- `registerPerk(data[, source])`
- `registerTreeNode(data[, source])`
- `registerPerkModule(module, expectedTab[, source])`
- `registerEffect(data[, source])`
- `registerPointSource(sourceId, handlers[, source])`
- `getRegistrationSummary()`
- `getPerks()`
- `getPerkIDs()`
- `getPerkIDsForTab(tabID)`
- `getTabIDs()`
- `getTabLabel(tabID)`
- `getTreeNode(nodeID)`
- `getTreeNodesForTab(tabID)`

## Startup logging

Framework and pack logs are explicit about each stage:

- framework `.omwscripts` manifest loaded
- framework interface exposed
- pack register script executed
- pack found framework interface
- module registrations
- startup registry summary

Example successful startup pattern:

```text
[SkillPerkSystem] framework .omwscripts PLAYER manifest loaded
[SkillPerkSystem][pack_registry] framework started in explicit content-pack registration mode
[SkillPerkSystem] startup registry summary: packs_registered=0 modules=0 perks=0 nodes=0 effects=1
[SkillPerkSystem] framework interface exposed as interfaces.SkillPerkSystem
[SkillPerkSystem_BasePack] register.lua executed
[SkillPerkSystem_BasePack] found interfaces.SkillPerkSystem
[SkillPerkSystem][pack_registry] registering pack SkillPerkSystem_BasePack
[SkillPerkSystem_BasePack] registered module block from scripts.SkillPerkSystem_BasePack.perks.block.block
[SkillPerkSystem_BasePack] registered module longblade from scripts.SkillPerkSystem_BasePack.perks.longblade.longblade
[SkillPerkSystem][pack_registry] registered pack SkillPerkSystem_BasePack modules=2 perks=11 nodes=11 effects=0
[SkillPerkSystem_BasePack] pack registration complete
[SkillPerkSystem] runtime registry summary: packs_registered=1 modules=2 perks=11 nodes=11 effects=1
```

## Base pack

`SkillPerkSystem_BasePack` is the reference content pack.

When enabled after framework, it registers:

- `scripts.SkillPerkSystem_BasePack.perks.block.block`
- `scripts.SkillPerkSystem_BasePack.perks.longblade.longblade`

## Create your own pack

Minimal structure:

```text
MyPack.omwscripts
scripts/MyPack/
  register.lua
  perks/
    <tabName>/
      <module>.lua
```

### `MyPack.omwscripts`

```text
PLAYER:scripts/MyPack/register.lua
```

### `scripts/MyPack/register.lua`

```lua
local interfaces = require("openmw.interfaces")

local PACK_NAME = "MyPack"
local api = interfaces.SkillPerkSystem

if type(api) ~= "table" then
    error("[MyPack] interfaces.SkillPerkSystem unavailable", 2)
end

api.assertCompatibleApiVersion(1)

api.registerPerk({
    id = "mypack_longblade_core",
    tab = "Long Blade",
    effectId = "mypack_bonus_damage",
    cost = 1,
    requirements = {},
}, "scripts.MyPack.perks.longblade.01_core")

api.registerTreeNode({
    id = "mypack_longblade_core",
    tab = "Long Blade",
    x = 0,
    y = 0,
    requires = {},
    title = "Core Training",
    description = "Starter node.",
}, "scripts.MyPack.perks.longblade.01_core")
```

### Why this matches `example_Mod`

Like `ErnExamplePerkPack.omwscripts -> PLAYER:scripts/ErnExamplePerkPack/dummy.lua`, SkillPerkSystem packs now load via `.omwscripts -> PLAYER register script -> direct framework interface calls`.

## Point sources

Register event-driven point sources with `registerPointSource(sourceId, handlers)`.

## Console commands

- `skillperks`
- `skillperks <tabId>`
- `lua skillperks`
- `lua skillperks <tabId>`
- `lua skillperksrespec`
