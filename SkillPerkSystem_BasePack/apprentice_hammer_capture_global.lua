local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local LOG_TAG = "[SkillPerkSystem_BasePack][ApprenticeHammer][CaptureGlobal]"
local registered = false

local function logDebug(message)
    print(string.format("%s %s", LOG_TAG, tostring(message)))
end

local function registerRepairCapture()
    if registered then
        return
    end

    local itemUsage = interfaces.ItemUsage
    if itemUsage == nil or type(itemUsage.addHandlerForType) ~= "function" then
        logDebug("interfaces.ItemUsage.addHandlerForType unavailable")
        return
    end

    itemUsage.addHandlerForType(types.Repair, function(repairItem, actor, options)
        if repairItem == nil or actor == nil then
            logDebug("repair capture skipped; item or actor missing")
            return
        end

        logDebug("captured repair tool " .. tostring(repairItem.recordId))
        actor:sendEvent("SkillPerkSystem_RecordRepairTool", {
            item = repairItem,
            recordId = repairItem.recordId,
        })
    end)

    registered = true
    logDebug("registered repair capture handler")
end

registerRepairCapture()

return {
    eventHandlers = {},
    engineHandlers = {},
}
