# Skill modules (perks + optional tree layout)

Preferred layout is one module per skill at `perks/<skillId>.lua`.

Each skill module can return:

- `perks = { ... }` (required for perk registration)
- optional `nodes = { ... }` (explicit tree node records), **or**
- embedded node fields directly on each perk (`x`, `y`, `title`, `description`, optional `node` table).

Example:

```lua
return {
  perks = {
    {
      id = "myperk_root",
      skill = "longblade",
      effectId = "my_effect",
      requires = {},
      cost = 1,
      x = 0,
      y = 0,
      title = "Root",
      description = "Starter perk and tree node in one place.",
    },
  },
}
```

## Backward compatibility during migration

Existing split perk modules under `perks/<skillId>/*.lua` are still discovered and loaded, but they do not auto-register tree nodes unless you adopt the new skill-module schema.
