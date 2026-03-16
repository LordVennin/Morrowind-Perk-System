# Skill tree node files

Create one Lua file per skill ID (for example: `block.lua`, `longblade.lua`, `alchemy.lua`).

Each file should return a list of node tables:

```lua
return {
  {
    id = "my_perk_id",
    skill = "block",
    title = "Display Title",
    description = "Optional detail text.",
    x = 0,
    y = 0,
    requires = { "parent_node_id" },
  },
}
```

Notes:
- `id` should match a registered perk ID when you want the node to be purchasable.
- `x`/`y` are stored now and reserved for map-style panning/tree-canvas rendering.
- `requires` defines chain/branch relationships.
