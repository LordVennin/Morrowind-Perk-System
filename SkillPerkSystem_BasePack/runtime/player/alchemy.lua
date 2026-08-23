-- Alchemy player runtime for SkillPerkSystem_BasePack.
-- Extracted from the consolidated basepack_player.lua; each perk tree now owns
-- its own Lua chunk so it has an independent 200-local budget.

local __basepack_subsystem_result = nil

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")
local ui = require("openmw.ui")
local util = require("openmw.util")
local async = require("openmw.async")

local PLAYER_INTERFACE_NAME = "SkillPerkSystemPlayer"
local INGREDIENT_LORE_PERK_ID = "alchemy_ingredient_lore"
local CAREFUL_MEASURE_PERK_ID = "alchemy_careful_measure"
local DUAL_DISTILLATION_PERK_ID = "alchemy_balanced_formula"
local CONCENTRATED_DRAUGHT_PERK_ID = "alchemy_concentrated_draught"
local LINGERING_TOXINS_PERK_ID = "alchemy_purified_toxins"
local MASTER_DISTILLATION_PERK_ID = "alchemy_master_distillation"
local PHILOSOPHERS_CRUCIBLE_PERK_ID = "alchemy_philosophers_crucible"
local PREPARATION_MODE_POTION = "potion"
local PREPARATION_MODE_POISON = "poison"
local CAREFUL_MEASURE_CHANCE = 0.25
local SETTLEMENT_FRAMES = 2
local INGREDIENT_LORE_TIERS = {
    { minimumAlchemy = 80, magnitude = 8, duration = 12 },
    { minimumAlchemy = 60, magnitude = 6, duration = 8 },
    { minimumAlchemy = 40, magnitude = 4, duration = 5 },
    { minimumAlchemy = 0, magnitude = 2, duration = 3 },
}
local LORE_REQUEST_EVENT = "SkillPerkSystem_BasePack_IngredientLoreApply"
local LORE_RESULT_EVENT = "SkillPerkSystem_BasePack_IngredientLoreResult"
local REFUND_REQUEST_EVENT = "SkillPerkSystem_BasePack_AlchemyRefundIngredient"
local REFUND_RESULT_EVENT = "SkillPerkSystem_BasePack_AlchemyRefundResult"
local COAT_REQUEST_EVENT = "SkillPerkSystem_BasePack_DualDistillationCoatRequest"
local CONVERT_REQUEST_EVENT = "SkillPerkSystem_BasePack_AlchemyRefineBrew"
local CONVERT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationConvertResult"
local DRINK_REQUEST_EVENT = "SkillPerkSystem_BasePack_DualDistillationDrinkPoison"
local RESTORE_REQUEST_EVENT = "SkillPerkSystem_BasePack_DualDistillationRestoreCoating"
local CLEAR_EVENT = "SkillPerkSystem_BasePack_DualDistillationClearCoating"
local COAT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationCoatResult"
local HIT_RESULT_EVENT = "SkillPerkSystem_BasePack_DualDistillationHitResult"
local LOG_TAG = "[SkillPerkSystem_BasePack][Alchemy][Player]"

local alchemyMenuOpen = false
local closingSession = false
local ingredientCounts = {}
local pendingBatch = nil
local successfulBrewsPending = 0
local requestSerial = 0
local pendingLoreRequests = {}
local pendingRefundRequests = {}
local lastAlchemyApparatus, lastAlchemyApparatusRecordId
local pendingUseApparatus, pendingUseApparatusFrames, replayTimeout = nil, 0, 0
local suppressNextAlchemyIntercept, alchemyChoiceMenuOpen = false, false
local pendingPreparationMode, activePreparationMode, settlementMode
local realAlchemySessionOpen = false
local potionOpeningCounts, poisonSettlementFrames = {}, 0
-- Distinct from an empty potionOpeningCounts: the player may legitimately own
-- no potions when the session opens, and the settlement pass must still run.
local potionSnapshotTaken = false
local preparationMenu, poisonUseMenu, replacementMenu
local selectedPoison, replacementPotion, replacementWeapon
local pendingConversionRequests, conversionSummary = {}, {}
local pendingCoatRequest, activeCoating, savedCoating
local coatingPoll, menuValidationPoll, restoreFrames = 0, 0, 0

local function log(message) print(LOG_TAG .. " " .. tostring(message)) end
local function hasEnabledPerk(perkId)
    local playerApi = interfaces[PLAYER_INTERFACE_NAME]
    if playerApi == nil or type(playerApi.hasPerk) ~= "function" then return false end
    if not playerApi.hasPerk(perkId) then return false end
    if type(playerApi.isPerkEffectEnabled) == "function" then
        return playerApi.isPerkEffectEnabled(perkId)
    end
    return true
