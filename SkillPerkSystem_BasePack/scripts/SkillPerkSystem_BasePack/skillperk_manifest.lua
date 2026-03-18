local interfaces = require("openmw.interfaces")

local PERK_MODULES = {
    {
        moduleName = "scripts.SkillPerkSystem_BasePack.perks.block.block",
        skillID = "block",
    },
    {
        moduleName = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade",
        skillID = "longblade",
    },
}

local registered = false
local VALIDATION_ERROR_TAG = "VALIDATION_ERROR"

local function tryRegisterModule(api, entry)
    local ok, err = pcall(api.registerPerkModule, require(entry.moduleName), entry.skillID)
    if ok then
        return true
    end

    local message = tostring(err)
    if message:find(VALIDATION_ERROR_TAG, 1, true) and message:find("duplicate", 1, true) then
        return true
    end

    error(err, 0)
end

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

    for _, entry in ipairs(PERK_MODULES) do
        tryRegisterModule(api, entry)
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
