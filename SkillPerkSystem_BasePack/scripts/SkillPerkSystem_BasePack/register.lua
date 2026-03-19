local interfaces = require("openmw.interfaces")

local PACK_NAME = "SkillPerkSystem_BasePack"

print("[SkillPerkSystem_BasePack] register.lua executed")

local api = interfaces.SkillPerkSystem
if type(api) ~= "table" then
    error("[SkillPerkSystem_BasePack] interface lookup failed: interfaces.SkillPerkSystem is unavailable", 2)
end

print("[SkillPerkSystem_BasePack] found interfaces.SkillPerkSystem")
api.assertCompatibleApiVersion(1)
api.beginPackRegistration(PACK_NAME)

local blockSource = "scripts.SkillPerkSystem_BasePack.perks.block.block"
api.registerPerkModule(require(blockSource), "block", blockSource)
print("[SkillPerkSystem_BasePack] registered module block from " .. blockSource)

local longbladeSource = "scripts.SkillPerkSystem_BasePack.perks.longblade.longblade"
api.registerPerkModule(require(longbladeSource), "longblade", longbladeSource)
print("[SkillPerkSystem_BasePack] registered module longblade from " .. longbladeSource)

api.completePackRegistration(PACK_NAME)
print("[SkillPerkSystem_BasePack] pack registration complete")

return {}
