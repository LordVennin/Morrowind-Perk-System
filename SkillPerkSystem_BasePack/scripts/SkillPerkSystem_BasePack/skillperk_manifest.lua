local function register(api)
    api.assertCompatibleApiVersion(1)
end

return {
    register = register,
    modules = {
        "scripts.SkillPerkSystem_BasePack.perks.block.block",
        "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
    },
}
