local state = {
    balance = 0,
    totalAdded = 0,
    totalSpent = 0,
    nextEntryID = 1,
    history = {},
}

local function sanitizePositiveAmount(amount)
    if type(amount) ~= "number" then
        return nil
    end

    local normalized = math.floor(amount)
    if normalized <= 0 then
        return nil
    end
    return normalized
end

local function pushHistoryEntry(entryType, amount, reason, sourceId, perkId)
    local entry = {
        id = state.nextEntryID,
        type = entryType,
        amount = amount,
        reason = reason,
        sourceId = sourceId,
        perkId = perkId,
    }

    state.nextEntryID = state.nextEntryID + 1
    table.insert(state.history, entry)
    return entry
end

local function addPoints(amount, reason, sourceId)
    local normalizedAmount = sanitizePositiveAmount(amount)
    if normalizedAmount == nil then
        return false, "amount must be a positive number"
    end

    state.balance = state.balance + normalizedAmount
    state.totalAdded = state.totalAdded + normalizedAmount
    return true, pushHistoryEntry("add", normalizedAmount, reason, sourceId, nil)
end

local function spendPoints(amount, perkId)
    local normalizedAmount = sanitizePositiveAmount(amount)
    if normalizedAmount == nil then
        return false, "amount must be a positive number"
    end
    if state.balance < normalizedAmount then
        return false, "insufficient points"
    end

    state.balance = state.balance - normalizedAmount
    state.totalSpent = state.totalSpent + normalizedAmount
    return true, pushHistoryEntry("spend", normalizedAmount, "Perk purchase", nil, perkId)
end

local function exportState()
    return {
        balance = state.balance,
        totalAdded = state.totalAdded,
        totalSpent = state.totalSpent,
        nextEntryID = state.nextEntryID,
        history = state.history,
    }
end

local function importState(data)
    local loaded = type(data) == "table" and data or {}
    state.balance = type(loaded.balance) == "number" and math.max(0, math.floor(loaded.balance)) or 0
    state.totalAdded = type(loaded.totalAdded) == "number" and math.max(0, math.floor(loaded.totalAdded)) or state.balance
    state.totalSpent = type(loaded.totalSpent) == "number" and math.max(0, math.floor(loaded.totalSpent)) or 0
    state.nextEntryID = type(loaded.nextEntryID) == "number" and math.max(1, math.floor(loaded.nextEntryID)) or 1
    state.history = type(loaded.history) == "table" and loaded.history or {}

    if state.nextEntryID <= #state.history then
        state.nextEntryID = #state.history + 1
    end
end

local function getHistory()
    return state.history
end

return {
    addPoints = addPoints,
    spendPoints = spendPoints,
    getAvailablePoints = function()
        return state.balance
    end,
    getTotalAdded = function()
        return state.totalAdded
    end,
    getTotalSpent = function()
        return state.totalSpent
    end,
    getHistory = getHistory,
    exportState = exportState,
    importState = importState,
}
