# Skill tree node files

Create one Lua file per skill ID (for example: `block.lua`, `longblade.lua`, `alchemy.lua`).

Each file should return a list (array) of node tables:

```lua
return {
  {
    id = "mymod_block_anchor",
    skill = "block",
    title = "Display Title",
    description = "Optional detail text.",
    x = 0,
    y = 0,
    requires = { "parent_node_id" },
  },
}
```

## Runtime schema

Nodes are validated by `registerTreeNode`/`registerTreeNodes` in `tree_registry.lua`.

Required fields:

- `id` (`string`): globally unique node ID across *all* skills.
- `skill` (`string`): valid OpenMW skill ID (`openmw.core.stats.Skill.records[skill]` must exist).
- `x` (`number`): horizontal position on the tree canvas.
- `y` (`number`): vertical position on the tree canvas.

Optional fields:

- `requires` (`string[]`): parent node IDs; defaults to `{}`.
- `title` (`string`): UI label; defaults to `id`.
- `description` (`string`): optional detail text.

Validation rules:

- `id` collisions throw an error immediately.
- `requires` must be a list/array of strings.
- `x` and `y` must be numeric (integer coordinates are recommended for cleaner layouts).

## Coordinate conventions

The current UI does not yet render a full panning map, but coordinates are persisted and sorted (`y`, then `x`, then `id`) so authors can prepare future-ready layouts now.

Recommended authoring conventions:

- Treat `(0, 0)` as a skill's root/start node.
- Positive `y` moves downward (deeper tier/progression).
- Negative `x` = left branch, positive `x` = right branch.
- Use a consistent grid step (e.g. 80, 100, or 120 units) to keep trees readable.
- Keep enough spacing between sibling nodes so connector lines and labels stay legible.

## Chain / branch examples

Linear chain:

```lua
return {
  { id = "a", skill = "block", x = 0, y = 0, requires = {} },
  { id = "b", skill = "block", x = 0, y = 120, requires = { "a" } },
  { id = "c", skill = "block", x = 0, y = 240, requires = { "b" } },
}
```

Branching from one parent:

```lua
return {
  { id = "root",  skill = "block", x = 0,    y = 0,   requires = {} },
  { id = "left",  skill = "block", x = -120, y = 120, requires = { "root" } },
  { id = "right", skill = "block", x = 120,  y = 120, requires = { "root" } },
}
```

Multi-parent gate (all listed parents required):

```lua
return {
  { id = "root", skill = "block", x = 0, y = 0, requires = {} },
  { id = "l1",   skill = "block", x = -120, y = 120, requires = { "root" } },
  { id = "r1",   skill = "block", x = 120, y = 120, requires = { "root" } },
  { id = "cap",  skill = "block", x = 0, y = 260, requires = { "l1", "r1" } },
}
```

## Reserved fields (forward compatibility)

The following keys are reserved for future built-in behavior. Do not repurpose them for custom data:

- `icon`
- `tier`
- `hidden`
- `uiColor`

If you need mod-specific metadata today, put it in a namespaced field to avoid collisions (for example `mymod_tag`, `mymod_costHint`, etc.).

## Mod extension workflow

You can extend trees without patching this folder:

1. Register your perks through the `SkillPerkSystem` interface.
2. Register additional nodes from your own PLAYER script using `registerTreeNode` or `registerTreeNodes`.
3. For an existing skill, choose unique IDs and set `requires` to IDs from the base tree (or from your own nodes) to attach new branches.

See the top-level `SkillPerkSystem/README.md` for complete copy/paste examples.
