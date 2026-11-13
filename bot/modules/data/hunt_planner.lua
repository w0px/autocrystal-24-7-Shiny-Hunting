-- hunt_planner.lua (lives in modules/data/)
-- Where the hunt spends its hours (the user, 2026-11-10: "why is the bot on
-- Route 29 at night? there is no gain from it - Rattata can be hunted in
-- Sprout Tower more efficiently and Hoothoot is encounterable almost
-- anywhere"). Replaces the stacked rules (dropping weaker spots, the night's
-- own first, "along anyway", rarity, any-time fillers) with one plan:
--
-- Every day has its hours: morning 6 (4-10 AM), day 8 (10 AM-6 PM), night 10
-- (6 PM-4 AM). Each time of day's hours are split between the spots met then
-- so the section's shinies are all caught soonest: each species still
-- needed takes need / (shinies a day it's met at) days; the plan makes the
-- slowest of them as fast as it can be, then the next slowest, and so on
-- (it minimizes the sum of each species' days to the POWER-th power - with a
-- high power that's "the slowest first", and spare hours go to whatever's
-- furthest behind). The roll at a time of day then follows those hours.
--
-- So a spot gets hours only for what it's really best at: Route 29 at night
-- is Hoothoot (met with Spinarak, Poliwag, Gastly on Routes 30/31/36 too)
-- and Rattata (met by day too, in Sprout Tower 100%): no hours while those
-- others are still needed. Sprout Tower at night is 85% Gastly against 5%
-- on the routes: the night's Gastly hours go there.
--
-- Time per encounter, in game time (= real time on the 1x stream), measured
-- on the dev bot's logs (2026-11-09/10: 159 encounters a game hour on the
-- grass, rate 10; 133 in Dark Cave, rate 4): BATTLE_SECS for the battle
-- (in, run, out) plus WALK_SECS / rate for the steps to meet one - a 10%
-- grass patch about 23 s, Dark Cave (4%) 27 s, Sprout Tower (2%) 34 s.
-- (The old maths counted Sprout Tower 5x slower than grass - per step -
-- it's about 1.5x: the battle is most of an encounter.)
--
-- Plain functions on tables, tested offline (walker/test_hunt.lua).

local M = {}

M.HOURS = {morn = 6, day = 8, nite = 10}
M.TIMES = {"morn", "day", "nite"}
M.SHINY = 8192          -- 1 in 8192 wild ones is shiny
M.BATTLE_SECS = 20
M.WALK_SECS = 28
M.POWER = 8
M.ITER = 1500
M.MIN_SHARE = 0.01      -- a spot under this share of its time of day: none (the solver's leftovers)
-- This time of day's own first (the user, 2026-11-10: "I don't see the point
-- of sitting in Dark Cave at night - Dunsparce gets farmed passively in the
-- morning, and we can sit Dark Cave at night once the other night
-- encounters are caught - use it as a filler after"): while a species met
-- ONLY at this time of day is still needed, this time's hours go to those;
-- species met at other times too count here only as they come along. Once
-- the time's own ones are all caught, its hours are filler for the rest.
-- The section's finish is the same (the mornings hold it up either way);
-- the catches just come sooner.
M.OWN_FIRST = true

-- Seconds of game time per encounter on a map with this encounter rate (% of steps).
function M.secs(rate) return M.BATTLE_SECS + M.WALK_SECS / (rate or 10) end

-- spots(section, need, spotsBySpecies) -> {{map, time, rate, secs, pct =
-- {[species] = %}, needed = {species...}}, ...}: every (map, time of day)
-- where something still needed is met. spotsBySpecies: Goals.spots(section).
function M.spots(need, spotsBySpecies)
    local byKey, list = {}, {}
    for sp, entries in pairs(spotsBySpecies) do
        for _, s in ipairs(entries) do
            local times = s.time == "any" and M.TIMES or {s.time}
            for _, t in ipairs(times) do
                local k = s.map .. "|" .. t
                local e = byKey[k]
                if not e then
                    e = {map = s.map, time = t, rate = s.rate or 10, secs = M.secs(s.rate), pct = {}, needed = {}}
                    byKey[k] = e
                end
                e.pct[sp] = (e.pct[sp] or 0) + s.pct
            end
        end
    end
    for _, e in pairs(byKey) do
        for sp in pairs(e.pct) do if (need[sp] or 0) > 0 then e.needed[#e.needed + 1] = sp end end
        if #e.needed > 0 then table.sort(e.needed); list[#list + 1] = e end
    end
    table.sort(list, function(a, b) if a.time ~= b.time then return a.time < b.time end; return a.map < b.map end)
    return list
end

-- solve(spots, need) -> hours (list, hours a day at each spot), days
-- ({[species] = days to catch what's needed of it, on average}), finish
-- (the slowest species' days: the section, on average - a little more in
-- practice, luck evens out slower than that).
-- Frank-Wolfe on sum(days^POWER): each round, at each time of day, the spot
-- that cuts it most gets a step of that time's hours.
function M.solve(spots, need)
    local per = {}                              -- spot -> {{species, shinies an hour}, ...}
    local species = {}
    for j, e in ipairs(spots) do
        per[j] = {}
        local perHour = 3600 / e.secs / M.SHINY
        for _, sp in ipairs(e.needed) do
            per[j][#per[j] + 1] = {sp, perHour * e.pct[sp] / 100}
            species[sp] = true
        end
    end
    local byTime = {}
    for j, e in ipairs(spots) do byTime[e.time] = byTime[e.time] or {}; table.insert(byTime[e.time], j) end
    -- (the needed species met only at one time of day: {[time] = {[species] = true}})
    local own = {}
    if M.OWN_FIRST then
        local times = {}
        for _, e in ipairs(spots) do
            for _, sp in ipairs(e.needed) do times[sp] = times[sp] or {}; times[sp][e.time] = true end
        end
        for sp, ts in pairs(times) do
            local n, one = 0, nil
            for t in pairs(ts) do n = n + 1; one = t end
            if n == 1 then own[one] = own[one] or {}; own[one][sp] = true end
        end
    end
    -- (start: each time of day's hours shared evenly)
    local x = {}
    for t, js in pairs(byTime) do for _, j in ipairs(js) do x[j] = M.HOURS[t] / #js end end
    local function supply()
        local s = {}
        for j in ipairs(spots) do
            for _, a in ipairs(per[j]) do s[a[1]] = (s[a[1]] or 0) + x[j] * a[2] end
        end
        return s
    end
    for it = 1, M.ITER do
        local s = supply()
        local worst = 0
        for sp in pairs(species) do worst = math.max(worst, need[sp] / s[sp]) end
        -- (the pull on each species: (days / the worst)^POWER / supply)
        local pull = {}
        for sp in pairs(species) do pull[sp] = (need[sp] / s[sp] / worst) ^ M.POWER / s[sp] end
        local g = 1 - 2 / (it + 2)
        for t, js in pairs(byTime) do
            local best, bestV, bestO = nil, -1, -1
            local mine = own[t]
            for _, j in ipairs(js) do
                -- (the time's own ones first: the others only break ties)
                local v, o = 0, 0
                for _, a in ipairs(per[j]) do
                    if not mine or mine[a[1]] then v = v + pull[a[1]] * a[2] else o = o + pull[a[1]] * a[2] end
                end
                if v > bestV * (1 + 1e-9) or (v >= bestV * (1 - 1e-9) and o > bestO) then best, bestV, bestO = j, v, o end
            end
            for _, j in ipairs(js) do x[j] = x[j] * g end
            x[best] = x[best] + (1 - g) * M.HOURS[t]
        end
    end
    -- (the solver's leftovers: under MIN_SHARE of the time's hours - none)
    for t, js in pairs(byTime) do
        local kept = 0
        for _, j in ipairs(js) do
            if x[j] < M.MIN_SHARE * M.HOURS[t] then x[j] = 0 else kept = kept + x[j] end
        end
        for _, j in ipairs(js) do x[j] = x[j] * M.HOURS[t] / kept end
    end
    local s = supply()
    local days, finish = {}, 0
    for sp in pairs(species) do
        days[sp] = s[sp] > 0 and need[sp] / s[sp] or math.huge      -- (s: shinies a day)
        finish = math.max(finish, days[sp])
    end
    return x, days, finish
end

-- (solve is slow-ish - 1500 rounds; the same needs and the same wild
-- tables give the same plan)
local cache, cacheN = {}, 0
function M.plan(need, spotsBySpecies)
    local parts = {}
    for sp, list in pairs(spotsBySpecies) do
        for _, s in ipairs(list) do
            parts[#parts + 1] = table.concat({sp, s.map, s.time, s.pct, s.rate or 10, need[sp] or 0}, "/")
        end
    end
    table.sort(parts)
    local key = (M.OWN_FIRST and "own|" or "") .. M.POWER .. "|" .. table.concat(parts, ",")
    if cache[key] then return cache[key] end
    local spots = M.spots(need, spotsBySpecies)
    local hours, days, finish = M.solve(spots, need)
    for j, e in ipairs(spots) do e.hours = hours[j] end
    local r = {spots = spots, days = days, finish = finish}
    if cacheN > 200 then cache, cacheN = {}, 0 end
    cache[key], cacheN = r, cacheN + 1
    return r
end

return M
