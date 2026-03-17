local settings = require("scripts.SkillPerkSystem.settings")

local samplePackManifests = {
    require("scripts.SkillPerkSystemSampleBlock.skillperk_manifest"),
    require("scripts.SkillPerkSystemSampleLongblade.skillperk_manifest"),
}

local function register(api)
    api.assertCompatibleApiVersion(1)

    if not settings.ENABLE_DEMO_TREE_PERKS then
        return
    end

    for _, sampleManifest in ipairs(samplePackManifests) do
        if type(sampleManifest) == "table" and type(sampleManifest.register) == "function" then
            sampleManifest.register(api)
        end
    end
end

return {
    register = register,
    modules = {},
}
