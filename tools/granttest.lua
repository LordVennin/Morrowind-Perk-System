-- Conjuration grant reconciler test. Run from the repository root:
--
--     lua5.4 tools/granttest.lua
--
-- The global script hands out this tree's powers, spells and the bound-armor
-- ward as dynamic records, swapping tiers as perks are bought, refunded or
-- disabled. The engine will not reliably tell us whether the player holds a
-- dynamically created record -- spells:has() answers "no" for ids it does not
-- recognise -- so the reconciler must act blind and still converge. These
-- cases model that, plus record ids that a records[] lookup cannot resolve.

local FAMILIES = {
    undead = { "undead1", "undead2", "undead3" },
    daedra = { "daedra1", "daedra2", "daedra3" },
}
local FAMILY_OF_KEY = {}
for family, keys in pairs(FAMILIES) do
    for _, key in ipairs(keys) do FAMILY_OF_KEY[key] = family end
end

local function newWorld(opts)
    local w = { conjRecords = {}, conjIssued = {}, held = {}, minted = 0 }

    function w.ensureGrantRecord(key)
        -- Trust the cache: records[] does not index dynamic records, so a nil
        -- lookup must not be read as "gone".
        if w.conjRecords[key] ~= nil then return w.conjRecords[key] end
        w.minted = w.minted + 1
        local id = "dyn_" .. key .. "_" .. w.minted
        w.conjRecords[key] = id
        w.conjIssued[id] = FAMILY_OF_KEY[key]
        return id
    end

    function w.spells()
        return {
            add = function(_, id) w.held[id] = true end,
            remove = function(_, id)
                if opts.removeByIdFails then error("cannot remove by id") end
                w.held[id] = nil
            end,
            has = opts.hasLies and function() return false end or nil,
        }
    end

    function w.reconcile(family, desiredIndex)
        local spells = w.spells()
        local keys = FAMILIES[family]
        local desiredId = nil
        if desiredIndex >= 1 and keys[desiredIndex] ~= nil then
            desiredId = w.ensureGrantRecord(keys[desiredIndex])
        end
        for recordId, issuedFamily in pairs(w.conjIssued) do
            if issuedFamily == family and recordId ~= desiredId then
                local ok = pcall(function() spells:remove(recordId) end)
                if not ok and opts.removeByRecordWorks then w.held[recordId] = nil end
            end
        end
        if desiredId ~= nil then
            pcall(function() spells:add(desiredId) end)
        end
    end

    function w.heldFor(family)
        local out = {}
        for id in pairs(w.held) do
            if w.conjIssued[id] == family then out[#out + 1] = id end
        end
        table.sort(out)
        return out
    end

    return w
end

local function assertHolds(w, family, expectedKey, label)
    local held = w.heldFor(family)
    assert(#held <= 1, string.format("%s: %s holds %d records at once (%s)",
        label, family, #held, table.concat(held, ",")))
    if expectedKey == nil then
        assert(#held == 0, label .. ": expected nothing held for " .. family)
    else
        assert(held[1] == w.conjRecords[expectedKey],
            string.format("%s: expected %s, held %s", label, expectedKey, tostring(held[1])))
    end
end

local scenarios = {
    { label = "has() accurate", opts = {} },
    { label = "has() answers no for dynamic ids", opts = { hasLies = true } },
    { label = "remove by id throws, record form works",
      opts = { hasLies = true, removeByIdFails = true, removeByRecordWorks = true } },
}

for _, scenario in ipairs(scenarios) do
    local w, label = newWorld(scenario.opts), scenario.label

    -- Walk one branch all the way up, then back down, then off.
    w.reconcile("undead", 1); assertHolds(w, "undead", "undead1", label .. " / tier up 1")
    w.reconcile("undead", 2); assertHolds(w, "undead", "undead2", label .. " / tier up 2")
    w.reconcile("undead", 3); assertHolds(w, "undead", "undead3", label .. " / tier up 3")
    w.reconcile("undead", 1); assertHolds(w, "undead", "undead1", label .. " / disabled upgrades")
    w.reconcile("undead", 0); assertHolds(w, "undead", nil,       label .. " / refunded")

    -- The reported sequence: max one branch out, then start the other. The
    -- shared upgrade perks mean the new pact arrives already upgraded, and
    -- must not disturb the branch that was already maxed.
    local x = newWorld(scenario.opts)
    x.reconcile("daedra", 1)
    x.reconcile("daedra", 2)
    x.reconcile("daedra", 3)
    assertHolds(x, "daedra", "daedra3", label .. " / daedra maxed")
    x.reconcile("undead", 3)   -- buying the undead pact at full mastery
    assertHolds(x, "undead", "undead3", label .. " / undead granted at full tier")
    assertHolds(x, "daedra", "daedra3", label .. " / daedra kept while undead added")

    -- Records minted in an earlier session must still be removable.
    local y = newWorld(scenario.opts)
    y.reconcile("undead", 1)
    local staleId = y.conjRecords["undead1"]
    y.conjRecords = { undead1 = staleId }        -- reload: cache restored
    y.conjIssued = { [staleId] = "undead" }      -- issued registry restored
    y.reconcile("undead", 2)
    assert(y.held[staleId] == nil, label .. " / stale record from a previous session was not removed")
    assertHolds(y, "undead", "undead2", label .. " / tier swapped after reload")
end

io.write("GRANT RECONCILER TEST PASSED\n")
