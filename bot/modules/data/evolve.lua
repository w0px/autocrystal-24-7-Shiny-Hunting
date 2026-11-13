-- evolve.lua (lives in modules/data/)
-- The section's evolutions before the gym (the user's rules, 2026-11-08):
-- every form data/goals.lua says is made by evolving a spare copy - level
-- and friendship ones before the gym (stone ones once there's the stone,
-- not here yet; trade ones are left out).
--
-- One copy at a time: fetched from the current PC box if it's there (at the
-- nearest Pokemon Center, data/teamer.lua's keep list), put in front, and
-- trained in the section's grass with the most EXP (the highest wild levels
-- at this time of day) - switch-training: it leads, a teammate who can win
-- comes in, both share the EXP (data/fighter.lua). It evolves on the
-- level-up that does it; the keepers (the copy of each form that stays)
-- have theirs stopped with B (fighter.no_evolve). Friendship (Crobat): the
-- level-ups and the steps raise it; it evolves on a level-up at 220+.
--
-- M.training_spot is a plain function on tables, tested offline.

local M = {}

local D, World, State, Walker, Goals, C, PC, Teamer, Fighter
local log = print
M.PACES = 40         -- paces between re-plans
M.FRIENDSHIP = 220

function M.setup(battleData, world, state, walker, goals, collection, pc, teamer, fighter, logger)
    D, World, State, Walker, Goals, C, PC, Teamer, Fighter = battleData, world, state, walker, goals, collection, pc, teamer, fighter
    log = logger or print
end

local SLOTS = {30, 30, 20, 10, 5, 4, 1}

