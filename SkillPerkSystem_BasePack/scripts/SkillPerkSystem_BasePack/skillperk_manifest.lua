local PERK_MODULES = {
    { moduleName = "scripts.SkillPerkSystem_BasePack.perks.block.block", skillID = "block" },
    { moduleName = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade", skillID = "longblade" },
}

local function register(api)
    api.assertCompatibleApiVersion(1)

    for _, entry in ipairs(PERK_MODULES) do
        api.registerPerkModule(require(entry.moduleName), entry.skillID)
    end
end

local modules = {}
for _, entry in ipairs(PERK_MODULES) do
    table.insert(modules, entry.moduleName)
end

return {
    register = register,
    modules = modules,
}
