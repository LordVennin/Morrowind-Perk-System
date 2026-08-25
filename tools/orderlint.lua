-- Undeclared/forward call lint. Run from the repository root:
--
--     lua5.4 tools/orderlint.lua
--
-- Lua resolves an unknown name as a global, so calling a helper that is
-- declared further down the file -- or one that was deleted out from under its
-- callers -- compiles cleanly and fails at runtime with "attempt to call a nil
-- value". luac -p cannot see it, and it has shipped three separate times here:
-- the perk menu's v2, the global script's effectTypeId, and the conjuration
-- runtime's restoreMagicka.
--
-- Only call sites are considered (`name(`), never field or method calls, and
-- never bare value references, which keeps the check free of table-key noise.

local BUILTIN = {}
for name in ([[print pairs ipairs type tostring tonumber pcall xpcall error assert
    require select setmetatable getmetatable rawget rawset rawequal rawlen next
    unpack load loadstring loadfile dofile collectgarbage math string table os io
    coroutine debug utf8 _G _VERSION]]):gmatch("%S+") do
    BUILTIN[name] = true
end

local KEYWORD = {}
for name in ([[and break do else elseif end false for function goto if in local nil
    not or repeat return then true until while]]):gmatch("%S+") do
    KEYWORD[name] = true
end

local function codeOnly(line)
    line = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    local commentAt = line:find("%-%-")
    if commentAt then line = line:sub(1, commentAt - 1) end
    return line
end

local function scanFiles()
    local files = {}
    local pipe = io.popen("ls SkillPerkSystem/*.lua SkillPerkSystem_BasePack/*.lua "
        .. "SkillPerkSystem_BasePack/runtime/*.lua SkillPerkSystem_BasePack/runtime/player/*.lua 2>/dev/null")
    for path in pipe:lines() do files[#files + 1] = path end
    pipe:close()
    return files
end

local failures = 0
for _, path in ipairs(scanFiles()) do
    local lines = {}
    for line in io.lines(path) do lines[#lines + 1] = line end

    -- Where each name becomes available, at any indentation: locals, function
    -- declarations, and plain assignments to a forward-declared local.
    local declaredAt, hasTopLevelDo = {}, false
    for index, line in ipairs(lines) do
        local code = codeOnly(line)
        if code:match("^do%s*$") then hasTopLevelDo = true end
        for _, name in ipairs({
            code:match("^%s*local function ([%w_]+)"),
            code:match("^%s*local ([%w_]+)%s*="),
            code:match("^%s*function ([%w_]+)%s*%("),
            code:match("^%s*([%w_]+)%s*=%s*function"),
        }) do
            if declaredAt[name] == nil or index < declaredAt[name] then
                declaredAt[name] = index
            end
        end
        -- comma-separated locals: local a, b, c = ...
        local names = code:match("^%s*local ([%w_,%s]+)=")
        if names then
            for name in names:gmatch("[%w_]+") do
                if declaredAt[name] == nil then declaredAt[name] = index end
            end
        end
        -- bare forward declaration: local name  (assigned further down)
        local bare = code:match("^%s*local ([%w_,%s]+)%s*$")
        if bare then
            for name in bare:gmatch("[%w_]+") do
                if declaredAt[name] == nil then declaredAt[name] = index end
            end
        end
        -- loop variables are in scope for the body that follows
        local loopVars = code:match("^%s*for%s+([%w_,%s]+)%s+in%s")
            or code:match("^%s*for%s+([%w_]+)%s*=")
        if loopVars then
            for name in loopVars:gmatch("[%w_]+") do
                if declaredAt[name] == nil then declaredAt[name] = index end
            end
        end
        -- parameters are in scope for the body that follows
        local params = code:match("function%s*[%w_.:]*%s*%(([^)]*)%)")
        if params then
            for name in params:gmatch("[%w_]+") do
                if declaredAt[name] == nil then declaredAt[name] = index end
            end
        end
    end

    for index, line in ipairs(lines) do
        local code = codeOnly(line)
        if not code:match("^%s*local function") and not code:match("^%s*function") then
            for name in code:gmatch("([%w_%.:]+)%s*%(") do
                -- Dotted or method calls come from a table, not a bare name.
                if not name:find("[%.:]") and not BUILTIN[name] and not KEYWORD[name]
                        and not name:match("^%d") then
                    local decl = declaredAt[name]
                    if decl == nil then
                        -- Unknown to this file: could legitimately come from a
                        -- required module table, so only flag a bare call.
                        if not code:find("[%w_]%.".. name) then
                            io.write(string.format("%s:%d: calls '%s', which is never declared in this file\n",
                                path, index, name))
                            failures = failures + 1
                        end
                    elseif decl > index and not hasTopLevelDo then
                        io.write(string.format("%s:%d: calls '%s' before its declaration at line %d\n",
                            path, index, name, decl))
                        failures = failures + 1
                    end
                end
            end
        end
    end
end

if failures > 0 then
    io.write(string.format("ORDER LINT FAILED: %d problem(s)\n", failures))
    os.exit(1)
end
io.write("ORDER LINT PASSED\n")
