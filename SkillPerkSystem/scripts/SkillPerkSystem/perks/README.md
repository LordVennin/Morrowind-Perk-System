# Unified perks schema

Canonical location: `scripts/<PackName>/perks/<skillId>/<file>.lua`.

Each module returns **one table that contains both perk behavior and tree layout metadata**:

```lua
return {
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

Pack manifests can call `api.registerPerkModule(require(moduleName), "longblade")` to register both perk and node data from the same module.
