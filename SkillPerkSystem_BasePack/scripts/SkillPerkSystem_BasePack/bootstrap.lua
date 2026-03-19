local interfaces = require("openmw.interfaces")
local registry = require("scripts.SkillPerkSystem_BasePack.bootstrap_registry")

local registered = false
local PACK_NAME = "SkillPerkSystem_BasePack"

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

    print("[SkillPerkSystem_BasePack] pack bootstrap detected SkillPerkSystem interface")
    if type(api.beginPackRegistration) == "function" then
        api.beginPackRegistration(PACK_NAME)
    end

    local totals = registry.registerWithCoreInterface(api)

    if type(api.completePackRegistration) == "function" then
        api.completePackRegistration(PACK_NAME)
    end
    print(
        "[SkillPerkSystem_BasePack] registered modules="
            .. tostring(totals.modules)
            .. " perks="
            .. tostring(totals.perks)
            .. " nodes="
            .. tostring(totals.nodes)
            .. " effects=0"
    )

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
