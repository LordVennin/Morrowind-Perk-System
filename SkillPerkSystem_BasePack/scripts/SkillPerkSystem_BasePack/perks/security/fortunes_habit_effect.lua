local core = require("openmw.core")

local TOGGLE_EVENT = "SkillPerkSystem_BasePack_FortunesHabit_Toggle"

local function setFortunesHabitEnabled(enable)
    core.sendGlobalEvent(TOGGLE_EVENT, {
        enable = enable == true,
    })
end

return {
    id = "security_fortunes_habit_effect",
    name = "Fortune's Habit",
    description = "Raises Lucky Find chance and improves Treasure Sense scaling and payout.",
    onAcquire = function(_context)
        setFortunesHabitEnabled(true)
    end,
    onRemove = function(_context)
        setFortunesHabitEnabled(false)
    end,
}
