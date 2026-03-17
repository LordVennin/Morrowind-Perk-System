local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local effectsByID = {
    demo_noop = {
        onAcquire = function(_) end,
        onRemove = function(_) end,
    },
}

local effectSourceByID = {
    demo_noop = "core:demo_builtin",
}

local duplicateEffectRegistrations = {}

local function warn(message)
    print("[" .. MOD_NAME .. "][effects] WARNING: " .. tostring(message))
end

local function duplicatePolicyLabel()
    if settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE then
        return "override(last-write-wins)"
    end
    return "strict(error)"
end

local function registerEffect(effectID, callbacks, source)
    if type(effectID) ~= "string" or effectID == "" then
        error("registerEffect() requires a non-empty string effectID", 2)
    end
    if type(callbacks) ~= "table" then
        error("registerEffect(" .. effectID .. ") requires a callbacks table", 2)
    end

    local sourceName = (type(source) == "string" and source ~= "") and source or "unknown"
    local previousSource = effectSourceByID[effectID]
    if previousSource ~= nil and not settings.ALLOW_DUPLICATE_REGISTRATION_OVERRIDE then
        table.insert(duplicateEffectRegistrations, {
            id = effectID,
            previousSource = previousSource,
            attemptedSource = sourceName,
        })
        error(
            "registerEffect() duplicate effect id '"
                .. tostring(effectID)
                .. "' from source='"
                .. tostring(sourceName)
                .. "' conflicts with source='"
                .. tostring(previousSource)
                .. "' policy="
                .. duplicatePolicyLabel(),
            2
        )
    end

    effectsByID[effectID] = callbacks
    effectSourceByID[effectID] = sourceName
end

local function invoke(effectID, callbackName, context)
    local effect = effectsByID[effectID]
    if effect == nil then
        warn("Missing effect handler for effectId='" .. tostring(effectID) .. "' callback='" .. tostring(callbackName) .. "'")
        return false
    end

    local callback = effect[callbackName]
    if type(callback) ~= "function" then
        warn("Missing callback '" .. tostring(callbackName) .. "' for effectId='" .. tostring(effectID) .. "'")
        return false
    end

    callback(context)
    return true
end

local function onAcquire(effectID, context)
    return invoke(effectID, "onAcquire", context)
end

local function onRemove(effectID, context)
    return invoke(effectID, "onRemove", context)
end

local function getEffects()
    return effectsByID
end

local function getEffectSource(effectID)
    return effectSourceByID[effectID]
end

return {
    registerEffect = registerEffect,
    onAcquire = onAcquire,
    onRemove = onRemove,
    getEffects = getEffects,
    getEffectSource = getEffectSource,
    getDuplicateEffectRegistrations = function()
        return duplicateEffectRegistrations
    end,
}
