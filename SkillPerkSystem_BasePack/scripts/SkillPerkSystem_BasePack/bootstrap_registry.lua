local blockModule = require("scripts.SkillPerkSystem_BasePack.perks.block.block")
local longbladeModule = require("scripts.SkillPerkSystem_BasePack.perks.longblade.longblade")

local MODULES = {
    {
        moduleName = "scripts.SkillPerkSystem_BasePack.perks.block.block",
        skillID = "block",
        data = blockModule,
    },
    {
        moduleName = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
        skillID = "longblade",
        data = longbladeModule,
    },
}

local function registerWithCoreInterface(api)
    if type(api.assertCompatibleApiVersion) == "function" then
        api.assertCompatibleApiVersion(1)
    end

    for _, entry in ipairs(MODULES) do
        api.registerPerkModule(entry.data, entry.skillID)
    end
end

local function registerWithPluginAPI(pluginAPI, source)
    local sourceName = source or "scripts.SkillPerkSystem_BasePack.bootstrap_registry"
    for _, entry in ipairs(MODULES) do
        pluginAPI.registerPerkModule(entry.data, sourceName, entry.skillID)
    end
end

return {
    modules = MODULES,
    registerWithCoreInterface = registerWithCoreInterface,
    registerWithPluginAPI = registerWithPluginAPI,
}
