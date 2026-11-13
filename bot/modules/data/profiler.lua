-- profiler.lua (lives in modules/data/)
-- Where the frame time goes (the user, 2026-11-11: the dev bot runs ~4.5x
-- where the user bot ran ~12x with the same BizHawk settings). Turned on by
-- a file "profile_on.txt" next to launcher.lua; off, nothing of this runs.
--
-- Every REPORT_SECONDS it appends to its file:
--   * frames and fps;
--   * the time inside emu.frameadvance - the emulator, and what BizHawk
--     calls back during the frame: the ROM hooks (each timed, with how many
--     calls and how many were for the right bank) and the frame-end work;
--   * the time between frames - the bot's own Lua - with its busiest lines
--     (sampled every SAMPLE_EVERY Lua instructions).
-- The timing itself costs a little (two clock reads per hook call): the
-- hook numbers are an upper bound.

local M = {}

M.REPORT_SECONDS = 60
M.SAMPLE_EVERY = 20000
M.TOP_LINES = 15

local clock = os.clock
local file = nil
local started, frames, inside = 0, 0, 0
local hooks = {}        -- name -> {calls, fired, time}
local sections = {}     -- name -> {calls, time}
local lines = {}        -- "source:line" -> samples
local samplesTotal = 0
local inFrame = false
local lastReport = 0

local function reset()
    started, frames, inside = clock(), 0, 0
    -- (in place: each wrapped hook keeps its own entry)
    for _, h in pairs(hooks) do h.calls, h.fired, h.time = 0, 0, 0 end
    sections, lines, samplesTotal = {}, {}, 0
end

local function write(text)
    if not file then return end
    local f = io.open(file, "a")
    if not f then return end
    f:write(text, "\n")
    f:close()
end

-- A ROM hook's callback, timed: calls (every time the CPU ran that address,
-- in any bank) and the time in it.
function M.wrap_hook(name, fn)
    local h = hooks[name] or {calls = 0, fired = 0, time = 0}
    hooks[name] = h
    return function(...)
        local t = clock()
        h.calls = h.calls + 1
        fn(...)
        h.time = h.time + (clock() - t)
    end
end
-- The hook's own action (the right bank): how often it really fired.
function M.count_fire(name, fn)
    return function(...)
        local h = hooks[name]
        if h then h.fired = h.fired + 1 end
        return fn(...)
    end
end
-- Any other function, timed under a name.
function M.timed(name, fn)
    return function(...)
        local sct = sections[name] or {calls = 0, time = 0}
        sections[name] = sct
        local t = clock()
        sct.calls = sct.calls + 1
        local r = table.pack(fn(...))
        sct.time = sct.time + (clock() - t)
        return table.unpack(r, 1, r.n)
    end
end

local function ms(x) return string.format("%.1f", x * 1000) end

function M.report()
    local wall = clock() - started
    if wall <= 0 or frames == 0 then return end
    local hookTime, hookCalls = 0, 0
    for _, h in pairs(hooks) do hookTime, hookCalls = hookTime + h.time, hookCalls + h.calls end
    local secTime = 0
    for _, sct in pairs(sections) do secTime = secTime + sct.time end
    local core = inside - hookTime - secTime
    local script = wall - inside
    local out = {}
    out[#out + 1] = string.format("== %s - %.0f s, %d frames, %.0f fps (%.1fx); per frame %s ms",
        os.date("%Y-%m-%d %H:%M:%S"), wall, frames, frames / wall, frames / wall / 59.73, ms(wall / frames))
    out[#out + 1] = string.format("   emulator + drawing %5.1f%%  (%s ms/frame)", 100 * core / wall, ms(core / frames))
    out[#out + 1] = string.format("   ROM hooks          %5.1f%%  (%s ms/frame, %d calls/frame)", 100 * hookTime / wall, ms(hookTime / frames), math.floor(hookCalls / frames + 0.5))
    out[#out + 1] = string.format("   frame-end work     %5.1f%%  (%s ms/frame)", 100 * secTime / wall, ms(secTime / frames))
    out[#out + 1] = string.format("   bot Lua            %5.1f%%  (%s ms/frame)", 100 * script / wall, ms(script / frames))
    -- (how many ROM hooks BizHawk has right now - data/memory.lua's groups)
    local okM, Mem = pcall(require, "data.memory")
    if okM and type(Mem) == "table" and Mem.CountHooks then
        local on, all = Mem.CountHooks()
        out[#out + 1] = string.format("   ROM hooks registered now: %d of %d", on, all)
    end
    local hs = {}
    for name, h in pairs(hooks) do if h.calls > 0 then hs[#hs + 1] = {name, h} end end
    table.sort(hs, function(a, b) return a[2].time > b[2].time end)
    if #hs > 0 then out[#out + 1] = "   hooks, busiest first (calls, for the right bank, time):" end
    for i = 1, math.min(#hs, 25) do
        local name, h = hs[i][1], hs[i][2]
        out[#out + 1] = string.format("     %-34s %9d %7d %8s ms", name, h.calls, h.fired, ms(h.time))
    end
    for name, sct in pairs(sections) do
        out[#out + 1] = string.format("   section %-30s %8d calls %8s ms", name, sct.calls, ms(sct.time))
    end
    local ls = {}
    for k, n in pairs(lines) do ls[#ls + 1] = {k, n} end
    table.sort(ls, function(a, b) return a[2] > b[2] end)
    if samplesTotal > 0 then out[#out + 1] = string.format("   busiest Lua lines (%d samples):", samplesTotal) end
    for i = 1, math.min(#ls, M.TOP_LINES) do
        out[#out + 1] = string.format("     %5.1f%%  %s", 100 * ls[i][2] / samplesTotal, ls[i][1])
    end
    write(table.concat(out, "\n"))
end

-- Called around every frame (the wrapped emu.frameadvance).
local function after_frame()
    frames = frames + 1
    local now = clock()
    if now - lastReport >= M.REPORT_SECONDS then
        if lastReport > 0 then pcall(M.report) end
        lastReport = now
        reset()
    end
end

-- path: the report file. Wraps emu.frameadvance (before anything keeps its
-- own copy of it) and starts the line sampler.
function M.start(path)
    file = path
    write(string.format("== profiler on, %s", os.date("%Y-%m-%d %H:%M:%S")))
    reset()
    lastReport = clock()
    -- (BizHawk keeps globals between script runs: the real one is kept
    -- once, so wrappers never stack - launcher.lua puts it back when off)
    local orig = AutocrystalOrigFrameadvance or emu.frameadvance
    AutocrystalOrigFrameadvance = orig
    local ok = pcall(function()
        emu.frameadvance = function(...)
            local t = clock()
            inFrame = true
            orig(...)
            inFrame = false
            inside = inside + (clock() - t)
            after_frame()
        end
    end)
    if not ok then write("   (couldn't wrap emu.frameadvance - frame split unknown)") end
    -- (the busiest lines of the bot's own Lua: a sample every SAMPLE_EVERY
    -- instructions, the line running then)
    pcall(debug.sethook, function()
        local info = debug.getinfo(2, "Sl")
        if not info then return end
        local src = (info.short_src or "?"):match("[^/\\]+$") or "?"
        local k = (inFrame and "[in frame] " or "") .. src .. ":" .. tostring(info.currentline)
        lines[k] = (lines[k] or 0) + 1
        samplesTotal = samplesTotal + 1
    end, "", M.SAMPLE_EVERY)
end

-- For tests.
M._state = function() return {frames = frames, inside = inside, hooks = hooks, sections = sections, lines = lines} end
M._after_frame = after_frame

return M
