local settings = require("scripts.SkillPerkSystem.settings")

local function register(api)
    api.assertCompatibleApiVersion(1)

    if not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    api.registerPerkModule(require("scripts.SkillPerkSystemSampleLongblade.perks.longblade.longblade"), "longblade")
end

return {
    register = register,
    modules = {},
}