end
-- Perks that rewrite a freshly brewed mixture. Collected once per settlement so
-- the global side sees a consistent set for the whole batch.
local function refinementPerkFlags()
    return {
        concentratedDraught = hasEnabledPerk(CONCENTRATED_DRAUGHT_PERK_ID),
        lingeringToxins = hasEnabledPerk(LINGERING_TOXINS_PERK_ID),
        crucible = hasEnabledPerk(PHILOSOPHERS_CRUCIBLE_PERK_ID),
        masterDistillation = hasEnabledPerk(MASTER_DISTILLATION_PERK_ID),
    }
end

local function anyRefinementPerkEnabled(flags)
    return flags.concentratedDraught or flags.lingeringToxins
        or flags.crucible or flags.masterDistillation
end

local function nextRequestId(prefix)
    requestSerial = requestSerial + 1
    return prefix .. tostring(requestSerial)
end
local function clearCarefulMeasure()
    alchemyMenuOpen = false
    closingSession = false
    ingredientCounts = {}
    pendingBatch = nil
    successfulBrewsPending = 0
    pendingRefundRequests = {}
end
local function ingredientRecord(recordId)
    if type(recordId) ~= "string" or recordId == "" then return nil end
    local ok, record = pcall(types.Ingredient.record, recordId)
    return ok and record or nil
end
local function snapshotIngredients()
    local counts = {}
    local ok, items = pcall(function()
        return types.Actor.inventory(pself):getAll(types.Ingredient)
    end)
    if not ok or items == nil then return counts end
    for _, item in pairs(items) do
        local recordId = item.recordId
        local count = math.max(0, math.floor(tonumber(item.count) or 1))
        if type(recordId) == "string" then counts[recordId] = (counts[recordId] or 0) + count end
    end
    return counts
end
local function rejectBatch(reason)
    if pendingBatch ~= nil then log("ambiguous batch rejected: " .. tostring(reason)) end
    pendingBatch = nil
