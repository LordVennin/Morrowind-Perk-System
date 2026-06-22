local world = require("openmw.world")
local types = require("openmw.types")

local Actor = types.Actor
local Armor = types.Armor
local Item = types.Item
local TARGET_SCRIPT = "scripts/SkillPerkSystem_BasePack/bluntweapon_target.lua"
local WATCHER_REFRESH_INTERVAL = 1.0

local refreshTimer = 0
local strengthInArmsState = {
    strengthInArmsEnabled = false,
    enabled = false,
    damageBonus = 0,
    platebreakerEnabled = false,
    playerId = nil,
}


local ARMOR_EQUIPMENT_SLOTS = {
    "Cuirass",
    "Greaves",
    "Helmet",
    "LeftGauntlet",
    "RightGauntlet",
    "LeftPauldron",
    "RightPauldron",
    "Boots",
    "CarriedLeft",
}

local function getEquippedItem(actor, slot)
    if Actor == nil or type(Actor.getEquipment) ~= "function" or actor == nil or slot == nil then
        return nil
    end

    local okEquipment, item = pcall(Actor.getEquipment, actor, slot)
    if not okEquipment then
        return nil
    end

    return item
end

local function getEquippedArmorItems(actor)
    local slots = Actor ~= nil and Actor.EQUIPMENT_SLOT or nil
    if slots == nil or Armor == nil or type(Armor.objectIsInstance) ~= "function" then
        return {}
    end

    local armorItems = {}
    for _, slotName in ipairs(ARMOR_EQUIPMENT_SLOTS) do
        local item = getEquippedItem(actor, slots[slotName])
        if item ~= nil and Armor.objectIsInstance(item) then
            local itemData = Item ~= nil and type(Item.itemData) == "function" and Item.itemData(item) or nil
            local condition = itemData ~= nil and tonumber(itemData.condition) or nil
            if condition ~= nil and condition > 0 then
                table.insert(armorItems, { itemData = itemData, condition = condition })
            end
        end
    end

    return armorItems
end

local function applyPlatebreakerArmorDamage(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.target
    if target == nil or (type(target.isValid) == "function" and not target:isValid()) then
        return
    end

    local conditionDamage = tonumber(data.conditionDamage)
    if conditionDamage == nil or conditionDamage <= 0 then
        return
    end
    conditionDamage = math.max(10, math.min(25, math.floor(conditionDamage)))

    local armorItems = getEquippedArmorItems(target)
    if #armorItems == 0 then
        return
    end

    local armor = armorItems[math.random(1, #armorItems)]
    armor.itemData.condition = math.max(0, armor.condition - conditionDamage)
end

local function shouldAttachWatcher(actor)
    if actor == nil or Actor == nil then
        return false
    end
    if type(actor.isValid) == "function" and not actor:isValid() then
        return false
    end
    if type(Actor.isDead) == "function" and Actor.isDead(actor) then
        return false
    end
    if world.players ~= nil and actor == world.players[1] then
        return false
    end
    if type(actor.hasScript) ~= "function" or type(actor.addScript) ~= "function" then
        return false
    end

    return not actor:hasScript(TARGET_SCRIPT)
end

local function sendState(actor)
    if actor ~= nil and type(actor.sendEvent) == "function" then
        actor:sendEvent("SkillPerkSystem_BluntWeaponStrengthInArmsRefresh", strengthInArmsState)
    end
end

local function refreshWatchers()
    for _, actor in ipairs(world.activeActors) do
        if shouldAttachWatcher(actor) then
            actor:addScript(TARGET_SCRIPT, strengthInArmsState)
        elseif actor ~= nil and type(actor.hasScript) == "function" and actor:hasScript(TARGET_SCRIPT) then
            sendState(actor)
        end
    end
end

local function onStrengthInArmsState(data)
    if type(data) ~= "table" then
        return
    end

    strengthInArmsState = {
        strengthInArmsEnabled = data.strengthInArmsEnabled == true or data.enabled == true,
        enabled = data.strengthInArmsEnabled == true or data.enabled == true,
        damageBonus = math.max(0, math.floor(tonumber(data.damageBonus) or 0)),
        platebreakerEnabled = data.platebreakerEnabled == true,
        playerId = type(data.playerId) == "string" and data.playerId or nil,
    }
    refreshWatchers()
end

return {
    eventHandlers = {
        SkillPerkSystem_BluntWeaponStrengthInArmsState = onStrengthInArmsState,
        SkillPerkSystem_ApplyPlatebreakerArmorDamage = applyPlatebreakerArmorDamage,
    },
    engineHandlers = {
        onUpdate = function(dt)
            refreshTimer = refreshTimer + (tonumber(dt) or 0)
            if refreshTimer >= WATCHER_REFRESH_INTERVAL then
                refreshTimer = 0
                refreshWatchers()
            end
        end,
        onLoad = function()
            refreshTimer = WATCHER_REFRESH_INTERVAL
            refreshWatchers()
        end,
    },
}
