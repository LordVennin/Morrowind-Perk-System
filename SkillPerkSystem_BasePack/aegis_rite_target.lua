local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local selfObj = require("openmw.self")

local primedPlayerId = nil
local remainingTime = 0

local function setState(data)
    if type(data) ~= "table" then
        return
    end

    if type(data.playerId) == "string" then
        primedPlayerId = data.playerId
    end
    if data.duration ~= nil then
        remainingTime = math.max(0, tonumber(data.duration) or 0)
    end
end

local function clearAndRequestRemoval()
    remainingTime = 0
    core.sendGlobalEvent("SkillPerkSystem_RemoveAegisRiteTarget", {
        target = selfObj,
    })
end

local function isSuccessfulPlayerMeleeHit(attack)
    if type(attack) ~= "table" then
        return false
    end
    if attack.attacker == nil then
        return false
    end
    if type(primedPlayerId) ~= "string" or primedPlayerId == "" then
        return false
    end
    if attack.attacker.id ~= primedPlayerId then
        return false
    end
    if attack.successful ~= true then
        return false
    end

    local combatInterface = interfaces.Combat
    local meleeType = combatInterface and combatInterface.ATTACK_SOURCE_TYPES and combatInterface.ATTACK_SOURCE_TYPES.Melee or nil
    if meleeType ~= nil and attack.sourceType ~= meleeType then
        return false
    end

    return true
end

local function onHit(attack)
    if remainingTime <= 0 then
        return
    end
    if not isSuccessfulPlayerMeleeHit(attack) then
        return
    end

    if attack.attacker ~= nil and attack.attacker:isValid() then
        attack.attacker:sendEvent("SkillPerkSystem_TryConsumeAegisRite", {
            target = selfObj,
        })
    end

    remainingTime = 0
end

local addOnHitHandler = interfaces.Combat ~= nil and interfaces.Combat.addOnHitHandler
if type(addOnHitHandler) == "function" then
    addOnHitHandler(onHit)
end

return {
    eventHandlers = {
        SkillPerkSystem_AegisRiteRefresh = function(data)
            setState(data)
        end,
    },
    engineHandlers = {
        onInit = function(initData)
            setState(initData)
        end,
        onLoad = function(savedData, initData)
            if type(savedData) == "table" then
                setState(savedData)
            else
                setState(initData)
            end
        end,
        onSave = function()
            return {
                playerId = primedPlayerId,
                duration = remainingTime,
            }
        end,
        onUpdate = function(dt)
            if remainingTime <= 0 then
                return
            end

            remainingTime = math.max(0, remainingTime - (tonumber(dt) or 0))
            if remainingTime <= 0 then
                clearAndRequestRemoval()
            end
        end,
    },
}
