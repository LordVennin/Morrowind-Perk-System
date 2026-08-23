# Runtime Update/Frame Handler Audit

This audit inventories the always-running `engineHandlers.onUpdate` and `engineHandlers.onFrame` paths in the requested SkillPerkSystem Lua runtimes. It documents current purpose and optimization classification only; no gameplay behavior is changed.

Suggested verification command:

```sh
rg -n "onUpdate|onFrame" SkillPerkSystem SkillPerkSystem_BasePack
```

## Classification key

- **Required every update/frame**: tied directly to per-frame input, animation, or UI state.
- **Timer-based and reducible**: already throttled or naturally suited to coarser scheduling.
- **Only needed while an effect is active**: should not need to run when no runtime buff/debuff/state is active.
- **Equipment/perk-state polling that could be cached**: repeatedly recomputes inventory/equipment/perk state that could be invalidated by events or state changes.
- **UI-only**: exists only for menu/input cleanup or interaction.
- **Fallback/debug/safety behavior**: compensates for missed events, delayed registration, or cleanup guarantees.

## SkillPerkSystem/player.lua

| Location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| `registerBuiltInPointSources()` level-up point source | `pointsLedger.registerPointSource("level-up", { onUpdate = ... })` | Awards configured perk points for player levels from the first reward level through current level; deduplication happens through `awardFromSource`. | Timer-based and reducible; fallback/safety behavior. | It is invoked by the player script's 1-second update pulse and also by menu-close events. Could become level-up/rest/event driven if all leveling paths are covered. |
| `registerBuiltInPointSources()` skill milestone point source | `pointsLedger.registerPointSource("skill-milestones", { onUpdate = ... })` | Scans all registered skill IDs and awards configured milestone points when base skill reaches thresholds. | Equipment/perk-state style polling that could be cached; timer-based and reducible. | This is a broad skill-state poll. It could be replaced by skill-increase events or cached last-seen skill values. |
| Player engine handler | `engineHandlers.onUpdate = onUpdate` | Runs once per second, emits point-source `onUpdate`, and performs delayed save-state reconciliation after the perk registry becomes available. | Timer-based and reducible; fallback/debug/safety behavior. | The one-second throttle already reduces cost. The delayed registry reconcile should self-disable after success; the point-source polling is the longer-term optimization target. |

## SkillPerkSystem/perkpage.lua

| Location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| Perk UI engine handler | `engineHandlers.onFrame = onFrame` | Suppresses journal sounds during short windows, validates/cleans owned UI mode, polls global points while the menu is open, handles tree keyboard panning, refreshes the toggle key binding, and opens/closes the perk menu on key press. | UI-only; toggle-key edge detection required every frame; remaining work throttled or gated. | Optimized. Panning no longer rebuilds the layout: node positions are canvas-relative and the canvas container's `position` is offset in place (`applyTreePanOffset`). Toggle key binding refresh (settings storage read) runs on a `0.5`-second timer; the global point poll runs on a `0.25`-second timer; `getTreeNodesForTab` (which copies and sorts) and `hasOpenMenuMode` (which walks the mode stack) are only called when a pan key is held or on the toggle key edge respectively. `input.KEY` codes are resolved once instead of a pcall plus closure per key per frame. |

### Perk UI redraw cost

Before this pass, every tree interaction assigned `menu.layout = buildLayout()`, rebuilding the entire widget tree — window chrome, one `ui.texture` per header tile, the tab row, every tree node, every connector line segment, and the detail pane. That ran once per rendered frame while an arrow key was held and once per `mouseMove` event while dragging. Full rebuilds are now limited to discrete content changes: tab switch, node selection, perk purchase/refund, and an observed point-total change.

## SkillPerkSystem/manifest.lua

| Location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| Manifest engine handler | `engineHandlers.onUpdate = onUpdate` | Waits for runtime perk/tree registry population, validates merged graph once, and logs a runtime registry summary once. | Fallback/debug/safety behavior; only needed until initialization completes. | It already returns permanently after both one-time actions are complete. Could be replaced by explicit pack-registration completion if available. |