end
local function compareIngredientCounts()
    local current = snapshotIngredients()
    local decreased, ids, inferred = {}, {}, 0
    for recordId, oldCount in pairs(ingredientCounts) do
        local amount = oldCount - (current[recordId] or 0)
        if amount > 0 then
            decreased[recordId] = amount
            ids[#ids + 1] = recordId
            inferred = math.max(inferred, amount)
        end
    end
    ingredientCounts = current
    if #ids == 0 then return end
    table.sort(ids)
    log("ingredient decreases=" .. table.concat(ids, ",") .. " inferred attempts=" .. tostring(inferred))
    if pendingBatch ~= nil then
        rejectBatch("overlapping inventory decreases")
        return
    end
    if inferred <= 0 then log("ambiguous batch rejected: invalid inferred attempt count") return end
    for _, recordId in ipairs(ids) do
        if decreased[recordId] ~= inferred then
            log("ambiguous batch rejected: unequal decreases suggest mixed inventory activity")
            return
        end
    end
    pendingBatch = { ids = ids, decreases = decreased, inferredAttempts = inferred, frames = SETTLEMENT_FRAMES }
end
local function requestRefund(recordId)
    local requestId = nextRequestId("CarefulMeasure_")
    pendingRefundRequests[requestId] = recordId
    core.sendGlobalEvent(REFUND_REQUEST_EVENT, {
        player = pself, ingredientRecordId = recordId, count = 1,
        requestId = requestId, reason = "careful_measure",
    })
end
local function resolveBatch()
    local batch = pendingBatch
    pendingBatch = nil
    if batch == nil then return end
    if not hasEnabledPerk(CAREFUL_MEASURE_PERK_ID) then log("ambiguous batch rejected: perk disabled") return end
    if successfulBrewsPending > batch.inferredAttempts then
        successfulBrewsPending = 0
        log("ambiguous batch rejected: excess success signals")
        return
    end
    local matched = math.min(successfulBrewsPending, batch.inferredAttempts)
    successfulBrewsPending = successfulBrewsPending - matched
    local failed = math.max(0, math.min(batch.inferredAttempts, batch.inferredAttempts - matched))
    log("failed-attempt count=" .. tostring(failed))
    for _ = 1, failed do
        local preserved = math.random() < CAREFUL_MEASURE_CHANCE
        log("preservation roll=" .. tostring(preserved))
        if preserved and #batch.ids > 0 then requestRefund(batch.ids[math.random(#batch.ids)]) end
    end
end
local function validObject(object)
    if object == nil then return false end
    if type(object.isValid) == "function" then local ok, valid = pcall(object.isValid, object); return ok and valid end
    return true
end
local function apparatusSet()
    local present, best, bestQuality = {}, nil, -math.huge
    local ok, items = pcall(function() return types.Actor.inventory(pself):getAll(types.Apparatus) end)
    if ok then for _, item in pairs(items or {}) do
        local okRecord, record = pcall(types.Apparatus.record, item)
        if okRecord and record then
            present[record.type] = true
            if record.type == types.Apparatus.TYPE.MortarPestle and validObject(item) and (tonumber(record.quality) or 0) > bestQuality then
                best, bestQuality = item, tonumber(record.quality) or 0
            end
        end
    end end
    local missing = {}
    for _, entry in ipairs({ {types.Apparatus.TYPE.MortarPestle,"Mortar and Pestle"}, {types.Apparatus.TYPE.Alembic,"Alembic"}, {types.Apparatus.TYPE.Calcinator,"Calcinator"}, {types.Apparatus.TYPE.Retort,"Retort"} }) do
        if not present[entry[1]] then missing[#missing + 1] = entry[2] end
    end
    log("complete apparatus set=" .. tostring(#missing == 0) .. (#missing > 0 and " missing=" .. table.concat(missing, ",") or ""))
    return #missing == 0, best, missing
end
local function snapshotPotions()
    local counts = {}
    local ok, items = pcall(function() return types.Actor.inventory(pself):getAll(types.Potion) end)
    if ok then for _, item in pairs(items or {}) do
        if type(item.recordId) == "string" then counts[item.recordId] = (counts[item.recordId] or 0) + math.max(0, math.floor(tonumber(item.count) or 1)) end
    end end
    return counts
end
local function harmfulPotion(recordId)
    local ok, record = pcall(types.Potion.record, recordId)
    if not ok or not record then return nil, {}, {} end
    local indices, names = {}, {}
    for index, effect in ipairs(record.effects or {}) do
        local okMagic, magic = pcall(function() return core.magic.effects.records[effect.id] end)
        if okMagic and magic and magic.harmful == true then indices[#indices + 1] = index - 1; names[#names + 1] = magic.name or effect.id end
    end
    return record, indices, names
end
local function destroyElement(element)
    if element ~= nil then pcall(element.destroy, element) end
end

local function setDualInterfaceMode()
    local uiApi = interfaces.UI
    if uiApi ~= nil and type(uiApi.setMode) == "function" then
        uiApi.setMode("Interface", { windows = { "Map", "Stats", "Magic", "Inventory" } })
    end
end

local function closePreparationMenu()
    destroyElement(preparationMenu)
    preparationMenu = nil
    alchemyChoiceMenuOpen = false
end

local function closePoisonUseMenu()
    destroyElement(poisonUseMenu)
    poisonUseMenu = nil
    selectedPoison = nil
end

local function closeReplacementMenu()
    destroyElement(replacementMenu)
    replacementMenu = nil
    replacementPotion = nil
    replacementWeapon = nil
end

local function closeAllDualMenus(reason)
    closePreparationMenu()
    closePoisonUseMenu()
    closeReplacementMenu()
    if reason ~= nil then log("menu cleanup reason=" .. tostring(reason)) end
end

local function updateDualMenus()
    for _, element in ipairs({ preparationMenu, poisonUseMenu, replacementMenu }) do
        if element ~= nil then element:update() end
    end
end

local function createDualButton(label, onSelect, width)
    local textLayout = {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.Center,
            relativeSize = util.vector2(1, 1),
        },
    }
    local innerButton = {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxButton,
        props = { size = util.vector2(width or 560, 28) },
        content = ui.content({ textLayout }),
    }
    return {
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = { autoSize = true },
        content = ui.content({ innerButton }),
        events = {
            mousePress = async:callback(function(event)
                if event.button == 1 then textLayout.template = interfaces.MWUI.templates.textHeader; updateDualMenus() end
            end),
            mouseRelease = async:callback(function(event) if event.button == 1 then onSelect() end end),
            focusGain = async:callback(function() textLayout.template = interfaces.MWUI.templates.textHeader; updateDualMenus() end),
            focusLoss = async:callback(function() textLayout.template = interfaces.MWUI.templates.textNormal; updateDualMenus() end),
        },
    }
end

local function createDualMenu(name, contentLayouts)
    local element = ui.create({
        layer = "Windows",
        name = name,
        type = ui.TYPE.Container,
        template = interfaces.MWUI.templates.boxTransparentThick,
        props = {
            anchor = util.vector2(0.5, 0.5),
            relativePosition = util.vector2(0.5, 0.5),
            autoSize = true,
        },
        content = ui.content({
            {
                type = ui.TYPE.Flex,
                template = interfaces.MWUI.templates.background,
                props = {
                    horizontal = false,
                    autoSize = true,
                    padding = util.vector2(12, 12),
                    arrange = ui.ALIGNMENT.Center,
                },
                content = ui.content(contentLayouts),
            },
        }),
    })
    setDualInterfaceMode()
    return element
end

local function equippedWeapon()
    local ok, weapon = pcall(types.Actor.getEquipment, pself, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not ok or not validObject(weapon) or not types.Weapon.objectIsInstance(weapon) then return nil end
    return weapon
end

local function inventoryContainsPotion(potion, recordId)
    if not validObject(potion) or potion.recordId ~= recordId or (tonumber(potion.count) or 1) < 1 then return false end
    local ok, items = pcall(function() return types.Actor.inventory(pself):getAll(types.Potion) end)
    if not ok then return false end
    for _, item in pairs(items or {}) do if item == potion then return true end end
    return false
end

local function queuePreparation(mode, apparatus)
    pendingPreparationMode = mode
    suppressNextAlchemyIntercept = true
    pendingUseApparatus = apparatus
    pendingUseApparatusFrames = 1
    replayTimeout = 8
    closePreparationMenu()
    log("selected preparation mode=" .. mode)
end

local function openPreparationMenu(apparatus)
    closeAllDualMenus("opening preparation menu")
    alchemyChoiceMenuOpen = true
    lastAlchemyApparatus = apparatus
    local layouts = {
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textHeader,
            props = { text = "Dual Distillation", textAlignH = ui.ALIGNMENT.Center } },
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textNormal,
            props = { text = "Choose how to prepare your mixtures.", textAlignH = ui.ALIGNMENT.Center } },
        createDualButton("Brew Potions", function()
            if validObject(apparatus) then queuePreparation(PREPARATION_MODE_POTION, apparatus) end
        end),
        createDualButton("Prepare Weapon Poisons", function()
            local complete, best = apparatusSet()
            local replay = validObject(apparatus) and apparatus or best
            if not hasEnabledPerk(DUAL_DISTILLATION_PERK_ID) or not complete or replay == nil then
                ui.showMessage("Dual Distillation requires a complete set of alchemy tools.", { showInDialogue = false })
                return
            end
            queuePreparation(PREPARATION_MODE_POISON, replay)
        end),
        createDualButton("Cancel", function()
            pendingPreparationMode = nil
            pendingUseApparatus = nil
            suppressNextAlchemyIntercept = false
            closePreparationMenu()
            log("preparation menu cancelled")
        end),
    }
    preparationMenu = createDualMenu("SkillPerkSystem_BasePack_DualDistillationChoice", layouts)
    log("Armorer-style preparation menu opened")
end

local function beginRealAlchemySession(mode)
    activePreparationMode = mode or PREPARATION_MODE_POTION
    clearCarefulMeasure()
    realAlchemySessionOpen = true
    potionOpeningCounts, potionSnapshotTaken = {}, false
    if hasEnabledPerk(CAREFUL_MEASURE_PERK_ID) then
        alchemyMenuOpen = true
        ingredientCounts = snapshotIngredients()
    end
    -- The settlement pass diffs potion counts to find what was brewed. Poison
    -- mode always needs it; potion mode only when a perk will rewrite the result.
    if activePreparationMode == PREPARATION_MODE_POISON or anyRefinementPerkEnabled(refinementPerkFlags()) then
        potionOpeningCounts = snapshotPotions()
        potionSnapshotTaken = true
        local count = 0
        for _ in pairs(potionOpeningCounts) do count = count + 1 end
        log("opening Potion snapshot count=" .. tostring(count))
    end
    log("real Alchemy session started mode=" .. activePreparationMode)
end

local function finishConversionSummary()
    if next(pendingConversionRequests) ~= nil then return end
    local converted = conversionSummary.converted or 0
    local refined = conversionSummary.refined or 0
    local bonus = conversionSummary.bonus or 0
    local isPoison = conversionSummary.mode == PREPARATION_MODE_POISON
    local message = nil

    if converted > 0 then
        message = string.format("Prepared %d weapon poison dose%s.", converted, converted == 1 and "" or "s")
        if conversionSummary.keptBeneficial then
            message = message .. " Beneficial mixtures were kept as normal potions."
        end
    elseif isPoison and conversionSummary.requested and refined == 0 then
        message = "The newly brewed mixtures could not be prepared as weapon poisons."
    end

    if refined > 0 then
        local refinedMessage = string.format("Refined %d potion dose%s.", refined, refined == 1 and "" or "s")
        message = message and (message .. " " .. refinedMessage) or refinedMessage
    end

    if bonus > 0 then
        local extra = string.format("Master Distillation yielded %d extra dose%s.", bonus, bonus == 1 and "" or "s")
        message = message and (message .. " " .. extra) or extra
    end

    if message ~= nil then ui.showMessage(message, { showInDialogue = false }) end
    conversionSummary = {}
end

-- Runs a few frames after the alchemy menu closes, once the engine has settled
-- the brewed items into the inventory. Diffs potion counts against the opening
-- snapshot and asks the global side to refine whatever is new.
local function settleBrewSession(mode)
    local current = snapshotPotions()
    local flags = refinementPerkFlags()
    local isPoison = mode == PREPARATION_MODE_POISON
    pendingConversionRequests = {}
    conversionSummary = { converted = 0, bonus = 0, requested = false, keptBeneficial = false, mode = mode }
    for recordId, count in pairs(current) do
        local difference = count - (potionOpeningCounts[recordId] or 0)
        if difference > 0 then
            log("positive source Potion difference=" .. recordId .. ":" .. difference)
            local record, harmful = harmfulPotion(recordId)
            local canPoison = isPoison and record ~= nil and #harmful > 0
                and hasEnabledPerk(DUAL_DISTILLATION_PERK_ID)
            -- A mixture with no harmful effects cannot become a poison, so it
            -- stays a potion and is refined as one. That also lets Master
            -- Distillation apply to beneficial brews made during a poison session.
            if isPoison and not canPoison then conversionSummary.keptBeneficial = true end
            -- Potion refining only has work to do when a perk actually changes
            -- the result; otherwise the brew is already what the player wanted.
            local canRefinePotion = not canPoison and record ~= nil and anyRefinementPerkEnabled(flags)
            if canPoison or canRefinePotion then
                local requestId = nextRequestId("AlchemyRefine_")
                pendingConversionRequests[requestId] = true
                conversionSummary.requested = true
                core.sendGlobalEvent(CONVERT_REQUEST_EVENT, {
                    player = pself, sourcePotionRecordId = recordId,
                    count = difference, requestId = requestId,
                    mode = canPoison and PREPARATION_MODE_POISON or PREPARATION_MODE_POTION,
                    perks = flags,
                })
                log("refine request source=" .. recordId .. " count=" .. difference
                    .. " mode=" .. (canPoison and PREPARATION_MODE_POISON or PREPARATION_MODE_POTION))
            end
        end
    end
    potionOpeningCounts = {}
    potionSnapshotTaken = false
    finishConversionSummary()
end

local function requestCoating(potion, weapon, replaceExisting)
    if pendingCoatRequest ~= nil or not inventoryContainsPotion(potion, potion.recordId) then
        log("Potion validation failure before coating request")
        closeAllDualMenus("invalid selected poison")
        return
    end
    pendingCoatRequest = nextRequestId("DualDistillationCoat_")
    core.sendGlobalEvent(COAT_REQUEST_EVENT, {
        player = pself, potion = potion, potionRecordId = potion.recordId,
        weapon = weapon, requestId = pendingCoatRequest,
        replaceExisting = replaceExisting == true,
    })
    log("Apply selected=" .. tostring(potion.recordId))
end

local function openReplacementMenu(potion, weapon)
    closeReplacementMenu()
    replacementPotion, replacementWeapon = potion, weapon
    replacementMenu = createDualMenu("SkillPerkSystem_BasePack_DualDistillationReplace", {
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textHeader,
            props = { text = "Replace Weapon Coating", textAlignH = ui.ALIGNMENT.Center } },
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textNormal,
            props = { text = "Replace the existing weapon coating?", textAlignH = ui.ALIGNMENT.Center } },
        createDualButton("Replace Existing Coating", function()
            local selected, equipped = replacementPotion, replacementWeapon
            closeReplacementMenu()
            requestCoating(selected, equipped, true)
        end),
        createDualButton("Cancel", function() closeReplacementMenu(); log("replacement menu cancelled") end),
    })
    log("replacement menu opened")
end

local function openPoisonUseMenu(data)
    local potion = type(data) == "table" and data.potion or nil
    local recordId = type(data) == "table" and data.potionRecordId or nil
    if not inventoryContainsPotion(potion, recordId) then log("Potion validation failure on use"); return end
    closeAllDualMenus("opening poison-use menu")
    selectedPoison = potion
    local record = types.Potion.record(recordId)
    poisonUseMenu = createDualMenu("SkillPerkSystem_BasePack_DualDistillationUse", {
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textHeader,
            props = { text = "Use Prepared Poison", textAlignH = ui.ALIGNMENT.Center } },
        { type = ui.TYPE.Text, template = interfaces.MWUI.templates.textNormal,
            props = { text = tostring(record.name or recordId), textAlignH = ui.ALIGNMENT.Center } },
        createDualButton("Drink Poison", function()
            local selected = selectedPoison
            if not inventoryContainsPotion(selected, recordId) then closeAllDualMenus("invalid selected poison"); return end
            local requestId = nextRequestId("DualDistillationDrink_")
            log("Drink selected=" .. recordId)
            closeAllDualMenus("Drink selected")
            core.sendGlobalEvent(DRINK_REQUEST_EVENT, { player = pself, potion = selected, requestId = requestId })
        end),
        createDualButton("Apply to Equipped Weapon", function()
            local selected = selectedPoison
            if not inventoryContainsPotion(selected, recordId) then closeAllDualMenus("invalid selected poison"); return end
            local weapon = equippedWeapon()
            if weapon == nil then ui.showMessage("Equip a weapon before applying poison.", { showInDialogue = false }); return end
            if activeCoating ~= nil then openReplacementMenu(selected, weapon)
            else requestCoating(selected, weapon, false) end
        end),
        createDualButton("Cancel", function() closePoisonUseMenu(); log("poison-use menu cancelled") end),
    })
    log("poison-use menu opened=" .. recordId)
