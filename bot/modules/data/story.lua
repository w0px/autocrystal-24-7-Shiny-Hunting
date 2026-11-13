-- story.lua (lives in modules/data/)
-- Plays the story: a list of steps (data/story_steps.lua), each with the
-- event flag that says it's done and what to do for it - walk somewhere,
-- talk to someone, train. Done steps are skipped, so it picks up wherever
-- the save is.
--
-- Cutscenes and talks are run by M.run_script, which the walker also uses
-- for any script that starts on the way (a scene trigger, a phone call):
--   * text: A;
--   * YES/NO: answered by M.ANSWERS (the words in the box - "nickname" NO,
--     "Daylight Saving" NO, TOTODILE YES...); anything else NO, and the
--     screen goes in the log;
--   * Mom's "What day is it?": today's day from the PC's clock;
--   * the rival's name: START, then A on END - an empty name, so the game
--     gives him its default (SILVER).
-- Battles that start in a script go to the walker (data/fighter.lua).
--
-- Each menu is recognised by the game's own routine for it (ROM hooks).

local M = {}

local Screen = require("data.screen")
local World, State, ButtonWait, Walker, D
local log = print

local function rom(bank, addr) return bank == 0 and addr or bank * 0x4000 + (addr - 0x4000) end
-- (pokecrystal11.sym; English Crystal 1.0 and 1.1 share them)
local HOOKS = {
    yesNo = rom(0x00, 0x1DD2),        -- PlaceYesNoBox (YesNoBox falls into it)
    day = rom(0x24, 0x496A),          -- SetDayOfWeek.loop2: "What day is it?", every frame
    naming = rom(0x04, 0x5915),       -- NamingScreenJoypadLoop: every frame on the naming screen
}
local A = {
    tilemap = 0xC4A0,
    tempDay = 0xD002,                 -- wTempDayOfWeek: the day the menu shows (0 Sunday)
    partyCount = 0xDCD7, party = 0xDCDF, partyLen = 0x30,
}

