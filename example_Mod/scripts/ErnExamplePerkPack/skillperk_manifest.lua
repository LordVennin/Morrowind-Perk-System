local M = {}

function M.register(api)
    api.assertCompatibleApiVersion(1)

    api.registerPerk({
        id = "ern_example_longblade_precision",
        skill = "longblade",
        cost = 1,
        effectId = "ern_example_longblade_precision_effect",
        requirements = {},
    })

    api.registerTreeNode({
        id = "ern_example_longblade_precision",
        skill = "longblade",
        x = 0,
        y = 0,
        requires = {},
        title = "Example: Precision",
        description = "Minimal example tree node loaded from a plugin pack.",
    })
end

M.modules = {
    "scripts.ErnExamplePerkPack.perks.longblade",
    "scripts.ErnExamplePerkPack.effects.ern_example_longblade_precision_effect",
}

return M
