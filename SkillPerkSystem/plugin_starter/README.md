# SkillPerkSystem plugin starter pack

Copy this scaffold to create an explicit `.omwscripts`-driven addon pack.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  YourPackName.omwscripts
  scripts/
    YourPackName/
      bootstrap.lua
      perks/
        longblade/
          01_core.lua
          10_bleed.lua
```

## Registration flow

1. `YourPackName.omwscripts` loads `scripts/YourPackName/bootstrap.lua`.
2. Bootstrap waits for `interfaces.SkillPerkSystem`.
3. Bootstrap calls `assertCompatibleApiVersion(1)`.
4. Bootstrap registers each module through `registerPerkModule(module, expectedSkill, source)`.
5. Bootstrap guards against double-registration with a `registered` flag.

## Content file

```text
PLAYER:scripts/YourPackName/bootstrap.lua
```

## Install order

1. `content=SkillPerkSystem.omwscripts`
2. `content=YourPackName.omwscripts`

Always load framework first.
