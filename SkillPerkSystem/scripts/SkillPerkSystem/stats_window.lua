local interfaces = require("openmw.interfaces")
local core = require("openmw.core")
local pself = require("openmw.self")
local settings = require("scripts.SkillPerkSystem.settings")

local MOD_NAME = settings.MOD_NAME
local sectionName = "perks"
local localization = core.l10n(MOD_NAME)
local statsWindowInitialized = false

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

local function initStatsWindowIntegration()
    if statsWindowInitialized then
        return
    end

    if not interfaces.StatsWindow then
        return
    end

    local playerApi = interfaces[MOD_NAME .. "Player"]
    local sc = interfaces.StatsWindow.Constants

    interfaces.StatsWindow.trackStat(MOD_NAME, function()
        if playerApi == nil or type(playerApi.getActivePerks) ~= "function" then
            return {}
        end
        return playerApi.getActivePerks()
    end)

    interfaces.StatsWindow.addSectionToBox(sectionName, sc.DefaultBoxes.RIGHT_SCROLL_BOX, {
        l10n = MOD_NAME,
        placement = {
            type = sc.Placement.AFTER,
            target = sc.DefaultSections.BIRTHSIGN,
            priority = 1,
        },
        header = localization(sectionName),
        indent = true,
        sort = sc.Sort.LABEL_ASC,
        trackedStats = { [MOD_NAME] = true },
        builder = function()
            for _, perkID in ipairs(interfaces.StatsWindow.getStat(MOD_NAME) or {}) do
                interfaces.StatsWindow.addLineToSection(perkID, sectionName, buildLine(perkID))
            end
        end,
    })

    statsWindowInitialized = true
end

return {
    engineHandlers = {
        onInit = initStatsWindowIntegration,
        onLoad = initStatsWindowIntegration,
    }
}
