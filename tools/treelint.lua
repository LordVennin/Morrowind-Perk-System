-- Perk tree layout lint. Run from the repository root:
--
--     lua5.4 tools/treelint.lua
--
-- Loads every perk definition module and checks, per tab, that no two node
-- boxes overlap or crowd each other. Node boxes render 178px wide (selected
-- width 174 plus border) and 26px tall on a 140px row grid, so nodes on the
-- same row need at least MIN_CENTER_GAP between centers.

local NODE_WIDTH = 178
local NODE_HEIGHT = 26
local MIN_CENTER_GAP = 200      -- hard failure: boxes visually collide or touch
local WARN_CENTER_GAP = 220     -- warning: legal but cramped

local modules = {}
do
    local pipe = io.popen('ls SkillPerkSystem_BasePack/perks/*/*.lua')
    for line in pipe:lines() do
        local name = line:match("perks/([%w_]+)/([%w_]+)%.lua$")
        if name and not line:match("_effect%.lua$") and not line:match("_config%.lua$") then
            modules[#modules + 1] = line
        end
    end
    pipe:close()
end

-- The tree viewport is ~536px wide. A span past three columns at 220px means
-- some panning; well past it means the outer columns sit half-off-screen and
-- read as clipped. Warn at the convention, fail where it becomes unusable.
local WARN_TREE_SPAN = 440
local MAX_TREE_SPAN = 600

local failures, warnings = 0, 0
for _, path in ipairs(modules) do
    local chunk = assert(loadfile(path))
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" and type(data.perks) == "table" then
        local byTab = {}
        for _, perk in ipairs(data.perks) do
            local tab = tostring(perk.tab or "?")
            byTab[tab] = byTab[tab] or {}
            table.insert(byTab[tab], perk)
        end
        for tab, perks in pairs(byTab) do
            local minX, maxX = perks[1].x, perks[1].x
            for _, perk in ipairs(perks) do
                minX = math.min(minX, tonumber(perk.x) or 0)
                maxX = math.max(maxX, tonumber(perk.x) or 0)
            end
            local span = maxX - minX
            if span > MAX_TREE_SPAN then
                failures = failures + 1
                io.write(string.format("TOO WIDE %s: columns span %dpx (x=%d..%d), max is %d\n",
                    tab, span, minX, maxX, MAX_TREE_SPAN))
            elseif span > WARN_TREE_SPAN then
                warnings = warnings + 1
                io.write(string.format("wide     %s: columns span %dpx (convention is %d)\n",
                    tab, span, WARN_TREE_SPAN))
            end
            for i = 1, #perks do
                for j = i + 1, #perks do
                    local a, b = perks[i], perks[j]
                    local dx = math.abs((tonumber(a.x) or 0) - (tonumber(b.x) or 0))
                    local dy = math.abs((tonumber(a.y) or 0) - (tonumber(b.y) or 0))
                    if dy < NODE_HEIGHT then  -- same visual row
                        if dx < MIN_CENTER_GAP then
                            failures = failures + 1
                            io.write(string.format("OVERLAP  %s: %s (x=%d) and %s (x=%d) are %dpx apart on row y=%d (need >= %d)\n",
                                tab, a.id, a.x, b.id, b.x, dx, a.y, MIN_CENTER_GAP))
                        elseif dx < WARN_CENTER_GAP then
                            warnings = warnings + 1
                            io.write(string.format("cramped  %s: %s and %s are %dpx apart on row y=%d\n",
                                tab, a.id, b.id, dx, a.y))
                        end
                    end
                end
            end
        end
    end
end

if failures > 0 then
    io.write(string.format("TREE LINT FAILED: %d overlap(s), %d warning(s)\n", failures, warnings))
    os.exit(1)
end
io.write(string.format("TREE LINT PASSED (%d warning(s))\n", warnings))
