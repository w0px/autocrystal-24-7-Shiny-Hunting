-- overlay_feed.lua (lives in data/)
-- Keeps the stream overlay (overlay/scene.html, via overlay/overlay_relay.ps1)
-- up to date: the current encounter, the last few, recent shinies with their
-- DVs, what lives where you stand, the game's clock, the lifetime numbers -
-- and the bot's lines.
--
-- Fed from two places every module already goes through:
--   Gui.update_last_encounter -> M.note_encounter (each encounter shown)
--   launcher.lua's main loop  -> M.tick (clock, place, table, totals)
-- Modules can also talk to viewers directly: OverlayFeed.say("...").
-- Nothing here may stop or slow the bot: every call is cheap, and the
-- posts themselves go through data/overlay.lua's back-off.
--
-- No session numbers on purpose: the stream runs for months, so a session
-- (or its best DVs) means nothing to a viewer.

local Overlay = require("data.overlay")

local M = {}

-- The launcher's window state (for the Auto-Catch species filter); set by launcher.lua.
M.hud = nil

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
-- Recent shinies WITH their DVs (shiny_history.txt keeps only when/which):
-- one per line, newest first: time|species|atk|def|spe|spc|item
-- (OVERLAY_SHINIES_FILE: tests point it elsewhere - the real list must never get their pretend shinies)
local SHINIES_FILE = OVERLAY_SHINIES_FILE or (script_dir .. "overlay_shinies.txt")
local KEEP_SHINIES = 10
-- The current one plus the five before it (scene.html lists those five).
local KEEP_ENCOUNTERS = 6
local TICK_SECONDS = 5

