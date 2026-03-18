local interfaces = require("openmw.interfaces")
local blockModule = require("scripts.SkillPerkSystem_BasePack.perks.block.block")
local longbladeModule = require("scripts.SkillPerkSystem_BasePack.perks.longblade.longblade")

local registered = false

local function tryRegisterWithCore()
    if registered then
        return true
    end

    local api = interfaces.SkillPerkSystem
    if type(api) ~= "table" or type(api.registerPerkModule) ~= "function" then
        return false
    end

    if type(api.assertCompatibleApiVersion) == "function" then
        api.assertCompatibleApiVersion(1)
    end

    api.registerPerkModule(blockModule, "block")
    api.registerPerkModule(longbladeModule, "longblade")

    registered = true
    return true
end

tryRegisterWithCore()

return {
    engineHandlers = {
        onUpdate = function()
            tryRegisterWithCore()
        end,
    },
}
