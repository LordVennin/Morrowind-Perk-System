-- Cross-subsystem state shared by the SkillPerkSystem_BasePack player runtimes.
-- Required from basepack_player.lua and from every runtime/player/*.lua module,
-- so all of them observe the same tables.

return {
    -- Published accessors that one perk tree exposes to another, e.g. the
    -- medium/heavy armor bonus getters consumed by the block runtime.
    shared = {},

    -- Repair tool tracking shared by the armorer runtimes (apprentice hammer
    -- and careful repairs both read and write this).
    repairToolState = {
        item = nil,
        recordId = nil,
        lastCondition = nil,
        source = nil,
    },
}
