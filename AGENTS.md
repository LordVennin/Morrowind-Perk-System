# Repository Instructions

- Perk runtime state must be stored in OpenMW save storage through script `onSave`/`onLoad` data.
- NEVER use global Lua storage (`openmw.storage`) for any perk state, perk effects, perk runtime timers, perk bonuses, or perk ownership data.
- Large consolidated Lua player scripts must keep each perk tree or runtime subsystem inside its own immediately invoked local initializer function, for example `local function __basepack_initExampleTree() ... end` followed by `__basepack_initExampleTree()`.
- Do not add large groups of perk/runtime `local` declarations directly at file scope or inside top-level `do ... end` blocks in consolidated Lua scripts; Lua chunks have a 200-local-variable limit, and top-level `do` blocks still count toward the chunk's main function locals.
- When adding new perk trees to consolidated runtime scripts, prefer one initializer function per tree/subsystem so future additions do not push either the main chunk or an existing large initializer toward the 200-local limit.

## Runtime Performance and Operation Budget

Performance is a correctness requirement. A perk is not complete if enabling it causes hundreds or thousands of unnecessary Lua operations per second while its state is idle or unchanged.

### Prefer events over frame polling

- Do not use `onUpdate` as the default way to detect attacks, spell casts, hits, perk changes, UI changes, or other discrete actions.
- Prefer existing player-side animation, combat, spell-cast, perk-state, UI-mode, load, and explicit custom events.
- Do not activate the shared actor-target watcher for behavior that can be detected from the player script.
- Do not scan `world.activeActors` or attach a local script to every active actor merely to determine whether the player attacked, cast a spell, entered combat, or changed equipment.
- Actor-target scripts are appropriate only when the effect genuinely requires target-local hit processing or target-local state that cannot be obtained from an existing player/global event path.

### Gate every update loop

- Every subsystem with an `onUpdate` handler must also provide a meaningful `shouldUpdate(dt)` gate unless the engine API does not support it.
- `shouldUpdate` must return `false` whenever no timer, stack, regeneration effect, damage-over-time effect, or other continuously changing state requires work.
- A persistent modifier being nonzero is NOT by itself a reason to update every frame. Static bonuses such as Feather, Speed, Strength, Armor Rating, or skill fortification should remain applied without keeping the subsystem continuously active.
- Do not write conditions such as `state.appliedBonus ~= 0` in the permanent fast-path of `shouldUpdate` unless that value genuinely requires frame-by-frame maintenance.
- Separate continuously changing effects from static equipment/perk checks. Timed effects may update continuously while active; static equipment effects should use events or a slow poll.

### Throttle unavoidable polling

- When no reliable event exists, poll at the slowest cadence that still feels responsive.
- Equipment, race, perk ownership, and passive-condition checks should normally run no more often than every `0.5` seconds unless there is a documented gameplay reason for a faster cadence.
- AI/combat-state fallback checks should normally run no more often than every `0.25` seconds and only while the relevant perk can currently activate.
- Do not call `Actor.getEquipment`, armor/weapon record lookups, race lookups, active-effect queries, AI target queries, or perk-interface checks every frame for a passive perk.
- Cache stable results where practical and invalidate or refresh them when a relevant event occurs.
- Perk acquisition/refund, load, and relevant UI/equipment transitions should force one immediate refresh rather than enabling permanent frame polling.

### Keep actor-target scripts idle

- Enabling a perk must not cause the consolidated actor-target script to run `onUpdate` on every nearby actor unless the perk truly needs continuous per-target processing.
- Event-only target behavior must not keep a target script's combined update loop active.
- `hasActiveState()` must reflect only real target-local work. It must become false as soon as the target has no active timed state, stacks, pending effects, or required watcher behavior.
- Target scripts must request removal when all target-local subsystems are idle.
- Before adding a new target-watcher provider, verify that it cannot be implemented through an existing player animation handler, player combat handler, spell event, or global event.

### Structure update code by cadence

- Keep frame-sensitive work in a small, explicitly active path.
- Keep periodic equipment/perk reconciliation behind a timer, for example:

```lua
shouldUpdate = function(dt)
    if timedEffectIsActive() then
        return true
    end

    state.pollTimer = state.pollTimer + (tonumber(dt) or 0)
    return state.pollTimer >= 0.5
end
```

- Reset the periodic timer only after the periodic reconciliation actually runs.
- Avoid incrementing the same timer in both `shouldUpdate` and `onUpdate` for the same frame.
- Do not run the entire perk-tree refresh function every frame merely because one timed effect is active. Split cheap timed-effect processing from slower equipment and perk reconciliation when necessary.

### Required performance review

Before considering a perk implementation complete:

- Compare OpenMW Lua profiler operations with the perk disabled and enabled while standing idle.
- Verify that a passive equipped effect does not add a persistent per-frame operation load.
- Verify that timed effects return to the idle operation level after expiring.
- Test in an area with multiple active actors when any target-side script is involved.
- Report the update mechanism and cadence in the implementation summary, such as event-driven, active-only per-frame, `0.25`-second polling, or `0.5`-second polling.
- Report any remaining in-engine performance behavior that could not be verified.

As a general acceptance rule, an idle passive perk should add only a small periodic cost. A change that adds several hundred operations per second while nothing is changing must be redesigned rather than accepted as good enough.