end
local function endRealAlchemySession()
    if not realAlchemySessionOpen then return end
    if alchemyMenuOpen then compareIngredientCounts(); alchemyMenuOpen=false; closingSession=pendingBatch~=nil; if not closingSession then ingredientCounts={}; successfulBrewsPending=0 end end
    if potionSnapshotTaken then
        settlementMode = activePreparationMode or PREPARATION_MODE_POTION
        poisonSettlementFrames = SETTLEMENT_FRAMES
    end
    log("real Alchemy session ended mode="..tostring(activePreparationMode)); realAlchemySessionOpen=false; activePreparationMode=nil
end
local function clearDual(reason, notifyGlobal)
    closeAllDualMenus(reason)
    pendingUseApparatus, pendingUseApparatusFrames, replayTimeout = nil, 0, 0
    suppressNextAlchemyIntercept = false
    pendingPreparationMode, activePreparationMode, settlementMode = nil, nil, nil
    realAlchemySessionOpen = false
    potionOpeningCounts, poisonSettlementFrames = {}, 0
    potionSnapshotTaken = false
    pendingConversionRequests, conversionSummary = {}, {}
    pendingCoatRequest = nil
    if activeCoating ~= nil and notifyGlobal then
        core.sendGlobalEvent(CLEAR_EVENT, { player = pself, coatingId = activeCoating.coatingId, reason = reason })
    end
    activeCoating, coatingPoll = nil, 0
    log("coating cleared reason=" .. tostring(reason))
