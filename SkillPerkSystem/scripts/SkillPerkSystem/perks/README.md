# Unified perks schema

Canonical location: `scripts/<PackName>/perks/<skillId>/<file>.lua`.

## Add-on pack contract

Pack layout:

```text
scripts/<PackName>/
  skillperk_manifest.lua
  perks/
    <skillId>/
      <module>.lua
  effects/                  <-- optional
```

Each module returns **one table that contains both perk behavior and tree layout metadata** and must include `schema = "skillperks.vNext"`:

```lua
return {
  schema = "skillperks.vNext",
  id = "myperk_root",
  skill = "longblade",
  effectId = "my_effect",
  requires = {},
  cost = 1,

  -- tree layout metadata in the same structure
  x = 0,
  y = 0,
  title = "Root",
  description = "Starter perk and tree node in one place.",
}
```

Optional explicit node object is also supported:

```lua
return {
  schema = "skillperks.vNext",
  id = "myperk_root",
  skill = "longblade",
  effectId = "my_effect",
  cost = 1,
  node = {
    x = 0,
    y = 0,
    title = "Root",
  },
}
```

Pack manifests call `api.registerPerkModule(require(moduleName), "<skillId>")` to register both perk and node data from the same module.

Duplicate registration policy is controlled by `ALLOW_DUPLICATE_REGISTRATION_OVERRIDE` in `scripts/SkillPerkSystem/settings.lua`:

- `false` (default): duplicate IDs are strict validation failures.
- `true`: duplicate IDs use last-write-wins override semantics.
