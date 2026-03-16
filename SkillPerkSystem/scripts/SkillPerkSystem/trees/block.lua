-- Example moddable perk-tree layout for a single skill.
--
-- Fields:
--   id          : unique node/perk id
--   skill       : OpenMW skill id
--   title       : display name in tree
--   description : optional extra text for right-hand detail panel
--   x, y        : map coordinates for future panning/tree-canvas rendering
--   requires    : list of parent node ids (chain/branching dependencies)

return {
    {
        id = "block_basic_guard",
        skill = "block",
        title = "Basic Guard",
        description = "Foundational shield posture. Increases confidence while blocking.",
        x = 0,
        y = 0,
        requires = {},
    },
    {
        id = "block_reactive_guard",
        skill = "block",
        title = "Reactive Guard",
        description = "Faster reaction windows against incoming melee attacks.",
        x = -120,
        y = 120,
        requires = { "block_basic_guard" },
    },
    {
        id = "block_bulwark_stance",
        skill = "block",
        title = "Bulwark Stance",
        description = "A steady stance that favors sustained defense.",
        x = 120,
        y = 120,
        requires = { "block_basic_guard" },
    },
    {
        id = "block_iron_wall",
        skill = "block",
        title = "Iron Wall",
        description = "Late-chain defensive mastery that branches from both lines.",
        x = 0,
        y = 260,
        requires = { "block_reactive_guard", "block_bulwark_stance" },
    },
}
