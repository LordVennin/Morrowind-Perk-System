# Repository Instructions

- Perk runtime state must be stored in OpenMW save storage through script `onSave`/`onLoad` data.
- NEVER use global Lua storage (`openmw.storage`) for any perk state, perk effects, perk runtime timers, perk bonuses, or perk ownership data.
- Each perk tree or runtime subsystem lives in its own module file under `SkillPerkSystem_BasePack/runtime/player/` and returns a subsystem table (`eventHandlers` / `engineHandlers`). `basepack_player.lua` only requires those modules in order and runs the handler-combining machinery; do not add perk logic to it.
- The order of the `__basepack_subsystems` require list defines engine-handler chain order. Preserve existing order when adding a tree; append new trees at the end unless a tree genuinely must run earlier.
- Lua allows at most 200 local variables per function, and a module's main chunk counts as a function. One module per tree keeps each tree inside its own budget, but a single large tree can still exhaust it.
- Do not add large groups of `local` declarations at module scope beyond what a tree needs. When a module approaches the limit, collapse related constants (perk ids, tuning values, save-state keys) into one table local — see the `K` table in `runtime/player/block.lua` — or split the module along perk-tree seams.
- After adding to a runtime module, verify headroom rather than assuming it: append throwaway `local` declarations before the module's final `return` and confirm the file still compiles.
- After adding or moving perk tree nodes, run `lua5.4 tools/treelint.lua` from the repository root. Node boxes render 178px wide on 140px rows; the linter fails on same-row centers closer than 200px and warns under 220px. Prefer 220px or more between same-row siblings.
- Register skill-use reactions with `interfaces.SkillProgression.addSkillUsedHandler(handler)` - one handler for every skill, registered with no skill argument, called as `handler(skillId, params)`. There is no per-skill registration function; passing a skill name matches nothing and fails silently.
- Spell casts do NOT raise the Combat `Hit` event; that event covers weapon hits only. Do not classify spell effects from `onHit`.
- A target script attached at runtime does not exist yet when the watcher pushes state to it immediately after `addScript`, so that push is lost and only the (empty) init data arrives. Have the target request its state from its own `onInit`/`onLoad` instead of relying on the push.
- `interfaces.*` are not resolved during a script's `onInit`. Retry registration later, and do not latch a one-shot "unavailable" log on the first attempt - that hides every subsequent retry and makes a timing problem look like a missing API.
- Do NOT register interface handlers at module load. `interfaces.*` is populated as scripts come up, and runtime modules are required early enough that an interface can still be absent, so a load-time registration silently does nothing. Register lazily from a handler that runs later (the poll, or a UI-mode change) and latch once it succeeds.
- Never pay a perk out as a fraction of a maximum pool (magicka, health, fatigue) in response to an action the player can repeat cheaply. The cheapest possible action then returns more than it costs and the pool refills on spam. Scale the payout off what the action actually consumed, with a fraction below 1, so repeating it can never profit.
- Run `lua5.4 tools/orderlint.lua` after any Lua change. Lua resolves an unknown name as a global, so calling a helper declared further down the file - or one deleted out from under its callers - compiles fine and fails at runtime with "attempt to call a nil value". This has shipped four times; the linter catches it.
- To change maximum health, magicka or fatigue, grant an Ability record carrying the matching Fortify effect rather than writing the dynamic stat's `modifier`. The engine drives those three from active effects, and abilities are the path it recognises. Skill and attribute modifiers are additive deltas the engine leaves alone, so `setModifier` is correct for those.
- After changing how perk grants (dynamic spell/power/ability records) are handed out, run `lua5.4 tools/granttest.lua`. Never treat a `false` from `spells:has()` as authoritative for a dynamically created record - the engine does not recognise those ids, and trusting the negative makes grant removal unreachable. Only a `true` is meaningful; otherwise enumerate the spell list.
- After touching `SkillPerkSystem/perkpage.lua`, run `lua5.4 tools/uitest.lua` from the repository root. `luac -p` only catches syntax; the smoke test drives the menu-open, per-frame, and close paths against mocked openmw modules and catches runtime failures such as a helper referencing a local declared later in the file (which compiles fine and resolves to a nil global in game).
- Cross-subsystem state belongs in `runtime/shared.lua`; shared animation plumbing belongs in `runtime/animation.lua`. Runtime modules register animation handlers there, and `basepack_player.lua` calls `install()` once every module is loaded — never install animation handlers from inside a tree module, as that reintroduces a load-order dependency between trees.

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
