# SkillPerkSystem Task/Planning Template

Use this template for new SkillPerkSystem implementation tasks so repository policy is inherited automatically.

## Scope

- Feature area:
- Files/modules expected to change (must be under `SkillPerkSystem/` and/or `SkillPerkSystem_BasePack/`):
- Out-of-scope areas:
  - `example_Mod/` (reference-only)
  - `ExampleModBF/` (reference-only)
  - `ExampleModlockpicking/` (reference-only)
  - `Advanced world map mod example/` (reference-only)

## Implementation Plan

1. 
2. 
3. 

## Runtime Performance/Gating Plan

- [ ] Identify every new or modified `engineHandlers.onUpdate` and `engineHandlers.onFrame` path.
- [ ] Classify each runtime handler as one of: event-only, active-effect cleanup, short detection window, dirty-state refresh, or unavoidable timed fallback.
- [ ] Confirm `hasEnabledPerk(...)` / `isPerkEffectEnabled(...)` is **not** the only reason an `onUpdate` or `onFrame` handler keeps running.
- [ ] Gate runtime polling behind cheap state checks so idle perks/effects return before inventory, equipment, actor-scan, spell, stat, or UI work.
- [ ] Keep per-frame work limited to input, animation, or UI behavior that must react immediately. Prefer explicit events, animation/combat callbacks, dirty-state invalidation, or short detection windows for everything else.
- [ ] Gate `world.activeActors` scans behind published player/perk state and consolidate scans when multiple subsystems need the same actor set.
- [ ] Separate active effect timers from static state refreshes; static equipment/perk-derived state should be cached or refreshed on load, perk changes, equipment changes, or explicit events.
- [ ] Ensure target scripts have an idle path or removal/deactivation plan so actors do not keep paying target-side update costs after effects expire.
- [ ] If a fallback poll is unavoidable, document the interaction it protects and throttle it with a named interval/window constant.

## Validation

- [ ] Confirm all implementation changes are inside `SkillPerkSystem/` and/or `SkillPerkSystem_BasePack/`.
- [ ] Confirm no files were added/edited/removed in `example_Mod/`.
- [ ] Confirm no files were added/edited/removed in `Advanced world map mod example/`.
- [ ] Run relevant tests/checks.
- [ ] Audit changed runtime paths with `rg -n "onUpdate|onFrame|world\.activeActors|addScript" SkillPerkSystem SkillPerkSystem_BasePack`.

## PR/Handoff Checklist

- [ ] I confirm this work follows the reference-only folder policy.
- [ ] I confirm there are **no** file changes under `example_Mod/`.
- [ ] I confirm there are **no** file changes under `Advanced world map mod example/`.
- [ ] I confirm active feature implementation changes are under `SkillPerkSystem/` and/or `SkillPerkSystem_BasePack/`.
- [ ] I confirm new/changed runtime handlers include idle gates and avoid ungated actor scans.
