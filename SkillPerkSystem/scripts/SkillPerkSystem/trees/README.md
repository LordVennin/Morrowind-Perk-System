# Skill tree node files

Tree nodes are loaded per skill using folder modules.

For a skill such as `block`, create files under `trees/block/`:

- `modules.lua`: returns an ordered list of module filenames to load.
- each listed file (for example `nodes_core.lua`, `nodes_finishers.lua`) returns a list of node tables.

```lua
-- trees/block/modules.lua
return {
  "nodes_core",
  "nodes_finishers",
}
```

```lua
-- trees/block/nodes_core.lua
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
- Legacy flat modules (`trees/<skillId>.lua`) remain supported as a fallback.

Demo folders included:
- `block/`
- `longblade/`

Use Long Blade in-game to quickly validate the scaffolded tree/panning behavior.