## SkillPerkSystem_BasePack/basepack_player.lua

`basepack_player.lua` combines every subsystem handler into a single player script engine-handler chain. As a result, each subsystem listed below contributes to the same player `onUpdate`/`onFrame` path.

| Subsystem / location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| Steady Hands / security tools | `onUpdate = onUpdate` | Tracks equipped lockpick/probe condition, logs debug frames, detects condition drops missed by tool-drain events, and rolls/refunds preserved uses. | Fallback/debug/safety behavior; equipment polling that could be cached; only needed while perk/effect or relevant tool is active. | Polls equipped security tool every update. Event handling already exists, so the fallback could be gated by perk enabled + tool equipped, or run at a lower cadence. |
| Tumbler Sense / security tools | `onUpdate = onUpdate` | Clears expired chance-bonus stacks, checks enabled state, tracks equipped security tool condition, and converts condition drops into failure events. | Only needed while effect/stacks are active; equipment polling that could be cached. | Stack expiry is time-based; condition fallback could be gated on enabled state and current security tool. |
| Fortune's Favor / luck from coin count | `onUpdate = refreshLuckBonus` | Refreshes applied luck bonus from carried coin count and enabled state. | Equipment/inventory/perk-state polling that could be cached. | Candidate for inventory/change-event invalidation or slower cadence; likely not necessary every update. |
| Burglar's Instinct | `onUpdate = refreshBurglarsInstinctAbility(false)` | Maintains/removes a player ability based on enabled state. | Equipment/perk-state polling that could be cached; only needed while effect state can change. | Could be driven by perk toggle/acquire/remove/load instead of always polling. |
| Aegis Rite / block momentum | anonymous `onUpdate(dt)` | Advances runtime time, prunes momentum stacks, applies block modifier, and updates Hallowed Guard ability. | Only needed while effect/stacks are active; equipment/perk-state polling that could be cached. | Stack pruning is timer/effect active; ability update could be event-driven by perk/equipment/state changes. |
| Long Blade | `onUpdate = onUpdate` | Advances runtime time, refreshes long blade fundamentals, updates long blade abilities, counts down Duelist's Tempo, and clears expired/ineligible agility bonus. | Equipment/perk-state polling that could be cached; only needed while tempo is active for countdown. | Fundamentals/ability refresh should be cacheable on equipment/perk changes. Tempo countdown only needs to run while active. |
| Axe/Fellstar player state publisher | anonymous `onUpdate(dt)` | Every `STATE_REFRESH_INTERVAL` second, refreshes Fellstar Crown feather and publishes axe-related state to global/targets. | Timer-based and reducible; equipment/perk-state polling that could be cached. | Already throttled to 1 second. Could publish only on state changes triggered by perk/equipment changes. |
| Marksman | `onUpdate = refreshBowFundamentalsAgilityBonus`; `onFrame = updateSteadyDraw(dt)` | Update keeps bow fundamentals agility bonus correct. Frame handler tracks held attack timing for Steady Draw. | `onUpdate`: equipment/perk-state polling that could be cached. `onFrame`: required every frame while attack-hold effect is possible; only needed while relevant perk/weapon state is active. | `onFrame` is more justified than the agility poll, but can still be gated by perk/equipped bow. |
| Blunt weapon player state/refunds | anonymous `onUpdate(dt)` | Processes Guarded Stamina refund timing, then every second publishes blunt state to global/targets. | Timer-based and reducible; only needed while refund is pending; equipment/perk-state polling that could be cached. | Split immediate refund timer from 1-second state publishing to allow gating. |
| Armorer masterwork repair use | `onFrame = tryPendingRepairUse()` | Attempts pending repair use work after activation/UI timing. | Fallback/safety behavior; only needed while pending repair use exists. | Can be gated behind a pending flag so the frame handler does no work when idle, or moved to an explicit delayed event if supported. |
| Careful Repairs | `onUpdate = onUpdate` | Snapshots repair tools, detects repair-tool condition drops, suppresses expected drops, and rolls/refunds preserved uses. | Equipment/inventory polling that could be cached; fallback/safety behavior; only needed while perk/effect active or suppression pending. | Polls repair tools every update. Candidate for event-driven repair result handling with a lower-frequency fallback. |
| Hand-to-hand player | anonymous `onUpdate(dt)` | Refreshes Centered Stance and Flowing Counter bonuses, updates Open Palm timer, and publishes hand-to-hand state every second. | High-cost equipment/perk-state polling that could be cached; only needed while effects are active; timer-based state publishing. | **High-cost candidate:** repeatedly checks glove/equipment/perk state on the player update path. Centered/Flowing refreshes could be invalidated by equipment/perk changes; Open Palm only needs active timer updates; state publish is already 1-second throttled. |
| Combined player engine chain | generated `__combinedEngineHandlers[handlerName]` | Builds a chain for every subsystem handler with the same engine event; for `onUpdate`, invokes gated subsystem contributions sequentially. For `onFrame`, inactive predicates are now sampled on a short interval and active frame handlers continue every frame until idle. | Required by current consolidation architecture; mitigated for idle frame costs. | This keeps frame-critical behavior responsive while preventing dormant frame predicates from being charged every rendered frame on the player script. |

