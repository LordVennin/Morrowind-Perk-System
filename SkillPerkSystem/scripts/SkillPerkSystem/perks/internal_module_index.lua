-- Intentionally empty.
--
-- Architecture policy: the base SkillPerkSystem framework ships without bundled perk trees.
-- Perk content must come from external content packs discovered at startup.
return {
    -- Deterministic internal module list loaded unconditionally at startup.
    -- Keep this empty unless you are explicitly building an internal-only development fork.
    modules = {},
}