-- YES/NO: the first pattern found in the box's text (lower case) wins.
M.ANSWERS = {
    {"nickname", false},                 -- "Give a nickname to...?" (the user: none)
    {"you received?", false},            -- ...its last two lines: "the TOTODILE you / received?"
    {"know how to use", true},           -- Mom: "do you know how to use the PHONE?"
    {"daylight", false},                 -- Mom: "Is it Daylight Saving Time now?" - no
    {"is that ok", true},                -- "...(no DST), is that OK?"
    {"is it?", true},                    -- "SUNDAY, is it?"
    -- trainers asking for your phone number: NO - except Youngster Joey
    -- (data/joey.lua sets acceptNumber while it talks to him: his
    -- rematches pay for balls)
    {"number", function() return M.acceptNumber == true end},
    {"raise a", true},                   -- Elm: "I'd like you to raise a POKéMON" (says it till you do)
    {"recently caught", true},
    {"need your help", true},            -- ...and if it was NO: "But... Please, I need your help!"
    {"totodile", true},                  -- the user's starter
    {"cyndaquil", false},
    {"chikorita", false},
    {"catch", false},                    -- Route 29: "show you how to catch POKéMON?" - no tutorial
    {"heal your", true},                 -- Elm's healing machine
    {"money", false},                    -- Mom: "save your money?" - no (the user's rule)
    {"egg", true},                       -- Elm's aide in Violet: "take the POKéMON EGG?"
}
M.unknown = {}    -- questions answered NO for want of a rule, for the log

local H = {}

function M.setup(world, state, buttonWait, mem, walker, battleData, logger)
    World, State, ButtonWait, Walker, D = world, state, buttonWait, walker, battleData
    M._mem = mem          -- (its hook group switched on around the entry points below)
    log = logger or print
    if mem then
        for name, addr in pairs(HOOKS) do
            mem.RegisterROMHook(addr, function() H[name] = emu.framecount() end, "Story " .. name, nil, "Story")
        end
    end
end

local function r(a) return State.read8(a) end
local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end
-- (a hook time ahead of now: a savestate was loaded since - not recent)
local function recent(name, within)
    if H[name] == nil then return false end
    local d = emu.framecount() - H[name]
    return d >= 0 and d <= (within or 2)
end

-- The screen's text (all 18 rows), for the questions and the log.
function M.screen_text()
    local rows = {}
    for y = 0, 17 do
        local t = {}
        for x = 0, 19 do t[#t + 1] = D.charmap[r(A.tilemap + y * 20 + x)] or " " end
        local line = table.concat(t):gsub("%s+$", "")
        if line:match("%S") then rows[#rows + 1] = line:gsub("^%s+", "") end
    end
    return table.concat(rows, " / ")
end

-- YES or NO for the box on screen: true / false, and the rule's pattern.
-- (the rows are joined with spaces first: the box breaks lines anywhere -
-- "that I recently / caught.")
function M.answer(text)
    -- Talking to Joey (data/joey.lua): YES to whatever he asks - the box
    -- shows only the question's last lines ("so I think it'd be / a good
    -- motivator."), "number" was in the text before: seen in the game,
    -- 2026-11-08. His only questions: the number, "battle again, OK?".
    if M.acceptNumber then return true, "joey" end
    local t = text:lower():gsub(" / ", " ")
    for _, a in ipairs(M.ANSWERS) do
        if t:find(a[1], 1, true) then
            local v = a[2]
            if type(v) == "function" then v = v() == true end
            return v, a[1]
        end
    end
    return false, nil
end

-- Today, 0 Sunday - 6 Saturday, from the PC's clock.
function M.today() return (os.date("*t").wday or 1) - 1 end

-- Run the script under way to its end: text with A, the questions per
-- M.ANSWERS, the day menu, the naming screen. Returns "battle" if one
-- starts (the walker fights it, then calls this again), else nil.
function M.run_script(opts)
    opts = opts or {}
    local say = opts.say or log
    local n, idle = 0, 0
    local menuFor = Screen.watch()
    while n < 60 * 60 * 3 do
        if State.in_battle() then return "battle" end
        -- (a YES/NO: the box's hook, or one seen on screen waiting for input)
        if recent("yesNo", 30) or Screen.yes_no_waiting() then
            H.yesNo = nil
            Screen.wait_yes_no(300)        -- (answer once it takes input)
            local text = M.screen_text()
            local yes, rule = M.answer(text)
            if not rule then
                M.unknown[#M.unknown + 1] = text
                say("(A question I have no rule for - NO: " .. text .. ")")
            end
            Screen.answer(yes, press)
            n = n + 15
        elseif recent("day") then
            -- "What day is it?": Up/Down to today, then A (the "..., is it?" YES/NO follows)
            local want = M.today()
            for _ = 1, 10 do
                local now = r(A.tempDay)
                if now == want then break end
                press(((want - now) % 7 <= 3) and "Up" or "Down")
                frames(6)
            end
            say(string.format("Mom asks the day - %s.", os.date("%A")))
            press("A")
            frames(10)
            n = n + 60
        elseif recent("naming") then
            -- The rival's name: an empty one - START (the cursor to END), A.
            frames(20)
            press("Start"); frames(10)
            press("A"); frames(30)
            say("A naming screen: left empty, so the game uses its own name (the rival: SILVER).")
            n = n + 60
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "A")
            idle = 0
        elseif menuFor(Screen.menu_waiting()) > 600 then
            -- (watchdog: some other menu waiting 10 seconds in a script -
            -- nothing here knows it: back out, and say what it was)
            say("(A menu was left waiting - " .. M.screen_text() .. " - pressing B.)")
            press("B")
            n = n + 10
        else
            emu.frameadvance()
            n = n + 1
            if not State.script_running() then
                idle = idle + 1
                if idle > 30 then break end
            else
                idle = 0
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------ steps

local function flag_on(name)
    local n = World.data.flags[name]
    if n == nil then error("no event flag called " .. tostring(name)) end
    return State.flag(n)
end

local function lead_level()
    local n = math.min(r(A.partyCount), 6)
    local best = 0
    for i = 0, n - 1 do
        local base = A.party + i * A.partyLen
        if r(0xDCD8 + i) ~= 0xFD then return r(base + 31) end
    end
    return best
end
M.lead_level = lead_level

-- The team side (set by story_run): data/teamer.lua, data/pc.lua,
-- data/collection.lua, species names.
M.teamer, M.pc, M.collection, M.names = nil, nil, nil, {}
function M.use_team(teamer, pc, collection, names)
    M.teamer, M.pc, M.collection, M.names = teamer, pc, collection, names or {}
end

-- A party member's level by fingerprint (nil if not in the party).
local function level_of(fp)
    for _, m in ipairs(M.collection.party()) do if M.pc.fingerprint(m) == fp then return m.level end end
    return nil
end

-- Anything owned that knows a sleep move (a catcher).
local function has_sleeper()
    if not M.collection then return false end
    for _, m in ipairs(M.collection.all()) do
        for _, mv in ipairs(m.moves or {}) do
            if D.moves[mv] and D.moves[mv][2] == "EFFECT_SLEEP" and not m.egg then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------ training target
-- The user's rule: the next big fight not beaten yet (data/big_fights.lua),
-- its top level +2. M.bigFights is set by story_run.
M.bigFights = nil
M.MARGIN = 2
function M.next_big_fight()
    for _, f in ipairs(M.bigFights or {}) do
        local n = World.data.flags[f.beaten]
        if n and not State.flag(n) then
            local top = D.trainers and D.trainers[f.trainer]
            if top then return f, top + M.MARGIN, top end
        end
    end
    return nil
end
-- A level from a step: a number, or "next" (the rule above).
function M.target_level(lv)
    if lv ~= "next" then return lv end
    local _, target = M.next_big_fight()
    return target or 100
end

-- Whether a step is done: done = "EVENT_..." (that flag set), or a table
-- {balls = true} (a Poke Ball in the bag), {level = n} (the team's
-- fighters - or the lead, without a team - at n+), {sleeper = true}
-- (something owned knows a sleep move).
function M.is_done(step)
    local d = step.done
    if d == nil then return false end
    if type(d) == "string" then return flag_on(d) end
    if d.balls then local _, total = State.balls(); return total > 0 end
    -- (the aide's 5 Poke Balls - given once: Elm's Lab scene (wElmsLabSceneID,
    -- D987) is 6, SCENE_ELMSLAB_AIDE_GIVES_POKE_BALLS, from the egg until
    -- they're given. Not "a ball in the bag": with none left the bot walked
    -- back to the Lab for balls it never gets again - the user, 2026-11-08)
    if d.aideBalls then return flag_on("EVENT_GAVE_MYSTERY_EGG_TO_ELM") and State.read8(0xD987) ~= 6 end
    if d.sleeper then return has_sleeper() end
    -- (a fly point: SPAWN_* n, bit n of wVisitedSpawns (DCA5) - set by the
    -- town's MAPCALLBACK_NEWMAP as you walk in; SPAWN_VIOLET 16)
    if d.flypoint then return (State.read8(0xDCA5 + d.flypoint // 8) >> (d.flypoint % 8)) & 1 == 1 end
    -- (one of these species is owned - party or box: the catcher's Caterpie,
    -- the Zubat; the user, 2026-11-09)
    if d.roles then return M.role_next == nil or M.role_next() == nil end
    if d.owns then
        if not M.collection then return false end
        local want = {}
        for _, n in ipairs(d.owns) do want[n:upper()] = true end
        for _, m in ipairs(M.collection.all()) do
            if not m.egg and want[tostring(M.names[m.species] or ""):upper()] then return true end
        end
        return false
    end
    if d.level then
        local want = M.target_level(d.level)
        local fighters = M.teamer and M.teamer.fighters() or {}
        if #fighters <= 1 then return lead_level() >= want end
        for _, f in ipairs(fighters) do if (level_of(f.fp) or 0) < want then return false end end
        return true
    end
    return false
end

local function key(name)
    local k = World.key_of(name)
    if not k then error("no map called " .. tostring(name)) end
    return k
end

-- The person/thing with this script on that map: its index (1-based, the
-- map's object order) and data.
local function find_object(mapKey, script)
    for i, o in ipairs(World.map(mapKey).objs) do
        if o[9] == script then return i, o end
    end
    return nil
end

local SERIOUS = {shiny = true, whiteout = true, data = true, battle = true, stopped = true}

-- Walk up to someone and talk: A, then their script to its end (battles
-- fought). Where they stand now if they're on screen (people walk).
local function talk(mapKey, script, opts)
    local idx, o = find_object(mapKey, script)
    if not idx then return false, "no " .. script .. " on " .. World.map(mapKey).name end
    for attempt = 1, 4 do
        if opts.done and opts.done() then return true end
        local x, y = o[1], o[2]
        if State.where().map == mapKey then
            local lx, ly, shown = State.object_pos(idx)
            if lx and shown then x, y = lx, ly end
        end
        local ok, why = Walker.go_talk(mapKey, x, y, opts)
        if not ok then
            if opts.done and opts.done() then return true end
            return false, why
        end
        -- (they may have walked off while we came: talk only if still there)
        local lx, ly = State.object_pos(idx)
        if lx == x and ly == y or attempt == 4 then
            press("A")
            frames(20)
            if State.script_running() or State.in_battle() then
                local stop = Walker.interruptions(opts)
                if stop then return false, stop end
                return true
            end
        end
        frames(30)
    end
    return false, "couldn't talk to " .. script
end

-- Two tiles next to each other where wild ones appear - tall grass, or
-- the floor of a cave or tower (Sprout Tower) - nearest `near`.
-- Two tiles next to each other where wild ones appear - world.lua's shared
-- picker: nobody standing there, reachable, nearest `near` (else us / the
-- map's entrances).
local function pace_spot(mapKey, near)
    local w = State.where()
    local flag = State.flag_checker(World.data.flags)
    return World.pace_pair(mapKey, {map = w.map, x = w.x, y = w.y, face = State.facing()}, flag, near)
end

-- Pace on g until done() (or n paces). nil when done, or why it stopped.
local function pace(mapKey, g, o, done, n)
    -- (1.2's walking pattern: a loop round the edge of the grass patch)
    -- (a new loop each round in a big patch)
    local pacer = require("data.walk_loop").pacer(World, mapKey, g, State.flag_checker(World.data.flags))
    for p = 1, n or 5000 do
        if done() then return nil end
        local w = State.where()
        local t = pacer:next(w.map == mapKey and w.x or nil, w.map == mapKey and w.y or nil)
        local ok, why = Walker.go({map = mapKey, x = t[1], y = t[2], pacing = true}, o)
        if not ok and tostring(why):match("^no route") and not pacer.pairOnly then
            pacer:fallback()       -- (a loop tile out of reach: the two tiles)
            ok = true
        end
        if not ok then return why end
    end
    return "paced a long time without getting there"
end

-- Fight wild Pokemon on a map until the team's fighters (starter +
-- specialists, data/teamer.lua) are at `level` - each in turn put in front
-- and trained; without a team, the lead. Then the team's order again.
local function train(mapKey, level, near, opts, say)
    local g = pace_spot(mapKey, near)
    if not g then return false, "nowhere on " .. World.map(mapKey).name .. " for wild Pokemon" end
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.fight_wild = true
    local fighters = M.teamer and M.teamer.fighters() or {}
    if #fighters <= 1 then
        say(string.format("Training on %s (%d,%d) until the lead is Lv %d (now %d).", World.map(mapKey).name, g[1], g[2], level, lead_level()))
        local why = pace(mapKey, g, o, function() return lead_level() >= level end)
        if why then return false, why end
        return true
    end
    -- (switch-training, as in the hunt: the one being trained leads, a
    -- teammate who can win comes in - both get the EXP; the user, 2026-11-08)
    o.trainee = true
    for _, f in ipairs(fighters) do
        local lv = level_of(f.fp)
        if lv and lv < level then
            say(string.format("Training %s (Lv %d) to Lv %d on %s - putting it in front.", M.names[f.species] or "#" .. f.species, lv, level, World.map(mapKey).name))
            M.teamer.front = f.fp       -- (a Center visit keeps it in front)
            local why = pace(mapKey, g, o, function()
                local now = level_of(f.fp)
                if now == nil or now >= level then return true end
                -- (in front - a Center trip may have put the team's order back)
                local first = M.collection.party()[1]
                if not first or M.pc.fingerprint(first) ~= f.fp then M.pc.order_party({f.fp}, {say = say}) end
                return false
            end)
            if why then M.teamer.front = nil; return false, why end
        end
    end
    -- The team's own order again.
    M.teamer.front = nil
    if M.teamer.current then
        local _, order = M.teamer.plan_moves(M.teamer.current, M.collection.party(), M.collection.current_box(), 0, false)
        M.pc.order_party(order, {say = say})
    end
    return true
end

-- Train the catchers (the user, 2026-11-09: before Sprout Tower, so the
-- starter shares the EXP - switch-training - and a Lv 5 Caterpie never has
-- to face the Sages). M.role_next() (play): the next trainee {fp, species,
-- level, target, why}, {center = why} for a Center visit (the new catcher
-- is named there), or nil when they're all where they should be.
M.role_next = nil
local function train_roles(mapKey, near, opts, say)
    if not M.role_next then return true end
    local g = pace_spot(mapKey, near)
    if not g then return false, "nowhere on " .. World.map(mapKey).name .. " for wild Pokemon" end
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.fight_wild = true
    o.trainee = true
    local trained, lastCenter = false, nil
    for _ = 1, 30 do
        local t = M.role_next()
        if not t then break end
        if t.center then
            -- (the same one again after a visit: the Center didn't change it - on)
            if t.center == lastCenter then say("(" .. t.center .. " - still, after a Center visit. Going on.)"); break end
            lastCenter = t.center
            say(t.center .. ".")
            local w = State.where()
            local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, State.flag_checker(World.data.flags))
            if not c then return false, "no Pokemon Center to walk to" end
            local stop = Walker.heal_at(c, {}, o, say)
            if stop then return false, stop end
        else
            trained = true
            say(string.format("Training %s (Lv %d) to Lv %d on %s - %s.", M.names[t.species] or "#" .. t.species, t.level, t.target,
                World.map(mapKey).name, t.why or "the catcher"))
            if M.teamer then M.teamer.front = t.fp end
            local why = pace(mapKey, g, o, function()
                local n = M.role_next()
                if not n or n.center or n.fp ~= t.fp then return true end
                local first = M.collection and M.collection.party()[1]
                if first and M.pc and M.pc.fingerprint(first) ~= t.fp then M.pc.order_party({t.fp}, {say = say}) end
                return false
            end)
            if why then if M.teamer then M.teamer.front = nil end; return false, why end
        end
    end
    if M.teamer then
        M.teamer.front = nil
        if trained and M.teamer.current then
            local _, order = M.teamer.plan_moves(M.teamer.current, M.collection.party(), M.collection.current_box(), 0, false)
            M.pc.order_party(order, {say = say})
        end
    end
    return true
end

-- Catch one of these species on a map (wild, not shiny): pace there with
-- catching on for them. Only at the given times of day ({"NITE"}); at
-- another time: nothing now (an optional step is tried again next run).
local function catch_some(mapKey, a, opts, say, done)
    if a.times then
        local now, ok = State.time_of_day(), false
        for _, t in ipairs(a.times) do if t == now then ok = true end end
        if not ok then
            say(string.format("(%s only appear%s at %s here - it's %s now. Not now.)", table.concat(a.species, "/"), #a.species > 1 and "" or "s",
                table.concat(a.times, "/"), now))
            return true
        end
    end
    local want = {}
    for _, n in ipairs(a.species) do
        for id, nm in pairs(M.names) do if type(id) == "number" and nm:upper() == n:upper() then want[id] = true end end
    end
    local g = pace_spot(mapKey, a.near)
    if not g then return false, "nowhere on " .. World.map(mapKey).name .. " for wild Pokemon" end
    say(string.format("Looking for a %s on %s to catch.", table.concat(a.species, " or "), World.map(mapKey).name))
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.catch = true
    o.catch_species = want
    local function over()
        if done() then return true end
        if a.times then
            local now, ok = State.time_of_day(), false
            for _, t in ipairs(a.times) do if t == now then ok = true end end
            if not ok then return true end
        end
        return false
    end
    -- (asked between the walker's moves too, not only between its loop
    -- tiles: one walk in the grass met three Caterpie in a row and caught
    -- them all - the user, 2026-11-09: "3 non shiny caterpies instead of 1")
    o.done = over
    -- (and one is enough: no more of them once one's caught, even in the
    -- middle of a walk - as the hunt does for its role catches)
    local onCaught = opts.on_caught
    o.on_caught = function(sp, lv, caught)
        if caught then o.catch_species = nil end
        if onCaught then onCaught(sp, lv, caught) end
    end
    local why = pace(mapKey, g, o, over, a.paces or 400)
    if why and why ~= "paced a long time without getting there" then return false, why end
    return true
end

-- A Ruins of Alph puzzle (data/unown_puzzle.lua): stand under the stone
-- slab (x, y, facing up), A, solve it - the floor gives way, down into the
-- Inner Chamber ("There is a strange presence here...").
M.puzzle = nil      -- data/unown_puzzle.lua (tests set a stand-in)
local function unown_puzzle(mapKey, x, y, opts, say)
    local Puzzle = M.puzzle or require("data.unown_puzzle")
    if Puzzle.setup and not M.puzzle then Puzzle.setup(State, say) end
    local ok, why = Walker.go({map = mapKey, tiles = {{x, y, "Up"}}}, opts)
    if not ok then return false, why end
    local up = false
    for _ = 1, 3 do
        press("A")
        for _ = 1, 180 do
            if Puzzle.on_screen() then up = true; break end
            emu.frameadvance()
        end
        if up then break end
    end
    if not up then return false, "the puzzle didn't open" end
    frames(30)
    say("The stone puzzle: putting its 16 pieces in place.")
    local solved, why2 = Puzzle.solve(say)
    if not solved then
        Puzzle.quit()
        frames(60)
        return false, "the puzzle: " .. tostring(why2)
    end
    say("Solved the puzzle - the floor gives way.")
    -- (the fall, then the Inner Chamber's text)
    for _ = 1, 4 do
        frames(60)
        M.run_script({say = say})
    end
    return true
end

local function act(a, opts, say, step)
    if a.puzzle then
        return unown_puzzle(key(a.puzzle[1]), a.puzzle[2], a.puzzle[3], opts, say)
    elseif a.roles then
        return train_roles(key(a.roles.map), a.roles.near, opts, say)
    elseif a.catch then
        return catch_some(key(a.catch.map), a.catch, opts, say, function() return M.is_done(step) end)
    elseif a.go then
        -- (done on the way - Violet's fly point as we walk in: stop there)
        local o = opts
        if step and step.done ~= nil then
            o = {}
            for k, v in pairs(opts) do o[k] = v end
            o.done = function() return M.is_done(step) end
        end
        return Walker.go({map = key(a.go[1]), x = a.go[2], y = a.go[3], face = a.go[4]}, o)
    elseif a.talk then
        -- (done on the way - a trainer who spotted us, beaten: stop walking)
        local o = opts
        if step and step.done ~= nil then
            o = {}
            for k, v in pairs(opts) do o[k] = v end
            o.done = function() return M.is_done(step) end
        end
        return talk(key(a.talk[1]), a.talk[2], o)
    elseif a.train then
        local lv = M.target_level(a.train.level)
        if a.train.level == "next" then
            local f, _, top = M.next_big_fight()
            if f then say(string.format("Training target: Lv %d - the next big fight is %s (top Pokemon Lv %d) +%d.", lv, f.name, top, M.MARGIN)) end
        end
        return train(key(a.train.map), lv, a.train.near, opts, say)
    elseif a.wait then
        frames(a.wait)
        return true
    end
    return false, "a step with nothing to do"
end

-- Play the steps in order, skipping the done ones. opts: the walker's
-- (say, flags...). Returns true when all are done, or false and why.
function M.run(steps, opts)
    local say = opts.say or log
    opts.script = function() return M.run_script({say = say}) end
    local function later_done(i)
        for k = i + 1, #steps do if steps[k].done ~= nil and M.is_done(steps[k]) then return true end end
        return false
    end
    for i, step in ipairs(steps) do
        if opts.should_stop and opts.should_stop() then return false, "stopped" end
        if step.testOnly and opts.shinyOnly then
            -- (catching a regular Pokemon: only when testing, never on the stream)
        elseif not M.is_done(step) and not (step.done == nil and later_done(i)) then
            say(string.format("Story %d/%d: %s.", i, #steps, step.name))
            for try = 1, 3 do
                local failed = nil
                for _, a in ipairs(step.actions) do
                    local ok, why = act(a, opts, say, step)
                    if not ok then failed = why; break end
                end
                if failed == nil and (M.is_done(step) or step.done == nil) then break end
                if step.optional and not (failed and SERIOUS[failed]) then
                    -- (one that can wait: not now - it's tried again next run)
                    say("Not done yet: " .. step.name .. (failed and (" (" .. tostring(failed) .. ")") or "") .. " - going on, it's tried again next run.")
                    break
                end
                if failed and failed ~= "whiteout" and SERIOUS[failed] then return false, failed end
                if failed == "whiteout" then
                    say("Whited out - back at a Pokemon Center. Trying that step again.")
                elseif failed then
                    say("(That didn't work: " .. tostring(failed) .. " - trying again.)")
                else
                    say("(Did all of it, but the game doesn't have it as done yet - again.)")
                end
                if try == 3 then return false, "step " .. i .. " (" .. step.name .. ") didn't get done" end
            end
            if step.done ~= nil and M.is_done(step) then say("Done: " .. step.name .. ".") end
        end
    end
    return true
end

-- Talk to someone by map name and script (data/joey.lua: Joey on Route 30).
function M.talk_to(mapName, script, opts)
    return talk(key(mapName), script, opts)
end


-- Its ROM hooks only while it's in use (the "Story" hook group - data/memory.lua;
-- the speed check, 2026-11-11: always-on hooks slowed BizHawk's core ~10x).
-- Wrapped here, before anything keeps its own copy of these.
for _, name in ipairs({"run_script"}) do
    local f = M[name]
    M[name] = function(...)
        local mem = M._mem
        if mem and mem.WithHookGroup then return mem.WithHookGroup("Story", f, ...) end
        return f(...)
    end
end

return M
