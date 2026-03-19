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

    local totals = { modules = 0, perks = 0, nodes = 0 }
    for _, entry in ipairs(MODULES) do
        local result = api.registerPerkModule(entry.data, entry.skillID, entry.moduleName)
        totals.modules = totals.modules + 1
        if type(result) == "table" and result.skipped ~= true then
            totals.perks = totals.perks + (result.perks or 0)
            totals.nodes = totals.nodes + (result.nodes or 0)
        end
    end
    return totals
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
