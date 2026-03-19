local interfaces = require("openmw.interfaces")

local PACK_NAME = "YourPackName"
local PERK_MODULES = {
    { moduleName = "scripts.YourPackName.perks.longblade.01_core", skillID = "longblade" },
    { moduleName = "scripts.YourPackName.perks.longblade.10_bleed", skillID = "longblade" },
}

local api = interfaces.SkillPerkSystem
if type(api) ~= "table" then
    error("[YourPackName] interfaces.SkillPerkSystem unavailable", 2)
end

api.assertCompatibleApiVersion(1)
api.beginPackRegistration(PACK_NAME)

for _, entry in ipairs(PERK_MODULES) do
    api.registerPerkModule(require(entry.moduleName), entry.skillID, entry.moduleName)
end

api.completePackRegistration(PACK_NAME)

return {}
