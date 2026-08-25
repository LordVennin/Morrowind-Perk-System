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
    ward = { "ward1" },
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

-- ---------------------------------------------------------------------------
-- Daily pact gate: a spent pact must not come back through the perk menu.
--
-- Toggling a perk off and on, or moving to another tier, replaces the Power
-- record and hands the player a fresh once-per-day use. The gate keys off our
-- own "spent on day N" record, which lives in save data and is untouched by
-- any of that.
-- ---------------------------------------------------------------------------
do
    local DAILY = { undead = true }
    local held, usedDay = {}, {}

    local function dailyGate(family, tierIndex, currentDay)
        if not DAILY[family] or tierIndex < 1 then return tierIndex end
        local desiredKey = FAMILIES[family][tierIndex]
        if desiredKey ~= nil and held[family] ~= desiredKey and usedDay[family] == currentDay then
            return 0
        end
        return tierIndex
    end

    local function apply(family, tierIndex, currentDay)
        local allowed = dailyGate(family, tierIndex, currentDay)
        held[family] = allowed >= 1 and FAMILIES[family][allowed] or nil
        return allowed
    end

    -- Day 1: buy the pact, get the power, spend it.
    assert(apply("undead", 1, 1) == 1, "pact should be granted when unspent")
    usedDay.undead = 1

    -- Toggling the perk off and back on the same day must not return it.
    assert(apply("undead", 0, 1) == 0, "toggling off should drop the power")
    assert(apply("undead", 1, 1) == 0, "spent pact came back after a toggle")

    -- Nor may a tier upgrade launder a fresh use out of it.
    assert(apply("undead", 2, 1) == 0, "spent pact came back through a tier upgrade")

    -- Next day it returns.
    assert(apply("undead", 2, 2) == 2, "pact should return the following day")

    -- Holding the same tier after spending is untouched: an honest player
    -- keeps the record they already have, and the engine greys it out.
    usedDay.undead = 2
    assert(apply("undead", 2, 2) == 2, "unchanged holding should not be withheld")

    -- A passive family is never gated.
    assert(dailyGate("ward", 1, 2) == 1, "non-daily family must not be gated")
end

-- ---------------------------------------------------------------------------
-- Grand Conjurer refund: a cast must never be able to turn a profit.
--
-- Paying out a share of MAXIMUM magicka let a one-second summon costing a few
-- points refund far more than it consumed, so the cheapest spell in the game
-- refilled the bar when spammed. Refunding a share of what the cast actually
-- cost is bounded by the cost itself.
-- ---------------------------------------------------------------------------
do
    local REFUND_FRACTION = 0.25
    assert(REFUND_FRACTION < 1, "a refund of the full cost would make casting free")

    local function netMagicka(spellCost)
        return REFUND_FRACTION * spellCost - spellCost
    end

    -- Every spell, cheap or expensive, must leave the caster down on the deal.
    for _, spellCost in ipairs({ 1, 3, 5, 12, 40, 120, 400 }) do
        assert(netMagicka(spellCost) < 0,
            string.format("casting a %d-cost spell profits %.2f magicka", spellCost, netMagicka(spellCost)))
    end

    -- The old rule for comparison: a share of a 200-point pool against a
    -- 5-point spell, which is what made spamming worthwhile.
    local oldRefund = 0.10 * 200
    assert(oldRefund - 5 > 0, "sanity: the previous rule really did profit")
end

io.write("GRANT RECONCILER TEST PASSED\n")
