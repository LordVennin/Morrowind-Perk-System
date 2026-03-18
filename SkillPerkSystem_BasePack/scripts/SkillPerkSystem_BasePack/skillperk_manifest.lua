local interfaces = require("openmw.interfaces")

local PERK_MODULES = {
    { moduleName = "scripts.SkillPerkSystem_BasePack.perks.block.block", skillID = "block" },
    { moduleName = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade", skillID = "longblade" },
}

local isRegistered = false

local function tryRegisterWithCore()
    if isRegistered then
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
        api.registerPerkModule(require(entry.moduleName), entry.skillID)
    end

    isRegistered = true
    return true
end

tryRegisterWithCore()

return {
    -- Self-managed: this pack registers from its own omwscript context when enabled.
    selfManaged = true,
    engineHandlers = {
        onUpdate = function()
            tryRegisterWithCore()
        end,
    },
}