## SkillPerkSystem_BasePack/basepack_global.lua

| Subsystem / location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| Axe target watcher | anonymous `onUpdate(dt)` | Every second scans `world.activeActors` and attaches the combined target script to actors that need axe/marksman target behavior. | Timer-based and reducible; fallback/safety behavior; high-cost active-actor scan. | **High-cost candidate:** scans all active actors. Could be driven by player state changes, combat/hit events, or narrower actor activation windows. |
| Hand-to-hand watcher | anonymous `onUpdate(dt)` | Every second scans `world.activeActors` and attaches the target script for hand-to-hand target damage modifiers. | Timer-based and reducible; high-cost active-actor scan. | **High-cost candidate:** explicitly called out because it scans `world.activeActors`; should be gated by hand-to-hand state being enabled and/or recent unarmed combat. |
| Blunt weapon watcher | anonymous `onUpdate(dt)` | Every second scans `world.activeActors` and attaches target script for blunt target effects/damage modifiers. | Timer-based and reducible; high-cost active-actor scan. | Could be gated by published blunt state indicating at least one target-side effect is enabled. |
| Duelist's Tempo watcher | anonymous `onUpdate(dt)` | Every second scans `world.activeActors` and attaches target script for Duelist's Tempo target state. | Timer-based and reducible; high-cost active-actor scan. | Could attach on hit/target selection or only while a tempo target state is active. |
| Combined global engine chain | `engineHandlers.onUpdate = function(dt) callEngineHandler("onUpdate", dt) end` | Dispatches global `onUpdate` to each global subsystem in `engineOrder`. | Required by current consolidation architecture; timer-based subsystem costs are aggregated here. | The dispatcher itself is small; the repeated active-actor watcher scans are the expensive work beneath it. |

## SkillPerkSystem_BasePack/basepack_actor_target.lua

The target script is attached to active actors by global watcher subsystems. Its combined `onUpdate` dispatch means every attached actor calls axe, blunt, Duelist's Tempo, Aegis Rite, and hand-to-hand target update handlers each update, even when most are idle.

| Subsystem / location | Handler | Current purpose | Classification | Notes / optimization candidate |
| --- | --- | --- | --- | --- |
| Axe target bleeds/pinning | anonymous `onUpdate(dt)` | Ticks Bloodletter, Hewer Heart, thrown/deadeye bleed stacks, blood spray timers, damage intervals, and Pinning Shot speed penalty cleanup. | Only needed while an effect is active; required at effect tick granularity while active. | Early-outs when all timers/stacks are inactive, but still runs for every actor with the target script. Strong candidate for removing target script when no target-side state remains. |
| Duelist's Tempo target penalty | anonymous `onUpdate(dt)` | Counts down remaining agility penalty time and clears penalty at expiry. | Only needed while an effect is active. | Can be inactive/removed when `remainingTime <= 0` and no penalty is applied. |
| Aegis Rite target prime | anonymous `onUpdate(dt)` | Counts down primed target duration and requests removal when it expires. | Only needed while effect is active. | Well-scoped timer; should not require a broad always-attached script after expiry. |
| Combined target update dispatch | `onUpdate = function(dt) callEngineHandler(...) ... end` | Dispatches update to axe, blunt, Duelist's Tempo, Aegis Rite, and hand-to-hand target modules on every actor carrying the combined target script. | Required by current target consolidation architecture; high-cost candidate. | **High-cost candidate:** attached active actors pay dispatch overhead for all target modules, including modules without an `onUpdate` or without active state. Consider reference-counted attachment, per-feature active flags, or removal when no module has live state. |

