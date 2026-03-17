local settings = require("scripts.SkillPerkSystem.settings")

local function isSamplePackEnabled()
    if settings.ENABLE_SAMPLE_PACK ~= nil then
        return settings.ENABLE_SAMPLE_PACK ~= false
    end

    return settings.ENABLE_DEMO_TREE_PERKS ~= false
end

local function register(api)
    api.assertCompatibleApiVersion(1)

    if not isSamplePackEnabled() then
        return
    end

    local modules = {
        {
            moduleName = "scripts.VenninsPerks.perks.longblade.longblade",
            skillId = "longblade",
        },
        {
            moduleName = "scripts.VenninsPerks.perks.block.block",
            skillId = "block",
        },
    }

    for _, module in ipairs(modules) do
        api.registerPerkModule(require(module.moduleName), module.skillId)
    end
end

return {
    register = register,
    modules = {},
}