end
local function shouldFrame()
    return pendingUseApparatus ~= nil or suppressNextAlchemyIntercept or poisonSettlementFrames > 0 or restoreFrames > 0 or (alchemyMenuOpen and hasEnabledPerk(CAREFUL_MEASURE_PERK_ID))
        or pendingBatch ~= nil or next(pendingRefundRequests) ~= nil
end
local function onFrame()
    if pendingUseApparatus ~= nil then
        pendingUseApparatusFrames=pendingUseApparatusFrames-1
        if pendingUseApparatusFrames<=0 then local replay=pendingUseApparatus; pendingUseApparatus=nil; log("apparatus replay="..tostring(replay.recordId)); core.sendGlobalEvent("UseItem",{object=replay,actor=pself}) end
    elseif suppressNextAlchemyIntercept and replayTimeout>0 then replayTimeout=replayTimeout-1; if replayTimeout<=0 then suppressNextAlchemyIntercept=false; pendingPreparationMode=nil; log("apparatus replay timeout") end end
    if poisonSettlementFrames>0 then poisonSettlementFrames=poisonSettlementFrames-1; if poisonSettlementFrames<=0 then local mode=settlementMode; settlementMode=nil; settleBrewSession(mode) end end
    if restoreFrames>0 then restoreFrames=restoreFrames-1; if restoreFrames<=0 and savedCoating then local weapon=equippedWeapon(); if weapon and weapon.recordId==savedCoating.weaponRecordId and harmfulPotion(savedCoating.potionRecordId) then core.sendGlobalEvent(RESTORE_REQUEST_EVENT,{player=pself,weapon=weapon,coating=savedCoating}) else savedCoating=nil end end end
    if alchemyMenuOpen then compareIngredientCounts() end
    if pendingBatch ~= nil then
        pendingBatch.frames = pendingBatch.frames - 1
        if pendingBatch.frames <= 0 then resolveBatch() end
    end
    if closingSession and pendingBatch == nil then
        if successfulBrewsPending > 0 then log("ambiguous batch rejected: unmatched success signals") end
        ingredientCounts = {}; successfulBrewsPending = 0; closingSession = false
    end