## PR4 gating follow-up checklist

These entries track the first conversion pass from unconditional polling to explicit gates. Future PRs should continue this table instead of re-auditing from scratch.

| Subsystem | PR4 action | Remaining follow-up |
| --- | --- | --- |
| Steady Hands / security tools | Added a `shouldUpdate` gate and short scan window so the fallback equipment condition comparison runs around toggles/tool-drain events and debug frames instead of unconditionally. | Prefer direct tool-drain events when reliable; keep fallback window narrow and only expand if condition-loss edge cases appear in game. |
| Tumbler Sense / security tools | Added a `shouldUpdate` gate and short scan window while preserving active stack expiry cleanup. | Replace fallback condition detection with direct security failure events wherever possible. |
| Block / Aegis Rite / Hallowed Guard | Added a `shouldUpdate` gate so momentum stacks run only while active and Hallowed Guard ability refreshes are throttled through a state refresh interval. | Move Hallowed Guard refresh to perk/equipment dirty-state events when a reliable equipment-change signal exists. |
| Long Blade | Added a `shouldUpdate` gate so Duelist's Tempo remains active while timed and static ability/fundamentals refreshes are throttled through a state refresh interval. | Move static Long Blade ability/fundamentals refresh to perk/equipment dirty-state events and keep update only for active Duelist's Tempo cleanup. |


## PR5 gating follow-up checklist

These entries track the second conversion pass for remaining player-side polling patterns.

| Subsystem | PR5 action | Remaining follow-up |
| --- | --- | --- |
| Lucky Find / Fortune's Favor | Replaced the enabled-perk update gate with dirty-state and short inventory scan windows; persisted the applied Luck bonus in player save data. | Prefer an explicit Lucky Coin inventory-change event from the award/drop path if one becomes available. |
| Burglar's Instinct / Unseen Hand | Replaced the enabled-perk ability refresh gate with dirty-state, short equipment/inventory scan windows, and runtime-owned spell cleanup retry state. | Prefer a direct equipment-change signal for lockpick/probe equip and unequip transitions. |
| Marksman Bow Fundamentals / Steady Draw | Replaced the timer-only agility refresh with dirty/window gating and limited Steady Draw frame checks to armed attack windows or active charge state. | Validate in game that bow attack animation windows arm Steady Draw early enough for held attacks. |
| Careful Repairs | Replaced enabled-perk repair-tool polling with repair-use/suppression/refund scan windows and persisted pending suppression count. | Prefer a direct repair-tool-use result event if OpenMW exposes one reliably. |
| Hand-to-hand player | Split Open Palm active timer handling from dirty/static equipment refreshes and removed the idle enabled-perk gate. | Prefer direct equipment/perk dirty events for weapon, shield, and glove changes. |

## PR6 dirty publishing follow-up checklist

These entries track the conversion from fixed-interval player-to-global state publishing to dirty-state publishing. Active effect timers remain update/frame-driven only while live.