local current, encounters, shinies = nil, {}, nil
local streak = {species = nil, count = 0}
-- Numbers each encounter, so the overlay can tell a new one from a repeat
-- (it slides the list along, and keeps each row's picture animating).
local nextId = 1
local dirty, lastPost = true, 0
-- When the log last got a line, and the phone as last read (for the quiet-time note).
local lastSaid, lastPhone = os.time(), nil

local function name_of(id)
    return (PokemonNames and PokemonNames[id]) or ("#" .. tostring(id))
end

local function load_shinies()
    shinies = {}
    local f = io.open(SHINIES_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local t, s, a, d, sp, sc, item = line:match("^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
        if t then
            shinies[#shinies + 1] = {time = tonumber(t), species = tonumber(s), atk = tonumber(a), def = tonumber(d),
                spe = tonumber(sp), spc = tonumber(sc), item = item ~= "" and item or nil}
        end
    end
    f:close()
end

local function save_shinies()
    local f = io.open(SHINIES_FILE, "w")
    if not f then return end
    for _, m in ipairs(shinies) do
        f:write(string.format("%d|%d|%d|%d|%d|%d|%s\n", m.time, m.species, m.atk, m.def, m.spe, m.spc,
            (m.item or ""):gsub("[|\n]", " ")))
    end
    f:close()
end

-- The shinies shown: ours (with DVs), topped up from shiny_history.txt for
-- ones from before this file existed (DVs unknown there).
local function recent_shinies()
    if shinies == nil then load_shinies() end
    local out = {}
    for _, m in ipairs(shinies) do
        if #out >= 3 then break end
        out[#out + 1] = m
    end
    if #out < 3 then
        local ok, History = pcall(require, "data.shiny_history")
        if ok and History then
            if not History.loaded then pcall(History.load) end
            for _, h in ipairs(History.entries or {}) do
                if #out >= 3 then break end
                local known = false
                for _, m in ipairs(out) do
                    if m.species == h.species and math.abs(m.time - h.time) < 120 then known = true break end
                end
                if h.species and not known then out[#out + 1] = {time = h.time, species = h.species} end
            end
        end
    end
    return out
end

-- Species the user is after: the Auto-Catch species filter (names or
-- numbers), as species numbers.
local function targets()
    local out = {}
    if M.targetList then
        for i = 1, math.min(#M.targetList, 12) do out[i] = M.targetList[i] end   -- (the page names 2, counts the rest)
        return out
    end
    if not (Gui and Gui.catch_species_filter and M.hud) then return out end
    local ok, tokens = pcall(Gui.catch_species_filter, M.hud)
    if not ok or tokens == nil then return out end
    for _, token in ipairs(tokens) do
        local id = tonumber(token)
        if not id then
            local lower = token:lower()
            for i = 1, 251 do
                if name_of(i):lower() == lower then id = i break end
            end
        end
        if id and id >= 1 and id <= 251 and #out < 5 then out[#out + 1] = id end
    end
    return out
end

-- The game's time of day: wTimeOfDay (0 morning, 1 day, 2 night).
local TIMES = {[0] = "MORN", [1] = "DAY", [2] = "NITE"}
local function time_of_day()
    local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
    if region == 0x4A or region == 0x4B then return nil end
    local addr = (version == 0x54 and 0xD269) or ((version == 0x55 or version == 0x58) and 0xD157) or nil
    if not addr then return nil end
    local ok, v = pcall(function() return require("data.frame_search").wram(addr) end)
    return ok and TIMES[v] or nil
end

-- The Game Assistant (live_view.lua) already reads the game's encounter
-- tables and its clock; borrowed from it.
local function rows_of(rows)
    local list = {}
    for i = 1, math.min(#(rows or {}), 7) do
        local r = rows[i]
        list[i] = {species = r.species, odds = r.odds, low = r.low, high = r.high}
    end
    return list
end

-- Rows of {odds, species, level} (a tree table) as one row per species:
-- chances summed, level range, likeliest first.
local function per_species(slots)
    local rows, seen = {}, {}
    for _, s in ipairs(slots or {}) do
        local r = seen[s.species]
        if r == nil then
            r = {species = s.species, odds = 0, low = s.level, high = s.level}
            seen[s.species] = r
            rows[#rows + 1] = r
        end
        r.odds = r.odds + s.odds
        r.low, r.high = math.min(r.low, s.level), math.max(r.high, s.level)
    end
    table.sort(rows, function(a, b)
        if a.odds ~= b.odds then return a.odds > b.odds end
        return a.species < b.species
    end)
    return rows
end

-- Fishing (the Fishing module): the rod on Select, its table by day and by
-- night (morning fishes as day). No rod registered: an empty list.
local ROD_NAMES = {"OLD ROD", "GOOD ROD", "SUPER ROD"}
local function fishing()
    if not LiveView.fishing_tables then return nil end
    local ok, f = pcall(LiveView.fishing_tables)
    if not ok then return nil end
    local out = {kind = "fish", now = time_of_day(), list = {}}
    local rod = f and f.rod
    if rod then
        out.rod = ROD_NAMES[rod]
        local day, nite = rows_of(f.day[rod]), rows_of(f.nite and f.nite[rod] or f.day[rod])
        out.morn, out.day, out.nite = day, day, nite
        out.list = out.now == "NITE" and nite or day
    end
    return out
end

-- Headbutt (the Headbutt module): the tree it faces - its table and
-- "RARE"/"COMMON"/"WEAK" - or the map's common table until it faced one.
local function trees()
    local okReq, TreeOverlay = pcall(require, "data.tree_overlay")
    if not okReq or not TreeOverlay.facing_tree then return nil end
    local ok, kind, rows = pcall(TreeOverlay.facing_tree)
    if not ok then return nil end
    return {kind = "tree", tree = kind and kind:upper() or nil, list = rows_of(per_species(rows))}
end

-- What lives here: kind/list = what the running module meets right now -
-- the grass at this time of day or the water while surfing (Wild and the
-- rest), the rod's table (Fishing), the tree's (Headbutt) - plus, where it
-- changes with the clock, every time of day, so the overlay can switch.
local function here()
    if not LiveView then return nil end
    local mode = ActiveModuleName
    if mode == "fishing" then
        local f = fishing()
        if f then return f end
    elseif mode == "headbutt" then
        local t = trees()
        if t then return t end
    end
    if LiveView.encounter_tables then
        local ok, t = pcall(LiveView.encounter_tables)
        if ok and t then
            local out = {morn = rows_of(t[0]), day = rows_of(t[1]), nite = rows_of(t[2]), water = rows_of(t.water),
                now = TIMES[t.now]}
            out.kind = t.surfing and "surf" or "walk"
            out.list = t.surfing and out.water or out[({[0] = "morn", [1] = "day", [2] = "nite"})[t.now] or "day"]
            return out
        end
    end
    if not LiveView.encounters_here then return nil end
    local ok, rows, kind = pcall(LiveView.encounters_here)
    if not ok or rows == nil then return nil end
    return {kind = kind, list = rows_of(rows)}
end

-- The phone: minutes until the game's next try at a call (CheckPhoneCall
-- rolls 50% each time its timer runs out - 20, 10, 5, then 3 minutes after
-- a call). wReceiveCallDelay_MinsRemaining is what was left at the last
-- check, wReceiveCallDelay_StartTime's minute when that was. Only when a
-- trainer's number is in the phone (Mom, the bike shop, Bill and Elm,
-- contacts 1-4, never call at random). English Crystal and Gold/Silver.
local PHONE = {
    crystal = {mins = 0xD465, start = 0xD466, list = 0xDC7C},
    gs = {mins = 0xD18C, start = 0xD18D, list = 0xD9C6},
}
-- The trainers whose numbers can be in the phone (constants/phone_constants.asm:
-- the contact numbers, 5 on; the gaps are unused numbers).
local CALLERS = {
    [5] = "JACK", [6] = "BEVERLY", [7] = "HUEY", [11] = "GAVEN", [12] = "BETH", [13] = "JOSE",
    [14] = "REENA", [15] = "JOEY", [16] = "WADE", [17] = "RALPH", [18] = "LIZ", [19] = "ANTHONY",
    [20] = "TODD", [21] = "GINA", [22] = "IRWIN", [23] = "ARNIE", [24] = "ALAN", [26] = "DANA",
    [27] = "CHAD", [28] = "DEREK", [29] = "TULLY", [30] = "BRENT", [31] = "TIFFANY", [32] = "VANCE",
    [33] = "WILTON", [34] = "KENJI", [35] = "PARRY", [36] = "ERIN",
}
local function phone(clockNow)
    local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
    if region == 0x4A or region == 0x4B then return nil end
    local a = (version == 0x54 and PHONE.crystal) or ((version == 0x55 or version == 0x58) and PHONE.gs) or nil
    if not a or not clockNow then return nil end
    local ok, out = pcall(function()
        local wram = require("data.frame_search").wram
        local callers = {}
        for i = 0, 9 do
            local who = CALLERS[wram(a.list + i)]
            if who then callers[#callers + 1] = who end
        end
        if #callers == 0 then return nil end
        local left = wram(a.mins)
        local since = (clockNow.minutes - wram(a.start + 2)) % 60
        -- (no call comes on a map without phone service - a cave, a gym:
        -- data/phone_service.lua, Crystal's numbering; wMapGroup/wMapNumber)
        local noSignal = nil
        if a == PHONE.crystal then
            local okS, NoPhone = pcall(require, "data.phone_service")
            noSignal = okS and NoPhone[wram(0xDCB5) .. ":" .. wram(0xDCB6)] or nil
        end
        return {mins = math.max(0, left - since), callers = callers, noSignal = noSignal}
    end)
    return ok and out or nil
end

-- The chat window's fixed lines: what the bot is working towards and what
-- it does next (a planner sets these; nil hides them).
M.goal, M.next, M.phase = nil, nil, nil
function M.set_goal(text) M.goal = text; dirty = true end
function M.set_next(text) M.next = text; dirty = true end
-- The info bar's TARGET: the species the hunt is after now (numbers); {} or
-- nil = "ANY SHINY". Set by the playthrough's hunt (data/hunt.lua).
function M.set_targets(ids)
    local key = table.concat(ids or {}, ",")
    if key == (M.targetKey or "") then return end
    M.targetKey = key
    M.targetList = (ids and #ids > 0) and ids or nil
    dirty = true
end
-- The encounter table's coloured icons: the species the playthrough needs
-- no more of (data/hunt.lua's done_species) - nil = the old stats file's
-- "caught shiny" list (the 1.2.0 hunting modes).
M.doneList = nil
function M.set_done(ids)
    local key = table.concat(ids or {}, ",")
    if ids and key == (M.doneKey or "") and M.doneList then return end
    M.doneKey = key
    M.doneList = ids
    dirty = true
end
-- The info bar's "CURRENT PHASE UNIQUE SHINIES 2/26" (a planner sets it).
function M.set_phase(caught, total) M.phase = {caught = caught, total = total}; dirty = true end

-- The big news, pinned at the top of the log in a box for PIN_HOURS (the
-- user, 2026-11-10: "a sticky event for something big - a shiny or perfect
-- DVs - it stays for like 12h and gets highlighted"). One at a time: a new
-- one takes the box unless the one there outranks it (a shiny over DVs) and
-- is still up. Kept in a file, so a restart doesn't drop it:
-- time|rank|species|text (OVERLAY_PIN_FILE: tests point it elsewhere).
M.PIN_HOURS = 8       -- (12 until the user, 2026-11-10: "or lets do 8h")
local PIN_FILE = OVERLAY_PIN_FILE or (script_dir .. "overlay_pin.txt")
local pinned = false          -- (false: not read yet; nil: none)
local function load_pin()
    pinned = nil
    local f = io.open(PIN_FILE, "r")
    if not f then return end
    local t, r, sp, text = (f:read("l") or ""):match("^(%d+)|(%d+)|(%d*)|(.*)$")
    f:close()
    if t then pinned = {time = tonumber(t), rank = tonumber(r), species = tonumber(sp), text = text} end
end
local function pin_up()
    if pinned == false then load_pin() end
    if pinned and os.time() - pinned.time < M.PIN_HOURS * 3600 then return pinned end
    return nil
end
function M.pin(text, rank, species)
    rank = rank or 1
    local now = pin_up()
    if now and now.rank > rank then return false end
    pinned = {time = os.time(), rank = rank, species = tonumber(species), text = tostring(text):gsub("[\r\n]", " ")}
    local f = io.open(PIN_FILE, "w")
    if f then f:write(string.format("%d|%d|%s|%s\n", pinned.time, pinned.rank, pinned.species or "", pinned.text)); f:close() end
    dirty = true
    return true
end

-- The % of a species in what the bot meets here now (the encounter table
-- the overlay shows), or nil: not met here / not known.
function M.odds_here(species)
    local h = here()
    if not (h and h.list) then return nil end
    local sum = nil
    for _, r in ipairs(h.list) do if r.species == species then sum = (sum or 0) + (r.odds or 0) end end
    return sum
end

local function clock()
    if not (LiveView and LiveView.game_clock) then return nil end
    local ok, day, hours, minutes = pcall(LiveView.game_clock)
    if not ok or day == nil then return nil end
    return {day = day, hours = hours, minutes = minutes}
end

local function build_state()
    local now = clock()
    local s = {
        location = AutocrystalCurrentLocation,
        time_of_day = time_of_day(),
        clock = now,
        phone = (function() lastPhone = phone(now); return lastPhone end)(),
        here = here(),
        current = current,
        encounters = encounters,
        -- (the same species again and again: "x7" by the current one from 3
        -- on - the user, 2026-11-11)
        streak = streak.count >= 3 and {species = streak.species, n = streak.count} or nil,
        recent_shinies = recent_shinies(),
        targets = targets(),
        pin = (function() local p = pin_up(); return p and {text = p.text, time = p.time, till = p.time + M.PIN_HOURS * 3600, rank = p.rank, species = p.species} or nil end)(),
        goal = M.goal,
        next = M.next,
        phase = M.phase,
        runtime = M.runtime,      -- seconds the bot has run, all sessions (the launcher sets it)
        joey = M.joey,            -- money won from Joey's rematches, all sessions (the launcher sets it)
    }
    if Stats then
        s.total = Stats.totalEncounters
        s.shinies = Stats.totalShinies
        s.since_shiny = Stats.encountersSinceShiny
        -- Species caught shiny already (the encounter table colours their icons).
        if Stats.caughtSpecies and not M.doneList then
            local caught = {}
            for id in pairs(Stats.caughtSpecies) do caught[#caught + 1] = id end
            table.sort(caught)
            if #caught > 0 then s.caught = caught end
        end
        if Stats.session_encounters_per_hour then
            local ok, rate = pcall(Stats.session_encounters_per_hour)
            if ok and rate then s.per_hour = math.floor(rate + 0.5) end
        end
    end
    -- (the playthrough: the species it needs no more of)
    if M.doneList then s.caught = M.doneList end
    pcall(M.cards, s)
    return s
end

-- The overlay's cards (the user, 2026-11-10: the luck board and the most
-- met take turns with the encounter table, the shiny history with the
-- recent shinies):
--   luck     the species most over the odds first: met / (8192 x (its
--            shinies + 1)) - 2.0 is twice the odds met without one
--   most     the most met, with their share of every encounter
--   history  the shinies, newest first, and how many encounters each
--            took (data/shiny_history.lua); history_stats over all kept
M.CARD_ROWS, M.HISTORY_ROWS = 12, 20
function M.cards(s)
    local st = Stats
    if st and st.speciesEncounters then
        local rows, total = {}, 0
        for id, met in pairs(st.speciesEncounters) do
            if type(id) == "number" and met and met > 0 then
                total = total + met
                local sh = (st.speciesShinies and st.speciesShinies[id]) or 0
                rows[#rows + 1] = {species = id, met = met, shinies = sh, x = met / (8192 * (sh + 1))}
            end
        end
        table.sort(rows, function(a, b) if a.x ~= b.x then return a.x > b.x end; return a.species < b.species end)
        local luck = {}
        for i = 1, math.min(M.CARD_ROWS, #rows) do
            local r = rows[i]
            luck[i] = {species = r.species, met = r.met, shinies = r.shinies, x = math.floor(r.x * 10 + 0.5) / 10}
        end
        table.sort(rows, function(a, b) if a.met ~= b.met then return a.met > b.met end; return a.species < b.species end)
        local most = {}
        for i = 1, math.min(M.CARD_ROWS, #rows) do
            local r = rows[i]
            most[i] = {species = r.species, met = r.met, pct = total > 0 and math.floor(r.met * 1000 / total + 0.5) / 10 or 0}
        end
        if #rows > 0 then s.luck, s.most, s.most_total = luck, most, total end
    end
    local okH, H = pcall(require, "data.shiny_history")
    if okH and type(H) == "table" then
        if not H.loaded and H.load then pcall(H.load) end
        local hist, sum, n, best, worst = {}, 0, 0, nil, nil
        for i, e in ipairs(H.entries or {}) do
            if i <= M.HISTORY_ROWS then hist[#hist + 1] = {species = e.species, took = e.encounters, time = e.time} end
            local t = e.encounters or 0
            if t > 0 then
                sum, n = sum + t, n + 1
                best = (not best or t < best) and t or best
                worst = (not worst or t > worst) and t or worst
            end
        end
        if #hist > 0 then
            s.history = hist
            if n > 0 then s.history_stats = {count = n, avg = math.floor(sum / n + 0.5), best = best, worst = worst} end
        end
    end
end

local function post()
    lastPost = os.time()
    dirty = false
    Overlay.state(build_state())
end

-- From Gui.update_last_encounter: one encounter, as the panel shows it.
function M.note_encounter(species, atk, def, spe, spc, isShiny, itemName)
    if type(species) ~= "number" or species < 1 or species > 251 then return end
    local item = (itemName and itemName ~= "(no item)" and itemName ~= "-") and itemName or nil

    streak.count = (species == streak.species) and streak.count + 1 or 1
    streak.species = species

    current = {species = species, atk = atk, def = def, spe = spe, spc = spc, item = item, shiny = isShiny or nil,
        streak = streak.count}
    table.insert(encounters, 1, {id = nextId, species = species, atk = atk, def = def, spe = spe, spc = spc, item = item, shiny = isShiny or nil})
    nextId = nextId + 1
    while #encounters > KEEP_ENCOUNTERS do table.remove(encounters) end

    if isShiny then
        if shinies == nil then load_shinies() end
        table.insert(shinies, 1, {time = os.time(), species = species, atk = atk, def = def, spe = spe, spc = spc, item = item})
        while #shinies > KEEP_SHINIES do table.remove(shinies) end
        save_shinies()
        M.say(string.format("A SHINY %s! DVs %d/%d/%d/%d.", name_of(species):upper(), atk or 0, def or 0, spe or 0, spc or 0), true)
    end
    -- Nothing said for ordinary encounters: the chat is only for what
    -- matters (a shiny, a catch, trouble); the encounter list shows the rest.
    post()
end

-- A line for viewers, in the log.
function M.say(text, force)
    lastSaid = os.time()
    return Overlay.say(text, force)
end

-- When there's been nothing to say for a while, the log mentions the next
-- phone call: "Expecting a call from JOEY in the next 12 minutes." (named
-- when one trainer is in the phone). Not more than every CALL_NOTE_EVERY.
local QUIET_SECONDS, CALL_NOTE_EVERY = 600, 1200
local lastCallNote = 0
local noSignalSaid = nil      -- (the no-signal place already said)
local function maybe_call_note()
    local now = os.time()
    if now - lastSaid < QUIET_SECONDS or now - lastCallNote < CALL_NOTE_EVERY then return end
    local p = lastPhone
    if not p then return end
    -- (no phone service here - a cave, a gym: the call waits till it's out.
    -- Said once a stay, not the countdown - the user, 2026-11-10, Joey
    -- "expected" in Dark Cave every 20 minutes)
    if p.noSignal then
        local where = AutocrystalCurrentLocation or "here"
        if noSignalSaid ~= where then
            noSignalSaid = where
            lastCallNote = now
            local who = #p.callers == 1 and (p.callers[1] .. "'s call") or "Phone calls"
            M.say(string.format("No phone signal in %s - %s comes once the bot leaves.", where, who))
        end
        return
    end
    noSignalSaid = nil
    if p.mins < 1 then return end
    local mins = p.mins == 1 and "minute" or (p.mins .. " minutes")
    local who = #p.callers == 1 and (" from " .. p.callers[1]) or ""
    lastCallNote = now
    M.say(string.format("Expecting a call%s in the next %s.", who, mins))
end

-- Every frame from launcher.lua's main loop: posts what changed, and the
-- clock-driven parts (game time, place, encounter table) every few seconds.
function M.tick(running)
    if not running then return end
    if dirty or os.time() - lastPost >= TICK_SECONDS then
        post()
        maybe_call_note()
    end
end

-- For tests.
function M._reset()
    current, encounters, shinies = nil, {}, nil
    streak = {species = nil, count = 0}
    dirty, lastPost = true, 0
    lastSaid, lastPhone, lastCallNote, noSignalSaid = os.time(), nil, 0, nil
    pinned = false
end
M._build_state = build_state
M._shinies_file = SHINIES_FILE
M._pin_file = PIN_FILE

return M
