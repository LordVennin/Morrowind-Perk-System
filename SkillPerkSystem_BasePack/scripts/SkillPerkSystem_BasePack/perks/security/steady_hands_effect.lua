return {
    id = "security_steady_hands_effect",
    name = "Steady Hands",
    description = "Security perk effect scaffold for reduced lockpick/probe durability loss.",
    onAcquire = function(_context)
        -- TODO: Implement durability-loss reduction hooks for lockpicks/probes.
        -- Keep idempotent with future toggle support.
    end,
    onRemove = function(_context)
        -- TODO: Revert durability-loss reduction hooks.
    end,
}