end
local function shouldUpdate()
    return activeCoating ~= nil or poisonUseMenu ~= nil or replacementMenu ~= nil
end
local function onUpdate(dt)
    local delta = tonumber(dt) or 0
    if poisonUseMenu ~= nil or replacementMenu ~= nil then
        menuValidationPoll = menuValidationPoll + delta
        if menuValidationPoll >= 0.5 then
            menuValidationPoll = 0
            local potion = replacementMenu ~= nil and replacementPotion or selectedPoison
            if potion == nil or not inventoryContainsPotion(potion, potion.recordId) then
                closeAllDualMenus("selected poison became invalid")
            end
        end
    else
        menuValidationPoll = 0
    end
    if activeCoating == nil then coatingPoll = 0; return end
    coatingPoll = coatingPoll + delta
    if coatingPoll < 0.5 then return end
    coatingPoll = 0
    local weapon = equippedWeapon()
    if weapon == nil or weapon ~= activeCoating.weapon then
        log("equipped weapon mismatch")
        clearDual("weapon changed", true)
        ui.showMessage("The weapon coating is lost.", { showInDialogue = false })
    end
end
local function modeIsAlchemy(mode) return tostring(mode or ""):lower() == "alchemy" end
local function onUiModeChanged(data)
    data=type(data)=="table" and data or {}; local entering=modeIsAlchemy(data.newMode) and not modeIsAlchemy(data.oldMode); local leaving=modeIsAlchemy(data.oldMode) and not modeIsAlchemy(data.newMode)
    if entering then
        if suppressNextAlchemyIntercept then suppressNextAlchemyIntercept=false; pendingUseApparatus=nil; replayTimeout=0; local mode=pendingPreparationMode or PREPARATION_MODE_POTION; pendingPreparationMode=nil; beginRealAlchemySession(mode); return end
        if not hasEnabledPerk(DUAL_DISTILLATION_PERK_ID) then beginRealAlchemySession(PREPARATION_MODE_POTION); return end
        local complete,best=apparatusSet(); if not complete then beginRealAlchemySession(PREPARATION_MODE_POTION); return end
        local replay=validObject(lastAlchemyApparatus) and lastAlchemyApparatus or best
        if not replay then beginRealAlchemySession(PREPARATION_MODE_POTION); return end
        log("initial Alchemy interception"); local uiApi=interfaces.UI; if uiApi and type(uiApi.setMode)=="function" then uiApi.setMode("Interface",{windows={"Map","Stats","Magic","Inventory"}}) end; openPreparationMenu(replay)
    elseif leaving then
        endRealAlchemySession()
    elseif (data.newMode == nil or data.newMode == "MainMenu") and not entering then
        closeAllDualMenus("incompatible UI mode")
    end
