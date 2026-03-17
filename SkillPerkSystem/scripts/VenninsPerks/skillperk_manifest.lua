local function register(api)
    api.assertCompatibleApiVersion(1)

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
