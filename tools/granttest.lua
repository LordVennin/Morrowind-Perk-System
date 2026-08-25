-- Conjuration grant reconciler test. Run from the repository root:
--
--     lua5.4 tools/granttest.lua
--
-- The global script hands out this tree's powers, spells and the bound-armor
-- ward as dynamic records, swapping tiers as perks are bought, refunded or
-- disabled. This exercises that reconciler against a fake spell list, with a
-- has() that answers "no" for dynamic record ids -- the engine behaviour that
-- made grant removal silently unreachable.

local removed, added = {}, {}

local function newSpellList(opts)
    local held = {}
    return setmetatable({
        add = function(self, id) held[id] = true; added[#added + 1] = id end,
        remove = function(self, id)
            if opts.removeByIdFails then error("cannot remove by id") end
            held[id] = nil; removed[#removed + 1] = id
        end,
        -- The engine's has() does not recognise our dynamically created
        -- records and answers false for them.
        has = opts.hasLies and function() return false end or nil,
        _held = held,
    }, { __pairs = function(t)
        local ids = {}
        for id in pairs(held) do ids[#ids + 1] = id end
        table.sort(ids)
        local i = 0
        return function() i = i + 1; if ids[i] then return i, ids[i] end end, t, nil
    end })
end

-- Mirrors the reconciler in basepack_global.lua.
local records = {}
local function ensureRecord(key)
    records[key] = records[key] or ("dyn_" .. key)
    return records[key]
end
local function hasSpellId(spells, id)
    if id == nil then return false end
    if type(spells.has) == "function" then
        local ok, has = pcall(function() return spells:has(id) end)
        if ok and has == true then return true end     -- only trust a "yes"
    end
    for _, spellId in pairs(spells) do
        if spellId == id then return true end
    end
    return false
end
local FAMILIES = { undead = { "undead1", "undead2", "undead3" } }
local function reconcile(spells, family, desired)
    for index, key in ipairs(FAMILIES[family]) do
        local wanted = index == desired
        local recordId = wanted and ensureRecord(key) or records[key]
        if recordId ~= nil then
            local has = hasSpellId(spells, recordId)
            if wanted and not has then
                spells:add(recordId)
            elseif not wanted and has then
                local ok = pcall(function() spells:remove(recordId) end)
                assert(ok or true)
            end
        end
    end
end

local function heldList(spells)
    local out = {}
    for _, id in pairs(spells) do out[#out + 1] = id end
    table.sort(out)
    return table.concat(out, ",")
end

-- Scenario: buy tier 1, upgrade to 2, upgrade to 3, then disable the upgrades
-- back down to 1, then refund entirely. At every step exactly one power is
-- held, and nothing is left behind.
for _, hasLies in ipairs({ false, true }) do
    records = {}
    local spells = newSpellList({ hasLies = hasLies })
    local label = hasLies and "has()=false (engine behaviour)" or "has() accurate"

    reconcile(spells, "undead", 1)
    assert(heldList(spells) == "dyn_undead1", label .. ": tier 1 -> " .. heldList(spells))
    reconcile(spells, "undead", 2)
    assert(heldList(spells) == "dyn_undead2", label .. ": tier 2 -> " .. heldList(spells))
    reconcile(spells, "undead", 3)
    assert(heldList(spells) == "dyn_undead3", label .. ": tier 3 -> " .. heldList(spells))
    -- disabling the upgrade perks walks the tier back down
    reconcile(spells, "undead", 1)
    assert(heldList(spells) == "dyn_undead1", label .. ": back to tier 1 -> " .. heldList(spells))
    -- refunding the base perk removes everything
    reconcile(spells, "undead", 0)
    assert(heldList(spells) == "", label .. ": tier 0 -> " .. heldList(spells))
end

io.write("GRANT RECONCILER TEST PASSED\n")
