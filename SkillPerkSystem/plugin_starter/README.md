# SkillPerkSystem plugin starter pack

Copy this scaffold to create an explicit `.omwscripts`-driven addon pack.

## Starter structure

```text
SkillPerkSystem/plugin_starter/
  README.md
  YourPackName.omwscripts
  scripts/
    YourPackName/
      register.lua
      perks/
        longblade/
          01_core.lua
          10_bleed.lua
```

## Registration flow

1. `YourPackName.omwscripts` loads `scripts/YourPackName/register.lua`.
2. `register.lua` obtains `interfaces.SkillPerkSystem` in PLAYER context.
3. `register.lua` calls `assertCompatibleApiVersion(1)`.
4. `register.lua` loads each perk module and registers data through `registerPerk` / `registerTreeNode`.

## Content file

```text
PLAYER:scripts/YourPackName/register.lua
```

## Install order

1. `content=SkillPerkSystem.omwscripts`
2. `content=YourPackName.omwscripts`

Always load framework first.
