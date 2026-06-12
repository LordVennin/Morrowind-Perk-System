local pself = require("openmw.self")
local storage = require("openmw.storage")
local types = require("openmw.types")

local EFFECTS_SECTION_ID = "SkillPerkSystem_BasePack_Effects_Global"
local ENABLED_KEY = "security.lucky_find.enabled"
local COIN_RECORD_ID_KEY = "security.lucky_find.coin_record_id"
local TOGGLE_EVENT = "SkillPerkSystem_BasePack_LuckyFind_Toggle"
local DEBUG_LUCKY_FIND = true

local effectsSection = storage.globalSection(EFFECTS_SECTION_ID)
local appliedLuckBonus = 0
local lastLoggedCoinCount = nil
local enabledOverride = nil

local function log(message)
    if not DEBUG_LUCKY_FIND then
        return
    end
    print("[SkillPerkSystem_BasePack][LuckyFind][Player] " .. tostring(message))
end

local function luckyFindEnabled()
    if enabledOverride ~= nil then
        return enabledOverride == true
    end
    return effectsSection:get(ENABLED_KEY) == true
end

local function clampNonNegativeInteger(value)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then
        return 0
    end
    return n
end

local function countLuckyCoinsInInventory()
    if types.Actor == nil or type(types.Actor.inventory) ~= "function" then
        return 0
    end

    local coinRecordId = effectsSection:get(COIN_RECORD_ID_KEY)
    if type(coinRecordId) ~= "string" or coinRecordId == "" then
        return 0
    end

    local okInventory, inventory = pcall(types.Actor.inventory, pself)
    if not okInventory or inventory == nil or type(inventory.countOf) ~= "function" then
        return 0
    end

    local count = nil

    local okCountA, countA = pcall(function()
        return inventory:countOf(coinRecordId)
    end)
    if okCountA and type(countA) == "number" then
        count = countA
    end

    if (count == nil or count <= 0) and types.Miscellaneous ~= nil then
        local okRecord, record = pcall(function()
            return types.Miscellaneous.records[coinRecordId]
        end)
        if okRecord and record ~= nil then
            local okCountB, countB = pcall(function()
                return inventory:countOf(record)
            end)
            if okCountB and type(countB) == "number" then
                count = countB
            end
        end
    end

    local normalized = clampNonNegativeInteger(count or 0)
    if lastLoggedCoinCount ~= normalized then
        log(string.format("inventory lucky coin count=%d record=%s", normalized, tostring(coinRecordId)))
        lastLoggedCoinCount = normalized
    end

    return normalized
end

local function resolveLuckStat()
    local function tryLuckGetter(t)
        if t == nil then
            return nil
        end

        local okStats, stats = pcall(function()
            return t.stats
        end)
        if not okStats or stats == nil then
            return nil
        end

        local okAttrs, attrs = pcall(function()
            return stats.attributes
        end)
        if not okAttrs or attrs == nil then
            return nil
        end

        local okFn, fn = pcall(function()
            return attrs.luck
        end)
        if not okFn or type(fn) ~= "function" then
            return nil
        end

        local okStat, stat = pcall(fn, pself)
        if not okStat then
            return nil
        end

        return stat
    end

    local okType, actorType = pcall(function()
        return pself.type
    end)
    if not okType then
        return nil
    end

    local stat = tryLuckGetter(actorType)
    if stat ~= nil then
        return stat
    end

    local okBase, baseType = pcall(function()
        return actorType.baseType
    end)
    if okBase and baseType ~= nil then
        return tryLuckGetter(baseType)
    end

    return nil
end

local function applyLuckBonus(targetBonus)
    local desired = clampNonNegativeInteger(targetBonus)
    if desired > 0 and not luckyFindEnabled() then
        desired = 0
    end
    local current = clampNonNegativeInteger(appliedLuckBonus)
    if desired == current then
        return
    end

    local stat = resolveLuckStat()
    if stat == nil or type(stat.modifier) ~= "number" then
        log("unable to resolve writable luck modifier stat for player")
        return
    end

    -- Apply Lucky Coin bonus through the dedicated non-base modifier channel
    -- so base Luck is untouched and only our tracked coin contribution changes.
    local newModifier = math.floor(stat.modifier - current + desired)
    stat.modifier = newModifier
    appliedLuckBonus = desired
    log(string.format("applied luck bonus %d -> %d (new modifier=%d)", current, desired, newModifier))
end

local function refreshLuckBonus()
    if not luckyFindEnabled() then
        applyLuckBonus(0)
        return
    end

    applyLuckBonus(countLuckyCoinsInInventory())
end

local function handleToggle(data)
    if type(data) == "table" then
        enabledOverride = data.enable == true
        log(string.format("toggle enable=%s", tostring(data.enable == true)))
    end
    refreshLuckBonus()
end

local function onLoad()
    appliedLuckBonus = 0
    lastLoggedCoinCount = nil
    enabledOverride = nil
    refreshLuckBonus()
end

return {
    engineHandlers = {
        onUpdate = refreshLuckBonus,
        onLoad = onLoad,
    },
    eventHandlers = {
        [TOGGLE_EVENT] = handleToggle,
    },
}
