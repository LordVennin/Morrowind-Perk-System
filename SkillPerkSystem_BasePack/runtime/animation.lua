-- Shared animation plumbing for the SkillPerkSystem_BasePack player runtimes.
--
-- Perk runtimes register blended-animation handlers and (at most one) text-key
-- handler here; basepack_player.lua calls install() once every runtime module
-- has been required. Installing centrally removes the load-order dependency
-- that previously existed between the blunt weapon and hand-to-hand runtimes.

local interfaces = require("openmw.interfaces")

local function animationStringMethod(value, methodName)
    if type(value) ~= "string" then
        return nil
    end

    return value[methodName]
end

local function animationKeyLower(value)
    local lower = animationStringMethod(value, "lower")
    if type(lower) ~= "function" then
        return ""
    end

    return lower(value)
end

local function animationStringContains(value, needle)
    local find = animationStringMethod(value, "find")
    return type(find) == "function" and find(value, needle, 1, true) ~= nil
end

local function animationStringEndsWith(value, suffix)
    local sub = animationStringMethod(value, "sub")
    if type(sub) ~= "function" or #value < #suffix then
        return false
    end

    return sub(value, #value - #suffix + 1) == suffix
end

local function multiplyAnimationSpeed(options, multiplier)
    if type(options) ~= "table" then
        return
    end

    local currentSpeed = type(options.speed) == "number" and options.speed or 1.0
    options.speed = currentSpeed * multiplier
end

local function classifyBlendedAnimationEvent(groupName, options)
    local hasOptions = type(options) == "table"
    local hasGroupName = type(groupName) == "string"
    local groupLower = animationKeyLower(groupName)
    local startKeyRaw = hasOptions and (options.startkey or options.startKey) or nil
    local stopKeyRaw = hasOptions and (options.stopkey or options.stopKey) or nil
    local startKeyLower = animationKeyLower(startKeyRaw)
    local stopKeyLower = animationKeyLower(stopKeyRaw)
    local isAttackGroup = animationStringContains(groupLower, "attack")
    local isMaxAttack = animationStringEndsWith(stopKeyLower, " max attack")
    local isHit = animationStringEndsWith(stopKeyLower, "hit") and not animationStringEndsWith(stopKeyLower, "min hit")
    local isChopStart = startKeyLower == "chop start"
    local isSlashStart = startKeyLower == "slash start"
    local isThrustStart = startKeyLower == "thrust start"
    local isChopMaxAttack = stopKeyLower == "chop max attack"
    local isSlashMaxAttack = stopKeyLower == "slash max attack"
    local isThrustMaxAttack = stopKeyLower == "thrust max attack"

    return {
        groupName = groupName,
        groupLower = groupLower,
        hasGroupName = hasGroupName,
        options = options,
        hasOptions = hasOptions,
        startKey = startKeyRaw,
        stopKey = stopKeyRaw,
        startKeyLower = startKeyLower,
        stopKeyLower = stopKeyLower,
        isAttackGroup = isAttackGroup,
        isMaxAttack = isMaxAttack,
        isHit = isHit,
        isWeaponAttackWindup = hasOptions and (isMaxAttack or isAttackGroup),
        isChopAttackWindup = hasOptions and (isChopStart or isChopMaxAttack),
        isBluntAttackShape = hasOptions and (
            isChopStart
            or isSlashStart
            or isThrustStart
            or isChopMaxAttack
            or isSlashMaxAttack
            or isThrustMaxAttack
        ),
        isHandToHandAttackShape = hasOptions and (
            (animationStringEndsWith(startKeyLower, " start") and animationStringContains(startKeyLower, "attack"))
            or isMaxAttack
            or isHit
            or isAttackGroup
        ),
        isToolUseShape = hasGroupName and (
            animationStringContains(groupLower, "pick")
            or animationStringContains(groupLower, "probe")
            or animationStringContains(groupLower, "lock")
            or animationStringContains(groupLower, "security")
            or animationStringContains(startKeyLower, "pick")
            or animationStringContains(startKeyLower, "probe")
            or animationStringContains(stopKeyLower, "pick")
            or animationStringContains(stopKeyLower, "probe")
        ),
    }
end

local handlers = {}
local textKeyHandler = nil

local function registerHandler(handler)
    handlers[#handlers + 1] = handler
end

local function setTextKeyHandler(handler)
    textKeyHandler = handler
end

local function dispatchBlendedAnimation(groupName, options)
    local event = classifyBlendedAnimationEvent(groupName, options)

    for _, handler in ipairs(handlers) do
        handler(event)
    end
end

local function dispatchTextKey(actor, key)
    if textKeyHandler ~= nil then
        textKeyHandler(actor, key)
    end
end

local function install()
    local controller = interfaces.AnimationController
    if controller == nil then
        return
    end

    if type(controller.addPlayBlendedAnimationHandler) == "function" then
        controller.addPlayBlendedAnimationHandler(dispatchBlendedAnimation)
    end

    if type(controller.addTextKeyHandler) == "function" then
        controller.addTextKeyHandler("", dispatchTextKey)
    end
end

return {
    multiplyAnimationSpeed = multiplyAnimationSpeed,
    classifyBlendedAnimationEvent = classifyBlendedAnimationEvent,
    animationKeyLower = animationKeyLower,
    animationStringContains = animationStringContains,
    animationStringEndsWith = animationStringEndsWith,
    registerHandler = registerHandler,
    setTextKeyHandler = setTextKeyHandler,
    install = install,
}
