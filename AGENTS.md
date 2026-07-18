# Repository Instructions

- Perk runtime state must be stored in OpenMW save storage through script `onSave`/`onLoad` data.
- NEVER use global Lua storage (`openmw.storage`) for any perk state, perk effects, perk runtime timers, perk bonuses, or perk ownership data.
- Large consolidated Lua player scripts must keep each perk tree or runtime subsystem inside its own immediately invoked local initializer function, for example `local function __basepack_initExampleTree() ... end` followed by `__basepack_initExampleTree()`.
- Do not add large groups of perk/runtime `local` declarations directly at file scope or inside top-level `do ... end` blocks in consolidated Lua scripts; Lua chunks have a 200-local-variable limit, and top-level `do` blocks still count toward the chunk's main function locals.
- When adding new perk trees to consolidated runtime scripts, prefer one initializer function per tree/subsystem so future additions do not push either the main chunk or an existing large initializer toward the 200-local limit.
