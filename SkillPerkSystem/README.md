# SkillPerkSystem

SkillPerkSystem is an OpenMW perk framework with a global perk-point ledger and explicit content-pack registration.

## Install

Add this folder to an OpenMW `data=` path, then enable:

```ini
content=SkillPerkSystem.omwscripts
```

## Loading model (explicit only)

SkillPerkSystem now follows the same explicit loading style as `example_Mod`:

1. `SkillPerkSystem.omwscripts` loads the framework runtime.
2. Every perk pack provides its **own** `.omwscripts` file.
3. That `.omwscripts` file loads the pack bootstrap script.
4. The bootstrap waits for `interfaces.SkillPerkSystem`, then registers modules/perks/nodes/effects.

There is **no folder scanning**, **no inferred plugin discovery**, and **no manifest-based auto-loading**.

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
- `registerPerkModule(module, expectedSkill[, source])`
- `registerEffect(data[, source])`
- `registerPointSource(sourceId, handlers[, source])`
- `beginPackRegistration(packName)`
- `completePackRegistration(packName)`
- `getRegistrationSummary()`
- `getPerks()`
- `getPerkIDs()`
- `getPerkIDsForSkill(skillID)`
- `getTreeNode(nodeID)`
- `getTreeNodesForSkill(skillID)`

## Startup logging

Framework logs reflect actual runtime registrations only, for example:

- framework started in explicit content-pack registration mode
- registering pack SkillPerkSystem_BasePack
- registered pack SkillPerkSystem_BasePack modules=2 perks=11 nodes=11 effects=0
- startup registry summary: packs_registered=X modules=Y perks=Z nodes=W effects=V

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
  bootstrap.lua
  perks/
    <skillId>/
      <module>.lua
```

### `MyPack.omwscripts`

```text
PLAYER:scripts/MyPack/bootstrap.lua
```

### `scripts/MyPack/bootstrap.lua`

```lua
local interfaces = require("openmw.interfaces")

local PACK_NAME = "MyPack"
local registered = false

local MODULES = {
    { moduleName = "scripts.MyPack.perks.longblade.01_core", skillID = "longblade" },
}

local function tryRegister()
    if registered then
        return true
    end

    local api = interfaces.SkillPerkSystem
    if type(api) ~= "table" or type(api.registerPerkModule) ~= "function" then
        return false
    end

    api.assertCompatibleApiVersion(1)

    if type(api.beginPackRegistration) == "function" then
        api.beginPackRegistration(PACK_NAME)
    end

    for _, entry in ipairs(MODULES) do
        api.registerPerkModule(require(entry.moduleName), entry.skillID, entry.moduleName)
    end

    if type(api.completePackRegistration) == "function" then
        api.completePackRegistration(PACK_NAME)
    end

    registered = true
    return true
end

tryRegister()

return {
    engineHandlers = {
        onUpdate = function()
            tryRegister()
        end,
    },
}
```

### `scripts/MyPack/perks/longblade/01_core.lua`

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
            x = 0,
            y = 0,
            title = "Core Training",
            description = "Starter node.",
        },
    },
}
```

## Point sources

Register event-driven point sources with `registerPointSource(sourceId, handlers)`.

## Console commands

- `skillperks`
- `skillperks <skillId>`
- `lua skillperks`
- `lua skillperks <skillId>`
- `lua skillperksrespec`
