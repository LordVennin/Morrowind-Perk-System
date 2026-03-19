local PACK_NAME = "SkillPerkSystem_BasePack"
local registered = false
local waitingLogged = false

print("[SkillPerkSystem_BasePack] register.lua loaded")

local function tryRegister()
    if registered then
        return true
    end

    local interfaces = require("openmw.interfaces")
    local api = interfaces.SkillPerkSystem
    if type(api) ~= "table" then
        if not waitingLogged then
            waitingLogged = true
            print("[SkillPerkSystem_BasePack] waiting for interfaces.SkillPerkSystem")
        end
        return false
    end

    print("[SkillPerkSystem_BasePack] interface found")
    api.assertCompatibleApiVersion(1)
    api.beginPackRegistration(PACK_NAME)

    local blockSource = "scripts.SkillPerkSystem_BasePack.perks.block.block"
    api.registerPerkModule(require(blockSource), "block", blockSource)
    print("[SkillPerkSystem_BasePack] block registered")

    local longbladeSource = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade"
    api.registerPerkModule(require(longbladeSource), "longblade", longbladeSource)
    print("[SkillPerkSystem_BasePack] longblade registered")

    api.completePackRegistration(PACK_NAME)
    print("[SkillPerkSystem_BasePack] pack registration complete")

    registered = true
    return true
end

tryRegister()

return {
    engineHandlers = {
        onUpdate = function()
            tryRegister()
        end,
    },
}
