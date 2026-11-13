-- hunt.lua (lives in modules/data/)
-- Hunts a section's shinies (the user's loop, 2026-11-08): until every form
-- data/goals.lua says holds up the gym is had, it picks where to hunt now,
-- walks there and paces in the grass (or a cave/tower floor), running from
-- everything - a shiny is caught (data/fighter.lua: sleep, safe weakening,
-- balls). With the testing switch, regular Pokemon of species still needed
-- are caught too, so the whole loop can be seen working.
--
-- Where (the user, 2026-11-10): data/hunt_planner.lua splits each time of
-- day's hours between the spots met then, so every shiny still needed is
-- caught soonest; the roll at a time of day follows those hours. While
-- Joey's rematch is awaited for money, maps where the game takes no phone
-- calls (caves) count M.NO_PHONE_WAITING. It rolls again when the time of
-- day changes, after a catch and after a trip (Center, Mart, Joey);
-- otherwise it stays.
--
-- M.score_spots / M.choose are plain functions on tables, tested offline.

local M = {}

local World, State, Walker, Goals, C
local WalkLoop = require("data.walk_loop")
local Planner = require("data.hunt_planner")
local log = print
M.PACES = 30        -- paces between re-plans (each pace: a step or two in the grass)
-- Waiting for Joey's rematch call (money for balls): maps without phone
-- service (data/no_phone.lua - Dark Cave, Union Cave...) count this much.
M.NO_PHONE_WAITING = 0.2
M.no_phone = nil    -- map const -> true (built from data/no_phone.lua at first use; tests set it)
M.joey = nil        -- data/joey.lua (set by play): balls low -> the Mart, or Joey's rematches
-- Training during the hunt (the user's rule, 2026-11-08): while a team
-- fighter is under the training target (the next big fight's top level
-- +2), it leads and the wild ones not being caught are fought instead of
-- run from - switch-training: a teammate who can win comes in, both get
-- the EXP. Set by play: {next = fn() -> {fp, species, level, target} or
-- nil, front = fn(fp), restore = fn()}.
M.training = nil
-- role_catch(time, spot) -> {[species] = fn(level) -> bool}, why - or nil: the
-- regular Pokemon worth catching now for an empty catcher or second-catcher
-- slot (set by play: data/team.lua decides who fits).
M.role_catch = nil
-- The times of day in turn, when each starts (Crystal: morning 4:00, day
-- 10:00, night 18:00), and how long until the next one (game clock).
M.NEXT_TIME = {morn = "day", day = "nite", nite = "morn"}
M.TIME_START = {morn = 4, day = 10, nite = 18}
M.TIME_TEXT = {morn = "4 AM", day = "10 AM", nite = "6 PM"}
M.TIME_WORD = {morn = "morning", day = "day", nite = "night"}
function M.minutes_left(time, hours, minutes)
    local nxt = M.TIME_START[M.NEXT_TIME[time] or "day"] or 10
    local left = (nxt * 60 - ((hours or 0) * 60 + (minutes or 0))) % 1440
    if left == 0 then left = 1440 end
    return left
end
-- The reminder step for minutes left (the user, 2026-11-09: "hunting X for
-- 1 more hour, every hour and 30 min before the switch"): whole hours left
-- (rounded up) while over 30 minutes, 0 for the last 30. A reminder is said
-- when it drops.
function M.reminder_step(left)
    if left > 30 then return math.ceil(left / 60) end
    return 0
end
function M.reminder_text(place, left, nextPlace, nextTime)
    local span
    if left > 30 then
        local h = math.ceil(left / 60)
        span = h == 1 and "1 more hour" or (h .. " more hours")
    else
        span = math.max(1, left) .. " more minutes"
    end
    -- (the next rotation is the same place: not "then Route 31" while on
    -- Route 31 - it stays, for the next time of day's ones; the user,
    -- 2026-11-09)
    if nextPlace and nextPlace == place then
        local wait = left > 30 and span:gsub(" more", "") or (math.max(1, left) .. " minutes")
        return string.format("Hunting on %s - staying here for the %s Pokemon at %s, in %s.", place,
            M.TIME_WORD[nextTime] or "next", M.TIME_TEXT[nextTime] or "the next change", wait)
    end
    local after = nextPlace and string.format(" - then %s at %s", nextPlace, M.TIME_TEXT[nextTime] or "the next change") or ""
    return string.format("Hunting on %s for %s%s.", place, span, after)
end

-- The section's species the hunt needs no more of (Goals.plan): met here,
-- and nothing left to catch for them - not for their own form, not as a
-- spare to evolve. Sorted ids. (the overlay colours their icons - the user,
-- 2026-11-10: the 2nd Spinarak was caught, the target gone, the icon grey)
function M.done_species(plan)
    local open, out, seen = {}, {}, {}
    for _, c in ipairs(plan.catch or {}) do
        if (c.need or 0) + (c.later or 0) > 0 then open[c.species] = true end
    end
    for _, f in ipairs(plan.forms or {}) do
        if (f.met or f.catchable) and not open[f.species] and not seen[f.species] then
            seen[f.species] = true
            out[#out + 1] = f.species
        end
    end
    table.sort(out)
    return out
end

-- Tell the overlay where the section stands: the icons in colour
-- (done_species) and "CURRENT PHASE SHINIES n/total" - the shinies the
-- section has for its forms: each form owned, and each copy set aside to
-- evolve into one (the user, 2026-11-10: 3 shinies caught showed 2 - the
-- second Spinarak waits for Ariados), of all its forms (one shiny each).
M.secured = function(plan) return (plan.have or 0) + #(plan.evolve or {}) end
function M.tell_overlay(plan, opts)
    if opts.on_done then pcall(opts.on_done, M.done_species(plan)) end
    if opts.on_phase then pcall(opts.on_phase, M.secured(plan), plan.total) end
end

-- Where species (a list) are met most often at this time of day (per second
-- of game time - hunt_planner.secs): a spot
-- (the scored one if there is one) and the wild table's entry - or nil.
function M.role_spot(section, time, species, scored)
    local best, bestPs = nil, nil
    local all = Goals.spots(section)
    for _, sp in ipairs(species) do
        for _, s in ipairs(all[sp] or {}) do
            if s.time == time or s.time == "any" then
                local ps = s.pct / Planner.secs(s.rate, s.map)
                if not bestPs or ps > bestPs then best, bestPs = s, ps end
            end
        end
    end
    if not best then return nil end
    for _, e in ipairs(scored or {}) do if e.map == best.map and e.time == best.time then return e, best end end
    return {map = best.map, time = best.time, species = {}, onlyNow = {}, value = 0, share = 0, weight = 0}, best
end
-- role_species(time) -> {species, ...}, job - or nil: a catcher missing whose
-- species to go and find (the hunt goes where it's met most now).
M.role_species = nil
M.ORDER_CHECK_SECONDS = 600   -- (how often the hunt checks the catcher leads)
M.HUNT_HP = 0.9     -- pure hunting: anyone under this share of HP -> a Pokemon Center first
-- needCenter: set to a reason to visit a Center next (the Teamer there
-- re-picks the team - the future catcher at its level).
M.needCenter = nil

function M.setup(world, state, walker, goals, collection, logger)
    World, State, Walker, Goals, C = world, state, walker, goals, collection
    log = logger or print
end

-- Every (map, time of day) of the section where something still needed is
-- met, with its planned hours (data/hunt_planner.lua). plan: Goals.plan.
-- Returns a list, most hours first: {map, time, weight (hours a day planned
-- there), share (% of encounters there that are needed species), species
-- (the needed ones: met on this map only first, then met only at this time of
-- day, then furthest behind), onlyNow (needed ones met only at this time of
-- day), exclusive (needed ones met on this map only), rate, secs} - and the planner's result ({spots,
-- days = {[species] = days}, finish = days for the section, on average}).
function M.score_spots(section, plan)
    local need = {}
    for _, c in ipairs(plan.catch) do if (c.need or 0) > 0 then need[c.species] = c.need end end
    local all = Goals.spots(section)
    local r = Planner.plan(need, all)
    local times = {}          -- species -> {[time] = true}
    for sp, list in pairs(all) do
        times[sp] = {}
        for _, s in ipairs(list) do
            if s.time == "any" then for _, t in ipairs(Planner.TIMES) do times[sp][t] = true end
            else times[sp][s.time] = true end
        end
    end
    -- (species met on one map of the section only: that map's own - the
    -- reason to be there, the user, 2026-11-10: "the bot is on Route 29, so
    -- its main target is Sentret - put the route-exclusive target first":
    -- Dark Cave in the morning is Teddiursa, then Dunsparce; no bold - the
    -- user didn't like it)
    local onMaps = {}         -- species -> number of maps
    for sp, list in pairs(all) do
        local seen, n = {}, 0
        for _, s in ipairs(list) do if not seen[s.map] then seen[s.map] = true; n = n + 1 end end
        onMaps[sp] = n
    end
    local out = {}
    for _, e in ipairs(r.spots) do
        local species, onlyNow, exclusive, share = {}, {}, {}, 0
        for _, sp in ipairs(e.needed) do
            species[#species + 1] = sp
            share = share + e.pct[sp]
            local n = 0
            for _ in pairs(times[sp]) do n = n + 1 end
            if n == 1 then onlyNow[#onlyNow + 1] = sp end
            if onMaps[sp] == 1 then exclusive[#exclusive + 1] = sp end
        end
        local isOwn, isExcl = {}, {}
        for _, sp in ipairs(onlyNow) do isOwn[sp] = true end
        for _, sp in ipairs(exclusive) do isExcl[sp] = true end
        -- (the map's exclusive ones first, then this time of day's own ones -
        -- the planner hunts them first - then the furthest behind)
        local function behind(a, b)
            if (isExcl[a] or false) ~= (isExcl[b] or false) then return isExcl[a] or false end
            if (isOwn[a] or false) ~= (isOwn[b] or false) then return isOwn[a] or false end
            if r.days[a] ~= r.days[b] then return r.days[a] > r.days[b] end
            return a < b
        end
        table.sort(species, behind)
        table.sort(onlyNow, behind)
        table.sort(exclusive, behind)
        out[#out + 1] = {map = e.map, time = e.time, weight = e.hours, hours = e.hours, share = share, species = species,
            onlyNow = onlyNow, exclusive = exclusive, rate = e.rate, secs = e.secs}
    end
    table.sort(out, function(a, b) if a.weight ~= b.weight then return a.weight > b.weight end; return a.map < b.map end)
    return out, r
end

-- The plan in words: "morning: Dark Cave 49%, Route 46 42%...; day: ...".
-- name(map const) -> its name.
function M.describe_plan(scored, name)
    local parts = {}
    for _, t in ipairs(Planner.TIMES) do
        local l = {}
        for _, e in ipairs(scored) do
            if e.time == t and e.weight > 0 then
                l[#l + 1] = string.format("%s %d%%", name and name(e.map) or e.map, math.floor(100 * e.weight / Planner.HOURS[t] + 0.5))
            end
        end
        parts[#parts + 1] = M.TIME_WORD[t] .. ": " .. (#l > 0 and table.concat(l, ", ") or "nothing needed")
    end
    return table.concat(parts, "; ")
end

-- A map's weight in the roll now: the catches still to be had, less on a
-- map without phone service while Joey's call is awaited.
function M.roll_weight(e)
    local w = e.weight
    local j = M.joey
    if j and j.state and j.state.waiting and (not j.registered or j.registered()) then
        if not M.no_phone and World and World.key_of then
            local t = {}
            local ok, list = pcall(require, "data.no_phone")
            for _, name in ipairs(ok and list or {}) do
                local key = World.key_of(name)
                local m = key and World.map(key)
                if m and m.const then t[m.const] = true end
            end
            M.no_phone = t
        end
        if M.no_phone and M.no_phone[e.map] then w = w * M.NO_PHONE_WAITING end
    end
    return w
end

-- Where to hunt at this time of day ("morn"/"day"/"nite"): currentMap
-- while the plan still gives it hours now - else a roll, each map as likely
-- as its planned hours (M.roll_weight). Returns the spot (nil if nothing
-- needed shows up at this time), every spot scored, the odds of the roll
-- ({{spot, share}, ...}, most likely first; nil when it stayed) and the
-- planner's result.
function M.choose(section, plan, time, currentMap)
    local scored, r = M.score_spots(section, plan)
    local now, total = {}, 0
    for _, e in ipairs(scored) do
        if e.time == time then
            local w = M.roll_weight(e)
            if w > 0 then now[#now + 1] = {e, w}; total = total + w end
        end
    end
    if #now == 0 then return nil, scored, nil, r end
    if currentMap then
        for _, x in ipairs(now) do if x[1].map == currentMap then return x[1], scored, nil, r end end
    end
    table.sort(now, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end; return a[1].map < b[1].map end)
    local odds = {}
    for _, x in ipairs(now) do odds[#odds + 1] = {x[1], x[2] / total} end
    local rnd = math.random() * total
    for _, x in ipairs(now) do
        rnd = rnd - x[2]
        if rnd <= 0 then return x[1], scored, odds, r end
    end
    return now[#now][1], scored, odds, r
end

-- ------------------------------------------------------------ in the game

-- Two tiles next to each other where wild ones appear, that we can walk to:
-- the nearest to where we are (or the map's first such), checked with the
-- route planner (Route 36's west grass is behind the Sudowoodo).
-- Where to pace on a map: world.lua's shared picker (nobody standing on
-- it, reachable, near us or the map's entrances).
local function spot_tiles(key, flag)
    local w = State.where()
    return World.pace_pair(key, {map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
end

local function key_of_const(const)
    for k, m in pairs(World.data.maps) do if m.const == const then return k end end
    return nil
end

-- Hunt the section until its gym-blocking forms are had. opts: the walker's
-- (say, should_stop, catch...), allShiny (the testing switch). Returns true
-- when done, or false and why ("stopped", "box full", "shiny", ...).
function M.run(section, opts)
    local say = opts.say or log
    local flag = State.flag_checker(World.data.flags)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.catch = true
    o.hunting = true
    local encounters, lastMap, lastTime, waitingSaid = 0, nil, nil, false
    local lastRemaining, rollMap, rollTime = nil, nil, nil
    local onOver, onCaught = opts.on_battle_over, opts.on_caught
    local logged = 0
    o.on_battle_over = function(sp, lv)
        encounters = encounters + 1
        if onOver then onOver(sp, lv) end
        if encounters >= logged + 100 then logged = encounters; say(string.format("%d encounters so far this hunt.", encounters)) end
    end
    -- (testing: one caught - not that species again until the next re-plan says it's still needed)
    local curTargets = nil       -- (what the overlay's TARGET shows now)
    local function refresh_overlay()
        local okP, p = pcall(Goals.plan, section, C.all(), {allShiny = opts.allShiny})
        if not (okP and p) then return end
        M.tell_overlay(p, opts)
        if opts.on_targets and curTargets then
            local open = {}
            for _, c in ipairs(p.catch) do if (c.need or 0) > 0 then open[c.species] = true end end
            local left = {}
            for _, t in ipairs(curTargets) do if open[t] then left[#left + 1] = t end end
            curTargets = left
            pcall(opts.on_targets, left)
        end
    end
    o.on_caught = function(sp, lv, caught)
        if caught and o.catch_species then o.catch_species[sp] = nil end
        -- (one regular one for the job is enough: no more until the next re-plan)
        if caught and o.roleCatch then
            o.catch_species, o.roleCatch = nil, nil
            M.needCenter = M.needCenter or "a new catcher caught - the team is picked again at a Pokemon Center"
        end
        -- (the overlay at once, not at the next re-plan up to PACES paces
        -- later - the user, 2026-11-10: "the sprite should turn colored
        -- instantly just like the disappearing pointer"): what's owned now,
        -- the icons in colour, the targets still needed
        if caught then refresh_overlay() end
        if onCaught then onCaught(sp, lv, caught) end
    end
    -- (a real shiny - the walker tells on_shiny, not on_caught: the same at
    -- once; the 2nd shiny Spinarak's icon stayed grey, 2026-11-10)
    local onShiny = opts.on_shiny
    o.on_shiny = function(sp, lv, caught)
        if caught then refresh_overlay() end
        if onShiny then onShiny(sp, lv, caught) end
    end
    local planNote = nil
    local planSaid = nil
    local roleSaid, roleSpotSaid = nil, nil
    -- (the next rotation, rolled one ahead - the user, 2026-11-09: NEXT
    -- ROTATION is where it goes at the next change, so it can be shown)
    local preMap, preTime, preFor, preName = nil, nil, nil, nil
    local remindStep, remindFor = nil, nil
    local trainingFp = nil
    local orderCheckedAt = 0     -- (when the hunting order was last checked)
    local boxTried = nil       -- (the full box a Center visit was made for)
    local healTried = nil        -- (the HP/status a heal was last tried for: not again for the same)
    while true do
        if opts.should_stop and opts.should_stop() then return false, "stopped" end
        local owned = C.all()
        local plan = Goals.plan(section, owned, {allShiny = opts.allShiny})
        M.tell_overlay(plan, opts)
        -- (the keepers' evolutions are stopped; friendship copies ride along
        -- in the party - the steps raise it)
        if Walker.fighter then Walker.fighter.no_evolve = plan.keepers end
        if Walker.teamer then
            local keep = {}
            for _, e in ipairs(plan.evolve) do
                for _, step in ipairs(e.path or {}) do if step[1] == "happiness" and e.fp then keep[e.fp] = true end end
            end
            Walker.teamer.keep = keep
        end
        -- (the hunt's job is catching: once nothing's left to catch, it's over -
        -- what's still to evolve is the next part's)
        local toCatch = 0
        for _, c in ipairs(plan.catch) do toCatch = toCatch + c.need end
        if toCatch == 0 then
            if opts.on_targets then pcall(opts.on_targets, {}) end
            if trainingFp and M.training then M.training.restore() end   -- (the team's own order again)
            local ev = 0
            for _, e in ipairs(plan.evolve) do if e.blocking then ev = ev + 1 end end
            if ev > 0 then
                say(string.format("Every shiny %s holds up is caught - %d evolution%s still to do before %s.", section.leader or "the gym",
                    ev, ev == 1 and "" or "s", section.leader or "the gym"))
            else
                say(string.format("Every shiny %s holds up is caught (%d forms)!", section.leader or "the gym", plan.blockingTotal))
            end
            return true
        end
        -- (the box: 6 in the party and 20 in the current box - a catch would
        -- have nowhere to go: to a Center, where the teamer changes to a box
        -- with room - it saves the game; still full after that: every box is)
        local party = C.party()
        local box = C.box(C.current_box())
        if #party >= 6 and box and #box >= 20 then
            if boxTried == C.current_box() then return false, "box full" end
            boxTried = C.current_box()
            M.needCenter = string.format("Box %d is full - changing to a box with room at the PC", C.current_box())
        end
        -- (balls running low: buy more, or earn the money from Joey)
        if M.joey then
            -- (its Center stop for balls sets the team's order too: the
            -- hunting one, catcher in front - the user, 2026-11-11: after a
            -- ball trip Croconaw led the hunt for hours)
            local jo = {}
            for k, v in pairs(opts) do jo[k] = v end
            jo.hunting = true
            local stop = M.joey.look_after(jo)
            if stop then return false, stop end
        end
        -- (a fighter under the training target: it leads, the wild ones not
        -- being caught are fought - switch-training)
        local tr = M.training and M.training.next()
        if tr then
            o.fight_wild, o.trainee = true, tr.fp or true      -- (who: the walker checks it's in front)
            if trainingFp ~= tr.fp then
                say(string.format("Training %s (Lv %d) to Lv %d while hunting%s: it leads, a teammate finishes the fights - both get the EXP.",
                    Goals.name(tr.species), tr.level, tr.target, tr.why and (" (" .. tr.why .. ")") or ""))
                trainingFp = tr.fp
            end
            -- (always marked to stay in front - a Center visit sets the team's
            -- order, and only this mark keeps the trainee first; the user saw
            -- the starter lead after one, 2026-11-08)
            M.training.front(tr.fp)
        elseif trainingFp then
            o.fight_wild, o.trainee = nil, nil
            trainingFp = nil
            say("The team's at its training target - back to running from everything not wanted.")
            M.training.restore()
        end
        -- (nobody training: the catcher in front - checked every
        -- ORDER_CHECK_SECONDS and put back through the party menu if not,
        -- whatever put it out of order; no Center needed)
        if not tr and M.training and M.training.ensure_order and os.time() - orderCheckedAt >= M.ORDER_CHECK_SECONDS then
            orderCheckedAt = os.time()
            local okO, errO = pcall(M.training.ensure_order)
            if not okO then say("(Checking the hunting order failed: " .. tostring(errO) .. ")") end
        end
        -- (pure hunting - nobody training: the party at full strength, the
        -- user's rule - anyone under M.HUNT_HP or with a status: a Center)
        -- (the healer - Milk Drink, Softboiled - tops them up first, and
        -- its own HP doesn't count: it doesn't fight in the grass)
        if (not tr or M.needCenter) and Walker.bag and Walker.heal_at then
            local function find_low()
                local party = Walker.bag.party()
                local h = Walker.healer_index and Walker.healer_index(C.party())
                local low = nil
                for i, p in ipairs(party) do
                    local hpLow = i ~= h and p.hp < M.HUNT_HP * p.maxhp
                    if not p.egg and p.maxhp > 0 and (hpLow or (p.hp > 0 and p.status ~= 0) or p.hp == 0) then
                        low = low or p
                    end
                end
                return low
            end
            local low = (not tr) and find_low() or nil
            if low and low.hp > 0 and low.status == 0 and Walker.field_heal and Walker.field_heal(1, {say = say}) > 0 then
                low = find_low()
                if not low then say("The healer topped the team up - hunting on, no Center needed.") end
            end
            local sig = low and (low.species .. ":" .. low.hp .. ":" .. low.status) or nil
            local why = M.needCenter
            if why then M.needCenter = nil end
            if (low and sig ~= healTried) or why then
                if low then healTried = sig end
                local w = State.where()
                local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
                if c then
                    if low then
                        say(string.format("Hunting at full strength: %s is at %d/%d HP%s - to the %s first.", Goals.name(low.species), low.hp, low.maxhp,
                            low.status ~= 0 and " with a status" or "", Walker.center_name(c.key)))
                    else
                        say(string.format("%s - to the %s.", why, Walker.center_name(c.key)))
                    end
                    local stop = Walker.heal_at(c, {}, o, say)
                    if stop then return false, stop end
                    lastMap = nil       -- (say where the hunt goes on - back to the same spot, no new roll)
                end
            end
        end
        local time = (State.time_of_day() or "DAY"):lower()
        -- (stay - unless the time of day changed or something was caught:
        -- then roll again. A trip - a Center, Joey, a Mart - comes back to
        -- the same spot: the user saw it move every few minutes)
        local remaining = 0
        for _, c in ipairs(plan.catch) do remaining = remaining + c.need end
        local stay = (time == rollTime and remaining == lastRemaining) and rollMap or nil
        -- (the time of day changed: the spot rolled for it beforehand)
        if not stay and time ~= rollTime and time == preTime and remaining == lastRemaining then stay = preMap end
        local spot, scored, odds, planned = M.choose(section, plan, time, stay)
        if stay and spot and spot.map == stay then odds = nil end
        -- (the plan, each time it changes - after a catch)
        if planned then
            local text = M.describe_plan(scored, function(m) local k = key_of_const(m); return k and World.map(k).name or m end)
            if text ~= planSaid then
                planSaid = text
                say(string.format("Hunt plan - each time of day's hours, to catch every shiny still needed soonest (about %d days on average): %s.",
                    math.floor(planned.finish + 0.5), text))
            end
        end
        lastRemaining = remaining
        rollMap, rollTime = spot and spot.map, time
        -- (a catcher missing - the Caterpie, then the Zubat once Butterfree
        -- is trained: straight to where its species is met now, catch it,
        -- train it, then the shiny hunt - the user, 2026-11-09)
        local roleSp, roleJob = nil, nil
        if M.role_species then roleSp, roleJob = M.role_species(time) end
        if roleSp and #roleSp > 0 then
            local rs, best = M.role_spot(section, time, roleSp, scored)
            if rs then
                spot = rs
                odds = nil
                rollMap = nil          -- (once it's caught: a fresh roll)
                local k = key_of_const(best.map)
                local note = string.format("Off to %s for a %s - the %s (%d%% of encounters there now).", k and World.map(k).name or best.map,
                    Goals.name(roleSp[1]), roleJob or "catcher", best.pct)
                if note ~= roleSpotSaid then say(note); roleSpotSaid = note end
            end
        end
        if spot and odds and #odds > 1 then
            local list = {}
            for i = 1, math.min(#odds, 5) do
                local k = key_of_const(odds[i][1].map)
                list[#list + 1] = string.format("%s %d%%", k and World.map(k).name or odds[i][1].map, math.floor(odds[i][2] * 100 + 0.5))
            end
            local k = key_of_const(spot.map)
            say(string.format("Rolled where to hunt (by the hours the plan gives each now): %s -> %s.", table.concat(list, ", "),
                k and World.map(k).name or spot.map))
        end
        curTargets = spot and spot.species or {}
        if opts.on_targets then pcall(opts.on_targets, curTargets) end
        -- The next rotation: rolled once per (time of day, catches left) -
        -- said in the log and shown as the overlay's NEXT ROTATION.
        local function place(map) local k = key_of_const(map); return k and World.map(k).name or map end
        local nt = M.NEXT_TIME[time]
        local forKey = time .. "|" .. remaining .. "|" .. tostring(spot and spot.map)
        if nt and forKey ~= preFor then
            preFor = forKey
            local nspot = M.choose(section, plan, nt)
            preMap, preTime = nspot and nspot.map, nt
            preName = nspot and place(nspot.map) or nil
            local text = preName and string.format("%s - %s", M.TIME_TEXT[nt], preName) or string.format("%s - nothing to hunt then", M.TIME_TEXT[nt])
            -- (the same spot again: it stays - the user, 2026-11-10: "staying
            -- in dark cave for the next rotation", not "Next rotation: Dark Cave")
            if spot and nspot and nspot.map == spot.map then
                say(string.format("Staying in %s for the next rotation (%s).", preName, M.TIME_TEXT[nt]))
            else
                say(string.format("Next rotation, at %s: %s.", M.TIME_TEXT[nt], preName or "nothing still needed shows up then"))
            end
            if opts.on_next then pcall(opts.on_next, text) end
        end
        -- (every hour, and 30 minutes before the change: how long it stays)
        if spot then
            local okC, _, hh, mm = pcall(State.clock)
            if okC and hh then
                local left = M.minutes_left(time, hh, mm)
                local step = M.reminder_step(left)
                local rk = time .. "|" .. spot.map
                if rk ~= remindFor then remindFor, remindStep = rk, step
                elseif step < (remindStep or step) then
                    remindStep = step
                    say(M.reminder_text(place(spot.map), left, preName, preTime))
                end
            end
        end
        if not spot then
            if not waitingSaid then
                say(string.format("Nothing still needed shows up in the %s - waiting for the time of day to change.", time))
                waitingSaid = true
            end
            for _ = 1, 60 * 60 do
                emu.frameadvance()
                if opts.should_stop and opts.should_stop() then return false, "stopped" end
            end
        else
            waitingSaid = false
            -- (testing: the needed species at this spot are caught even when not shiny)
            if opts.allShiny then
                o.catch_species = {}
                for _, c in ipairs(plan.catch) do if c.need > 0 then o.catch_species[c.species] = true end end
            else
                -- (a regular one for an empty catcher or second-catcher slot -
                -- the only jobs a regular Pokemon may be caught for, testing
                -- or the stream: the user, 2026-11-08. One: after a catch
                -- the next re-plan asks again, with it owned)
                o.catch_species, o.roleCatch = nil, nil
                local rc, why = nil, nil
                if M.role_catch then rc, why = M.role_catch(time, spot) end
                if rc and next(rc) then
                    o.catch_species, o.roleCatch = rc, true
                    if why and why ~= roleSaid then say(why); roleSaid = why end
                end
            end
            local key = key_of_const(spot.map)
            if not key then return false, "no map " .. spot.map end
            if spot.map ~= lastMap or time ~= lastTime then
                local names = {}
                for _, sp in ipairs(spot.species) do names[#names + 1] = Goals.name(sp) end
                local why = ""
                if spot.onlyNow and #spot.onlyNow > 0 then
                    local own = {}
                    for _, sp in ipairs(spot.onlyNow) do own[#own + 1] = Goals.name(sp) end
                    local word = ({morn = "morning", day = "day", nite = "night"})[time] or time
                    why = string.format(" (%s-only: %s)", word, table.concat(own, ", "))
                end
                say(string.format("Hunting on %s (%s): %d%% of encounters there are still needed - %s.%s", World.map(key).name, time,
                    spot.share, table.concat(names, ", "), why))
                local note = string.format("%d of %d forms; to catch: ", plan.have, plan.total)
                local c = {}
                for _, e in ipairs(plan.catch) do if e.need > 0 then c[#c + 1] = Goals.name(e.species) .. " x" .. e.need end end
                note = note .. table.concat(c, ", ")
                if note ~= planNote then say(note .. "."); planNote = note end
                lastMap, lastTime = spot.map, time
            end
            local pair = spot_tiles(key, flag)
            if not pair then return false, "no way to the grass on " .. World.map(key).name end
            -- (1.2's walking pattern: a loop round the edge of the grass patch)
            -- (a new loop each round in a big patch: WalkLoop.pacer)
            local pacer = WalkLoop.pacer(World, key, pair, flag)
            for p = 1, M.PACES do
                local w = State.where()
                local t = pacer:next(w.map == key and w.x or nil, w.map == key and w.y or nil)
                local ok, why = Walker.go({map = key, x = t[1], y = t[2], pacing = true}, o)
                if not ok and tostring(why):match("^no route") and not pacer.pairOnly then
                    -- (a loop tile we can't get to: the two tiles, as before)
                    pacer:fallback()
                    ok = true
                end
                if not ok then return false, why end
                if (State.time_of_day() or "DAY"):lower() ~= time then break end
            end
        end
    end
end

return M
