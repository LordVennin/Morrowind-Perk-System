local interfaces = require("openmw.interfaces")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local skillModules = {
    longblade = {
        perks = "scripts.SkillPerkSystemBuiltin.perks.longblade",
        tree = "scripts.SkillPerkSystemBuiltin.trees.longblade",
    },
    block = {
        tree = "scripts.SkillPerkSystemBuiltin.trees.block",
    },
}

local function registerModule(modulePath, api)
    local module = require(modulePath)
    if type(module) == "table" and type(module.register) == "function" then
        module.register(api)
    end
end

local function register(api)
    api.assertCompatibleApiVersion(1)

    local builtInAPI = {
        registerPerk = api.registerPerk,
        registerTreeNode = api.registerTreeNode,
        registerEffect = api.registerEffect,
        registerPointSource = api.registerPointSource,
        playerHasPerk = function(perkID)
            local playerInterface = interfaces[MOD_NAME .. "Player"]
            return playerInterface ~= nil and playerInterface.hasPerk(perkID)
        end,
    }

    for _, skillModule in pairs(skillModules) do
        if type(skillModule.perks) == "string" then
            registerModule(skillModule.perks, builtInAPI)
        end
        if type(skillModule.tree) == "string" then
            registerModule(skillModule.tree, builtInAPI)
        end
    end
end

return {
    register = register,
}
