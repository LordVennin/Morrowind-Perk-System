local interfaces = require("openmw.interfaces")
local core = require("openmw.core")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME
local sectionName = "perks"
local localization = core.l10n(MOD_NAME)
local statsWindowInitialized = false
local retryTimer = 0

local function normalizedPerkIDs(rawPerks)
    local out = {}

    if type(rawPerks) == "table" then
        for key, value in pairs(rawPerks) do
            if type(key) == "number" and type(value) == "string" then
                table.insert(out, value)
            elseif type(key) == "string" and value == true then
                table.insert(out, key)
            end
        end
    end

    table.sort(out)
    return out
end

local function buildLine(perkID)
    local modApi = interfaces[MOD_NAME]
    local perksByID = modApi ~= nil and type(modApi.getPerks) == "function" and modApi.getPerks() or {}
    local perk = perksByID[perkID] or {}

    local label = perk.title or perk.name or perkID
    if type(label) ~= "string" or label == "" then
        label = perkID
    end

    local description = perk.description
    if type(description) ~= "string" or description == "" then
        description = "No description."
    end

    return {
        label = label,
        tooltip = function()
            return interfaces.StatsWindow.TooltipBuilders.TEXT({ text = description })
        end,
        onClick = function()
            pself:sendEvent(MOD_NAME .. "showPerkUI", { selectedPerkID = perkID })
        end,
    }
end

local function addPerksSection(sc)
    -- Keep perks in the right-side skills list, specifically between Misc Skills and Reputation.
    local placementType = sc.Placement.BEFORE
    local placementTarget = sc.DefaultSections.REPUTATION

    if placementTarget == nil then
        placementType = sc.Placement.AFTER
        placementTarget = sc.DefaultSections.MISC_SKILLS
            or sc.DefaultSections.MINOR_SKILLS
            or sc.DefaultSections.MAJOR_SKILLS
    end

    interfaces.StatsWindow.addSectionToBox(sectionName, sc.DefaultBoxes.RIGHT_SCROLL_BOX, {
        l10n = MOD_NAME,
        placement = {
            type = placementType,
            target = placementTarget,
            priority = 1,
        },
        header = localization(sectionName),
        indent = true,
        sort = sc.Sort.LABEL_ASC,
        trackedStats = { [MOD_NAME] = true },
        builder = function()
            local perkIDs = normalizedPerkIDs(interfaces.StatsWindow.getStat(MOD_NAME) or {})
            for _, perkID in ipairs(perkIDs) do
                interfaces.StatsWindow.addLineToSection(perkID, sectionName, buildLine(perkID))
            end
        end,
    })
end

local function initStatsWindowIntegration()
    if statsWindowInitialized then
        return
    end

    if not interfaces.StatsWindow then
        return
    end

    local playerApi = interfaces[MOD_NAME .. "Player"]
    if playerApi == nil or type(playerApi.getActivePerks) ~= "function" then
        return
    end

    local sc = interfaces.StatsWindow.Constants

    interfaces.StatsWindow.trackStat(MOD_NAME, function()
        return normalizedPerkIDs(playerApi.getActivePerks() or {})
    end)

    addPerksSection(sc)

    statsWindowInitialized = true
end

local function onUpdate(dt)
    if statsWindowInitialized then
        return
    end

    retryTimer = retryTimer - (dt or 0)
    if retryTimer > 0 then
        return
    end

    retryTimer = 1
    initStatsWindowIntegration()
end

return {
    engineHandlers = {
        onInit = initStatsWindowIntegration,
        onLoad = initStatsWindowIntegration,
        onUpdate = onUpdate,
    }
}
