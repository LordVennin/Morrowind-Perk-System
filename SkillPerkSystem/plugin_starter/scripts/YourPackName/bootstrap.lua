local interfaces = require("openmw.interfaces")

local PACK_NAME = "YourPackName"
local PERK_MODULES = {
    { moduleName = "scripts.YourPackName.perks.longblade.01_core", skillID = "longblade" },
    { moduleName = "scripts.YourPackName.perks.longblade.10_bleed", skillID = "longblade" },
}

local registered = false

local function tryRegisterWithCore()
    if registered then
        return true
    end

    local api = interfaces.SkillPerkSystem
    if type(api) ~= "table" or type(api.registerPerkModule) ~= "function" then
        return false
    end

    api.assertCompatibleApiVersion(1)

    if type(api.beginPackRegistration) == "function" then
        api.beginPackRegistration(PACK_NAME)
    end

    for _, entry in ipairs(PERK_MODULES) do
        api.registerPerkModule(require(entry.moduleName), entry.skillID, entry.moduleName)
    end

    if type(api.completePackRegistration) == "function" then
        api.completePackRegistration(PACK_NAME)
    end

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
