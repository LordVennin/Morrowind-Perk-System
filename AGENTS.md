# Repository Instructions

- Perk runtime state must be stored in OpenMW save storage through script `onSave`/`onLoad` data.
- NEVER use global Lua storage (`openmw.storage`) for any perk state, perk effects, perk runtime timers, perk bonuses, or perk ownership data.
