local interfaces = require("openmw.interfaces")

interfaces.SkillPerkSystem.registerEffect({
    id = "ern_example_longblade_precision_effect",
    onAcquire = function(context)
        print("[ErnExamplePerkPack] acquired " .. tostring(context and context.perkID))
    end,
    onRemove = function(context)
        print("[ErnExamplePerkPack] removed " .. tostring(context and context.perkID))
    end,
})

interfaces.SkillPerkSystem.registerEffect({
    id = "ern_example_longblade_mastery_effect",
    onAcquire = function(context)
        print("[ErnExamplePerkPack] acquired " .. tostring(context and context.perkID))
    end,
    onRemove = function(context)
        print("[ErnExamplePerkPack] removed " .. tostring(context and context.perkID))
    end,
})