end
local function alchemyTier()
    local modified = 0
    pcall(function() modified = tonumber(types.NPC.stats.skills.alchemy(pself).modified) or 0 end)
    for index, tier in ipairs(INGREDIENT_LORE_TIERS) do
        if modified >= tier.minimumAlchemy then return index, tier end
    end
    return #INGREDIENT_LORE_TIERS, INGREDIENT_LORE_TIERS[#INGREDIENT_LORE_TIERS]
end
local function onConsume(item)
    if not hasEnabledPerk(INGREDIENT_LORE_PERK_ID) then return end
    local recordId = item and item.recordId
    local record = ingredientRecord(recordId)
    if record == nil or record.effects == nil then return end
    local valid = {}
    for index, effect in ipairs(record.effects) do
        if effect ~= nil and type(effect.id) == "string" and effect.id ~= "" then
            valid[#valid + 1] = { index = index - 1, effectId = effect.id }
        end
    end
    if #valid == 0 then log("rejected consumed ingredient " .. tostring(recordId) .. ": no valid effects") return end
    local selected = valid[math.random(#valid)]
    local tierIndex = alchemyTier()
    local requestId = nextRequestId("IngredientLore_")
    pendingLoreRequests[requestId] = true
    log(string.format("consumed=%s effectIndex=%d effectId=%s tier=%d", recordId, selected.index, selected.effectId, tierIndex))
    core.sendGlobalEvent(LORE_REQUEST_EVENT, {
        player = pself, ingredientRecordId = recordId, sourceEffectIndex = selected.index,
        powerTier = tierIndex, requestId = requestId,
    })
end
local function onLoreResult(data)
    if type(data) ~= "table" or pendingLoreRequests[data.requestId] == nil then return end
    pendingLoreRequests[data.requestId] = nil
    if data.success then
        ui.showMessage("Ingredient Lore reveals: " .. tostring(data.effectName or data.effectId or "Unknown Effect") .. ".", { showInDialogue = false })
    else log("Ingredient Lore application failed: " .. tostring(data.failureReason)) end
end
local function onRefundResult(data)
    if type(data) ~= "table" or pendingRefundRequests[data.requestId] == nil then return end
    pendingRefundRequests[data.requestId] = nil
    if data.success then
        ui.showMessage("Careful Measure preserves " .. tostring(data.ingredientName or data.ingredientRecordId or "an ingredient") .. ".", { showInDialogue = false })
        log("refunded ingredient=" .. tostring(data.ingredientRecordId))
    else log("refund delivery failed: " .. tostring(data.failureReason)) end
end
local function onCoatResult(data)
    if type(data) ~= "table" then return end
    if data.restore ~= true and (pendingCoatRequest == nil or data.requestId ~= pendingCoatRequest) then return end
    pendingCoatRequest = nil
    if data.success then
        activeCoating = {
            coatingId = data.coatingId, weapon = data.weapon,
            weaponRecordId = data.weaponRecordId, weaponName = data.weaponName,
            potionRecordId = data.potionRecordId, potionName = data.potionName,
        }
        savedCoating = nil
        closeAllDualMenus("coating succeeded")
        ui.showMessage(tostring(data.weaponName) .. " coated with " .. tostring(data.potionName) .. ".", { showInDialogue = false })
    elseif data.restore ~= true then
        ui.showMessage(tostring(data.failureReason or "The weapon could not be coated."), { showInDialogue = false })
    else
        savedCoating = nil
    end
end

local function onConversionResult(data)
    if type(data) ~= "table" or pendingConversionRequests[data.requestId] == nil then return end
    pendingConversionRequests[data.requestId] = nil
    local count = math.max(0, math.floor(tonumber(data.convertedCount) or 0))
    if data.mode == PREPARATION_MODE_POISON then
        conversionSummary.converted = (conversionSummary.converted or 0) + count
    -- Only count a potion as refined when its effects actually changed; a
    -- Master Distillation-only batch keeps its original record.
    elseif data.effectsRefined == true then
        conversionSummary.refined = (conversionSummary.refined or 0) + count
    end
    conversionSummary.bonus = (conversionSummary.bonus or 0) + math.max(0, math.floor(tonumber(data.bonusCount) or 0))
    if not data.success then log("refine failure source=" .. tostring(data.sourcePotionRecordId) .. " reason=" .. tostring(data.failureReason)) end
    finishConversionSummary()
end
local function onHitResult(data) if type(data)=="table" and activeCoating and data.coatingId==activeCoating.coatingId then activeCoating=nil; if data.success then ui.showMessage(tostring(data.potionName).." affects "..tostring(data.targetName)..".",{showInDialogue=false}) end end end
local function onRecordApparatus(data) if type(data)=="table" and validObject(data.item) and types.Apparatus.objectIsInstance(data.item) then lastAlchemyApparatus=data.item; lastAlchemyApparatusRecordId=data.recordId or data.item.recordId; log("apparatus captured="..tostring(lastAlchemyApparatusRecordId)) end end
local function onPerkStateChanged(data)
    if type(data) ~= "table" then return end
    local perkId = data.perkId or data.id
    if perkId == INGREDIENT_LORE_PERK_ID and not hasEnabledPerk(INGREDIENT_LORE_PERK_ID) then pendingLoreRequests = {} end
    if perkId == CAREFUL_MEASURE_PERK_ID and not hasEnabledPerk(CAREFUL_MEASURE_PERK_ID) then clearCarefulMeasure() end
    if perkId == DUAL_DISTILLATION_PERK_ID and not hasEnabledPerk(DUAL_DISTILLATION_PERK_ID) then clearDual("perk disabled", true) end
end
local function recordSuccessfulBrew(eventOrSkillId, params)
    local skillId, eventParams = eventOrSkillId, params
    if type(eventOrSkillId) == "table" then
        skillId = eventOrSkillId.skillId or eventOrSkillId.skill
        eventParams = eventOrSkillId.params or eventOrSkillId
    end
    local progression = interfaces.SkillProgression
    local expected = progression and progression.SKILL_USE_TYPES and progression.SKILL_USE_TYPES.Alchemy_CreatePotion
    if skillId == "alchemy" and type(eventParams) == "table" and eventParams.useType == expected
            and (alchemyMenuOpen or closingSession) then
        successfulBrewsPending = successfulBrewsPending + 1
        log("successful-brew signal=" .. tostring(successfulBrewsPending))
    end
end
local progression = interfaces.SkillProgression
if progression ~= nil then
    if type(progression.addSkillUseHandler) == "function" then
        progression.addSkillUseHandler("alchemy", function(first, second)
            if second ~= nil then recordSuccessfulBrew(first, second) else recordSuccessfulBrew("alchemy", first) end
        end)
    elseif type(progression.registerSkillUseHandler) == "function" then
        progression.registerSkillUseHandler({ id = "SkillPerkSystem_BasePack_Alchemy", skill = "alchemy", handler = recordSuccessfulBrew })
    end
end

__basepack_subsystem_result = {
    engineHandlers = {
        onConsume = onConsume,
        onUpdate = onUpdate,
        shouldUpdate = shouldUpdate,
        onFrame = onFrame,
        shouldFrame = shouldFrame,
        onSave = function()
            if not activeCoating then return {} end
            return { coating={coatingId=activeCoating.coatingId,weaponRecordId=activeCoating.weaponRecordId,weaponName=activeCoating.weaponName,potionRecordId=activeCoating.potionRecordId,potionName=activeCoating.potionName} }
        end,
        onLoad = function(data)
            clearCarefulMeasure()
            pendingLoreRequests = {}
            clearDual("load reset", false)
            core.sendGlobalEvent(CLEAR_EVENT, { player = pself, reason = "load reset" })
            savedCoating = type(data) == "table" and data.coating or nil
            restoreFrames = savedCoating and 2 or 0
        end,
    },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        SkillPerkSystem_PerkStateChanged = onPerkStateChanged,
        [LORE_RESULT_EVENT] = onLoreResult,
        [REFUND_RESULT_EVENT] = onRefundResult,
        [COAT_RESULT_EVENT] = onCoatResult,
        [CONVERT_RESULT_EVENT] = onConversionResult,
        [HIT_RESULT_EVENT] = onHitResult,
        SkillPerkSystem_BasePack_DualDistillationPoisonUsed = openPoisonUseMenu,
        SkillPerkSystem_RecordAlchemyApparatus = onRecordApparatus,
    },
}

return __basepack_subsystem_result