-- Where in the section the wild ones are highest-level at this time of day
-- (the most EXP a battle): map const, average level.
function M.training_spot(section, time)
    local best, bestAvg = nil, -1
    for _, mp in ipairs(section.maps) do
        -- (not a puzzle-locked map - the Inner Chamber's Unown: nothing
        -- there until it's solved, and only Unown after)
        local g = not (section.locked and section.locked[mp]) and D.wild_grass[mp]
        if g and g[time] then
            local avg = 0
            for i, slot in ipairs(g[time]) do avg = avg + slot[1] * SLOTS[i] / 100 end
            if avg > bestAvg then best, bestAvg = mp, avg end
        end
    end
    return best, bestAvg
end

-- The friendship ones (Crobat...): keep them in the party while hunting -
-- the steps raise friendship. A set of fingerprints.
function M.friendship_copies(plan)
    local out = {}
    for _, e in ipairs(plan.evolve) do
        for _, step in ipairs(e.path or {}) do
            if step[1] == "happiness" and e.fp then out[e.fp] = true end
        end
    end
    return out
end

local function key_of_const(const)
    for k, m in pairs(World.data.maps) do if m.const == const then return k end end
    return nil
end

-- The copy now (it may have evolved: its species changed, its DVs and
-- trainer ID didn't).
local function find_copy(ev)
    for _, m in ipairs(C.all()) do
        if ev.dvs and m.dvs and m.dvs[1] == ev.dvs[1] and m.dvs[2] == ev.dvs[2] and m.otId == ev.otId then return m end
    end
    return nil
end

-- Pace tiles on a map we can walk to (as data/hunt.lua does).
-- Where to pace on a map: world.lua's shared picker.
local function pace_tiles(key, flag)
    local w = State.where()
    return World.pace_pair(key, {map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
end

-- Do the section's blocking evolutions. opts: the walker's (say,
-- should_stop...), allShiny. Returns true when none is left, or false and
-- why ("catch" - something's to be caught first - "stopped", ...).
function M.run(section, opts)
    local say = opts.say or log
    local flag = State.flag_checker(World.data.flags)
    local skip = {}             -- copies that can't be had (in another box)
    local boxTried = nil        -- (the full box a Center visit was made for)
    local lastNote = nil
    while true do
        if opts.should_stop and opts.should_stop() then return false, "stopped" end
        local plan = Goals.plan(section, C.all(), {allShiny = opts.allShiny})
        Fighter.no_evolve = plan.keepers
        local toCatch = 0
        for _, c in ipairs(plan.catch) do toCatch = toCatch + c.need end
        if toCatch > 0 then Teamer.front = nil; return false, "catch" end
        local ev = nil
        for _, e in ipairs(plan.evolve) do
            if e.blocking and not skip[e.fp] then ev = e; break end
        end
        if not ev then
            Teamer.front = nil
            if next(skip) then return false, "a copy to evolve is in another PC box" end
            Teamer.keep = {}
            return true
        end
        local copy = find_copy(ev)
        if not copy then return false, "lost track of " .. Goals.name(ev.from) end
        local fp = PC.fingerprint(copy)
        Teamer.keep = {[fp] = true}
        -- (the party full and the current box too: a shiny met while
        -- training would have nowhere to go - a Center, where the teamer
        -- changes to a box with room)
        local party, curList = C.party(), C.box and C.current_box and C.box(C.current_box())
        local boxFull = #party >= 6 and curList and #curList >= 20
        if boxFull and copy.where == "party" then
            if boxTried == C.current_box() then return false, "box full" end
            boxTried = C.current_box()
            local w = State.where()
            local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
            if not c then return false, "box full" end
            say(string.format("Box %d is full - changing to a box with room at the PC first.", C.current_box()))
            Walker.healing = true
            local stop = Teamer.manage(c.key, opts)
            Walker.healing = false
            if stop then return false, stop end
        end
        -- In the party? If not: the nearest Pokemon Center's PC (the teamer
        -- fetches it - from whichever box it's in).
        if copy.where ~= "party" then
            do
                local w = State.where()
                local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
                if not c then return false, "no Pokemon Center to fetch " .. Goals.name(copy.species) end
                say(string.format("Fetching %s from box %d to evolve it into %s.", Goals.name(copy.species), copy.box or 0, Goals.name(ev.to)))
                Walker.healing = true
                local stop = Teamer.manage(c.key, opts)
                Walker.healing = false
                if stop then return false, stop end
                local now = find_copy(ev)
                if not now or now.where ~= "party" then return false, "couldn't get " .. Goals.name(copy.species) .. " out of the PC" end
            end
        else
            -- In front, then train where the EXP is.
            local first = C.party()[1]
            Teamer.front = fp           -- (a Center visit keeps it in front)
            if not first or PC.fingerprint(first) ~= fp then PC.order_party({fp}, {say = say}) end
            local time = (State.time_of_day() or "DAY"):lower()
            local mp, avg = M.training_spot(section, time)
            local key = mp and key_of_const(mp)
            if not key then return false, "nowhere to train in " .. section.name end
            local friendship = false
            for _, step in ipairs(ev.path or {}) do if step[1] == "happiness" then friendship = true end end
            local note = string.format("Evolving %s (Lv %d) into %s (%s): training it on %s (wild Lv ~%d), switch-training%s.",
                Goals.name(copy.species), copy.level, Goals.name(ev.to), ev.how, World.map(key).name, math.floor(avg + 0.5),
                friendship and string.format(" - friendship %d/%d", copy.happiness or 0, M.FRIENDSHIP) or "")
            if note ~= lastNote then say(note); lastNote = note end
            local tiles = pace_tiles(key, flag)
            if not tiles then return false, "no way to the grass on " .. World.map(key).name end
            local o = {}
            for k, v in pairs(opts) do o[k] = v end
            o.fight_wild = true
            o.trainee = true
            local species0 = copy.species
            -- (1.2's walking pattern: a loop round the edge of the grass patch)
            -- (a new loop each round in a big patch)
            local pacer = require("data.walk_loop").pacer(World, key, tiles, flag)
            for p = 1, M.PACES do
                local here = State.where()
                local t = pacer:next(here.map == key and here.x or nil, here.map == key and here.y or nil)
                local ok, why = Walker.go({map = key, x = t[1], y = t[2], pacing = true}, o)
                if not ok and tostring(why):match("^no route") and not pacer.pairOnly then
                    pacer:fallback()   -- (a loop tile out of reach: the two tiles)
                    ok = true
                end
                if not ok then return false, why end
                local now = find_copy(ev)
                if not now then break end
                if now.species ~= species0 then
                    say(string.format("%s evolved into %s!", Goals.name(species0), Goals.name(now.species)))
                    break
                end
                -- (a Center trip may have put the team's order back: in front again)
                local f1 = C.party()[1]
                if not f1 or PC.fingerprint(f1) ~= PC.fingerprint(now) then PC.order_party({PC.fingerprint(now)}, {say = say}) end
            end
        end
    end
end

return M