| Subsystem | PR6 action | Remaining follow-up |
| --- | --- | --- |
| Perk state invalidation | Added a player-local `SkillPerkSystem_PerkStateChanged` event after perk add/remove/respec/effect-toggle paths so basepack publishers can invalidate static perk bundles without polling. | Expand this event if future perk mutation paths are added outside the current player script handlers. |
| Axe / Fellstar player publisher | Replaced the 1-second axe state/feather publish loop with dirty flags driven by load, perk changes, UI/equipment fallback events, and axe animation checks. | Prefer a direct equipment-changed signal over UI/animation fallback once OpenMW exposes one in this context. |
| Blunt weapon player publisher | Split Guarded Stamina refund timing from static blunt perk bundle publishing; the update gate now runs only while a refund is pending or blunt state is dirty. | Strength-derived damage bonus still needs invalidation if non-perk strength changes should update target-side damage outside combat/UI activity. |
| Marksman player state | Added perk/UI dirty invalidation for Bow Fundamentals/Deadeye agility refresh while leaving Steady Draw shot publishing event-driven. | Continue validating that Steady Draw frame windows cover all held-shot starts. |
| Hand-to-hand player publisher | Removed the 1-second hand-to-hand state publish timer and publishes target-side hand-to-hand state only when dirty, while keeping Open Palm timer cleanup active. | Replace short equipment scan windows with direct weapon/shield/glove equip events when available. |
| Combined player frame dispatcher | Added an idle `onFrame` predicate sampler so dormant frame handlers are not all evaluated every rendered frame; active frame handlers still run every frame until their predicate goes idle. | If future frame handlers must catch a same-frame input edge while idle, explicitly arm them from an event instead of relying on idle predicate polling. |

## PR7 target-side watcher follow-up checklist

These entries track the target-side conversion from repeated watcher scans toward shared watcher state and idle target-script removal.

| Subsystem | PR7 action | Remaining follow-up |
| --- | --- | --- |
| Global target watchers | Replaced separate axe, blunt, and hand-to-hand watcher scans with one shared active-actor watcher that only scans while at least one registered target-side provider is active. | Prefer fully on-demand attachment for hit-modifier-only features if future combat events expose enough target context globally. |
| Duelist's Tempo | Removed the unconditional Duelist's Tempo active-actor watcher and attaches the combined target script directly when applying target tempo state. | Validate in game that player-side combat handlers cover all previous target-bridge hit paths. |
| Combined target runtime | Added per-subsystem active-state checks and an idle removal request so target scripts can remove themselves after all local state is inactive. | Keep expanding active-state predicates if future target-side timers/debuffs are added. |
| Hand-to-hand Open Palm | Added a player-side hit path for Open Palm so it no longer depends on always-attached target bridge scripts. | Validate unarmed hit target detection across OpenMW attack payload variants. |

## High-cost candidates called out

1. **Hand-to-hand player glove/equipment polling** in `basepack_player.lua`: Centered Stance and Flowing Counter refresh every player update, while state publishing is only throttled after those refreshes.
2. **Global hand-to-hand watcher** in `basepack_global.lua`: scans `world.activeActors` every second to attach target scripts.
3. **Actor target script attached to active actors** by global watchers: every attached actor retains the combined target runtime until explicitly removed by target logic.
4. **Combined target `onUpdate` dispatch** in `basepack_actor_target.lua`: every attached target dispatches to axe, blunt, Duelist's Tempo, Aegis Rite, and hand-to-hand update paths each update.

## Recommended optimization order

1. **Add cheap gates before expensive scans and polls.** Skip global watcher scans when the corresponding published player state says no target-side perk is enabled; skip hand-to-hand equipment refresh when no relevant perk/effect is enabled.
2. **Separate active timers from cached state refreshes.** Keep per-update/per-frame timers only for active effects such as Open Palm, Duelist's Tempo, Aegis Rite primes, bleed ticks, and Steady Draw; move equipment/perk ability refreshes to load, acquire/remove, toggle, and equipment-change invalidation points where possible.
3. **Reduce target script residency.** Track whether any target module has live state and remove the combined target script once all module states are idle.
4. **Consolidate active-actor watcher passes.** If scans remain necessary, perform one shared global active-actor scan per interval instead of separate axe, hand-to-hand, blunt, and Duelist's Tempo scans.
5. **Lower fallback cadence after event coverage improves.** Security/repair condition fallback polling can become slower once direct tool-drain/repair events are trusted, with immediate event paths preserving responsiveness.
