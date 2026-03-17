local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME

local effectsByID = {
    demo_noop = {
        onAcquire = function(_) end,
        onRemove = function(_) end,
    },
}

local function warn(message)
    print("[" .. MOD_NAME .. "][effects] WARNING: " .. tostring(message))
end

local function registerEffect(effectID, callbacks)
    if type(effectID) ~= "string" or effectID == "" then
        error("registerEffect() requires a non-empty string effectID", 2)
    end
    if type(callbacks) ~= "table" then
        error("registerEffect(" .. effectID .. ") requires a callbacks table", 2)
    end

    effectsByID[effectID] = callbacks
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

return {
    registerEffect = registerEffect,
    onAcquire = onAcquire,
    onRemove = onRemove,
}
