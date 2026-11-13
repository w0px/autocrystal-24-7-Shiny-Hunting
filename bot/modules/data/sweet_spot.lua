-- sweet_spot.lua (lives in modules/data/)
-- The catcher's level band for a section (the user, 2026-11-08: "find a
-- sweet spot where the hunter outspeeds but doesn't crit the enemy to
-- death"). Trained past it, every move it has could knock a shiny out with
-- a critical hit - so it couldn't weaken anything safely any more; below
-- it, wild ones move first (a wild Gastly's Hypnosis on our catcher).
--
-- For every species still to catch in the section, at the levels it
-- appears there (battle_data's wild tables):
--   * low end - the catcher's Speed beats its best possible Speed (its
--     highest level there, Speed DV 15);
--   * high end - the catcher still has a safe weakening move whose WORST
--     case (top roll, critical hit, data/fighter.lua's max_damage) can't
--     knock out its weakest possible copy (lowest level there, DVs 0) from
--     full HP - and that move hurts it at all.
-- The catcher's stats at a level come from the game's formula with its
-- own DVs and no stat experience; its moves are the ones it has plus the
-- ones it learns by then. A species nothing it has can hurt is left out of
-- the high end (it can't be weakened either way).
--
-- Below Falkner the wild ones go down to Lv 2: their weakest copies have
-- so little HP that no level is safe against all of them - each level up
-- only makes fewer of them safe. So the sweet spot is the first level that
-- outspeeds them all, and no higher (the in-battle check decides each
-- real shiny anyway: data/fighter.lua's weaken_move).
-- M.band(mon, targets) -> {low, train, cover, coverNow, slow} - plain,
-- tested offline.

local M = {}
local D, Fighter

function M.setup(battleData, fighter)
    D, Fighter = battleData, fighter
end

-- Gen 2 stats at level L: base, DV, no stat experience.
local function stat(base, dv, L) return math.floor((base + dv) * 2 * L / 100) + 5 end
local function hp_stat(base, dv, L) return math.floor((base + dv) * 2 * L / 100) + L + 10 end

-- A battle-ready mon table (as data/fighter.lua reads one) for species at
-- level L with DVs (atk, def, spd, spc).
function M.at_level(species, L, atk, def, spd, spc, moves)
    local s = D.species[species]
    local b = s[1]
    local hpDv = (atk & 1) * 8 + (def & 1) * 4 + (spd & 1) * 2 + (spc & 1)
    local m = {species = species, level = L, hp = hp_stat(b[1], hpDv, L), atk = stat(b[2], atk, L), def = stat(b[3], def, L),
        spd = stat(b[4], spd, L), sat = stat(b[5], spc, L), sdf = stat(b[6], spc, L), t1 = s[2], t2 = s[3], status = 0, moves = {}}
    m.maxhp = m.hp
    for i, id in ipairs(moves or {}) do m.moves[i] = {id, 20} end
    return m
end

-- The moves it has by level L: the ones it knows plus its level-up moves
-- up to L (the newest four - what the game would have taught it).
local function moves_by(mon, L)
    local seen, list = {}, {}
    for _, id in ipairs(mon.moves or {}) do if not seen[id] then seen[id] = true; list[#list + 1] = id end end
    for _, lm in ipairs(D.learn[mon.species] or {}) do
        if lm[1] > (mon.level or 1) and lm[1] <= L and not seen[lm[2]] then seen[lm[2]] = true; list[#list + 1] = lm[2] end
    end
    return list
end

-- Whether `me` has a safe weakening move against `them` that hurts it:
-- true / false, or nil when nothing it has hurts it at all.
local function can_weaken(me, them)
    local hurts = false
    for _, mv in ipairs(me.moves) do
        if Fighter.expected(me, them, mv[1]) > 0 then
            hurts = true
            if Fighter.weaken_move({moves = {mv}, level = me.level, atk = me.atk, sat = me.sat, t1 = me.t1, t2 = me.t2, item = 0}, them) then
                return true
            end
        end
    end
    if hurts then return false end
    return nil
end

-- targets: {{species, low, high}, ...} (levels it appears at in the section).
-- Every level a target appears at counts once (its weakest copy there).
-- Returns {low = the first level it outspeeds them all (nil: never by Lv
-- 100), train = the level to train it to, cover = share of the targets'
-- levels it can weaken safely at `train`, coverNow = the same at its level
-- now, slow = a target it doesn't outspeed now}.
function M.band(mon, targets)
    local atkDv, defDv = mon.dvs[1] >> 4, mon.dvs[1] & 15
    local spdDv, spcDv = mon.dvs[2] >> 4, mon.dvs[2] & 15
    local start = mon.level or 1
    local function me_at(L) return M.at_level(mon.species, L, atkDv, defDv, spdDv, spcDv, moves_by(mon, L)) end
    local function cover(me)
        local yes, all = 0, 0
        for _, t in ipairs(targets) do
            for l = t.low, t.high do
                local w = can_weaken(me, M.at_level(t.species, l, 0, 0, 0, 0))
                if w ~= nil then all = all + 1; if w then yes = yes + 1 end end
            end
        end
        return all > 0 and yes / all or 0
    end
    local out = {}
    for L = start, 100 do
        local me = me_at(L)
        local fast, slow = true, nil
        for _, t in ipairs(targets) do
            if me.spd <= M.at_level(t.species, t.high, 15, 15, 15, 15).spd then fast = false; slow = slow or t end
        end
        if L == start then out.slow = slow end
        if fast then out.low = L; break end
    end
    out.train = out.low or start
    out.coverNow = cover(me_at(start))
    out.cover = cover(me_at(out.train))
    return out
end

-- What mon can weaken safely at level L (its level now if nil): a set of
-- "species:level" keys over the targets' levels, and how many there are.
function M.covers(mon, targets, L)
    L = L or mon.level or 1
    local me = M.at_level(mon.species, L, mon.dvs[1] >> 4, mon.dvs[1] & 15, mon.dvs[2] >> 4, mon.dvs[2] & 15, moves_by(mon, L))
    local set, n = {}, 0
    for _, t in ipairs(targets) do
        for l = t.low, t.high do
            if can_weaken(me, M.at_level(t.species, l, 0, 0, 0, 0)) then set[t.species .. ":" .. l] = true; n = n + 1 end
        end
    end
    return set, n
end

-- A second, low-level catcher (the user, 2026-11-08: "a lv 2 Zubat does
-- not have to get caught by the main catcher"): how many of the targets'
-- levels mon can weaken safely that the main catcher (at its sweet spot)
-- can't - nil if none. A bit for bulk breaks ties: it has to take a hit
-- or two while it weakens.
-- main: what the main catcher covers (M.main_cover), so it's worked out once.
function M.main_cover(catcher, targets)
    if not catcher then return {} end
    local band = M.band(catcher, targets)
    return (M.covers(catcher, targets, band.train))
end
-- (the user, 2026-11-08: a Lv 3 Caterpie needs 13 Tackles on a Geodude -
-- "a 2nd weakener a bit stronger and more suitable": how FAST it weakens
-- counts too. Each target level it can weaken safely (that the main one
-- can't) is worth 1 if it gets there - CATCH_HP - in M.FAST_HITS hits or
-- fewer, less the more it needs (13 hits: 4/13). Its level can go up to
-- M.SECOND_MAX_UP levels for that - never as far as its next evolution;
-- returns the score at its best level, that level, and the levels it
-- covers there.)
M.FAST_HITS = 4
-- (the lowest level within this share of the best score: the curve is
-- flat - a Zubat with Attack DV 11 scored 37.3 at Lv 8 and 37.9 at Lv 11,
-- and was trained to 11 for under 2% (the user's log, 2026-11-09). Lower
-- is less training and less chance of a crit knocking a Lv 2 out.)
M.SECOND_TOLERANCE = 0.02
M.SECOND_MAX_UP = 30   -- (its whole range up to before its evolution: the same answer whenever it is asked - with 6 it crept up as it levelled, the user's log 2026-11-09)
local function weaken_hits(me, them)
    local slot, id = Fighter.weaken_move({moves = me.moves, level = me.level, atk = me.atk, sat = me.sat, t1 = me.t1, t2 = me.t2, item = 0}, them)
    if not slot then return nil end
    local e = Fighter.expected(me, them, id)
    if e <= 0 then return nil end
    return math.max(1, math.ceil(them.hp * (1 - (Fighter.CATCH_HP or 0.4)) / e))
end
M.weaken_hits = weaken_hits
function M.second_value(mon, main, targets, L)
    L = L or mon.level or 1
    local me = M.at_level(mon.species, L, mon.dvs[1] >> 4, mon.dvs[1] & 15, mon.dvs[2] >> 4, mon.dvs[2] & 15, moves_by(mon, L))
    local v, gain = 0, 0
    for _, t in ipairs(targets) do
        for l = t.low, t.high do
            if not main[t.species .. ":" .. l] then
                local h = weaken_hits(me, M.at_level(t.species, l, 0, 0, 0, 0))
                if h then gain = gain + 1; v = v + math.min(1, M.FAST_HITS / h) end
            end
        end
    end
    return v, gain
end
local function next_evolution_level(sp)
    for _, e in ipairs(D.evos and D.evos[sp] or {}) do
        if e[1] == "level" then return tonumber(e[2]) end
    end
    return nil
end
function M.second_score(mon, main, targets)
    local from = mon.level or 1
    local to = math.min(100, from + M.SECOND_MAX_UP)
    local evo = next_evolution_level(mon.species)
    if evo then to = math.min(to, evo - 1) end
    -- (its best level over its whole range - from Lv 2; one already past it
    -- stays where it is: no more EXP to chase a second-best further up)
    local best, bestL, bestGain
    for L = math.min(from, 2), math.max(from, to) do
        local v, g = M.second_value(mon, main, targets, L)
        if v > 0 and (not best or v > best + 1e-9) then best, bestL, bestGain = v, L, g end
    end
    if not best then return nil end
    for L = math.min(from, 2), bestL - 1 do
        local v, g = M.second_value(mon, main, targets, L)
        if v > 0 and v >= best * (1 - M.SECOND_TOLERANCE) then best, bestL, bestGain = v, L, g; break end
    end
    if bestL < from then
        best, bestGain = M.second_value(mon, main, targets, from)
        bestL = from
        if best <= 0 then return nil end
    end
    local b = D.species[mon.species][1]
    return best + (b[1] + b[3] + b[6]) / 1000, bestL, bestGain
end

-- A wild one's moves at level L: its level-up moves up to L, the newest
-- four (what the game gives a wild Pokemon).
function M.wild_moves(sp, L)
    local list = {}
    for _, lm in ipairs(D.learn[sp] or {}) do
        if lm[1] <= L then
            for i = #list, 1, -1 do if list[i] == lm[2] then table.remove(list, i) end end
            list[#list + 1] = lm[2]
        end
    end
    while #list > 4 do table.remove(list, 1) end
    return list
end

-- How much a catcher gets hurt before its sleep move lands (the user,
-- 2026-11-08: Gastly vs Butterfree - accuracy isn't everything): over the
-- targets' levels, the damage a wild one does in a turn (it picks a move
-- at random - the average of its moves, status ones count 0), as a share
-- of the catcher's HP, times the turns it's awake: 100 / accuracy tries,
-- one less if the catcher moves first. A Ghost takes no Tackle. Returns
-- the share (0.1 = a tenth of its HP) and the worst target ("Pidgey Lv 6").
function M.catcher_risk(mon, targets, acc)
    if not targets or #targets == 0 or not acc or acc <= 0 then return 0 end
    local L = mon.level or 1
    local me = M.at_level(mon.species, L, mon.dvs[1] >> 4, mon.dvs[1] & 15, mon.dvs[2] >> 4, mon.dvs[2] & 15, moves_by(mon, L))
    local sum, n, worst, worstShare = 0, 0, nil, -1
    for _, t in ipairs(targets) do
        for l = t.low, t.high do
            local moves = M.wild_moves(t.species, l)
            local them = M.at_level(t.species, l, 8, 8, 8, 8, moves)
            local dmg = 0
            for _, id in ipairs(moves) do dmg = dmg + Fighter.expected(them, me, id) end
            dmg = #moves > 0 and dmg / #moves or 0
            local turns = 100 / acc - ((me.spd > them.spd) and 1 or 0)
            local share = dmg / me.maxhp * turns
            sum, n = sum + share, n + 1
            if share > worstShare then worst, worstShare = t.species .. ":" .. l, share end
        end
    end
    return n > 0 and sum / n or 0, worst
end

-- The section's still-needed species with their levels there:
-- {{species, low, high}, ...}. need: {[species] = true}.
function M.targets(section, need)
    local lv = {}
    for _, mp in ipairs(section.maps) do
        for _, tbl in ipairs({D.wild_grass[mp] or {}}) do
            for _, time in ipairs({"morn", "day", "nite"}) do
                for _, slot in ipairs(tbl[time] or {}) do
                    local l, sp = slot[1], slot[2]
                    if need[sp] then
                        local e = lv[sp] or {species = sp, low = l, high = l}
                        e.low, e.high = math.min(e.low, l), math.max(e.high, l)
                        lv[sp] = e
                    end
                end
            end
        end
    end
    local out = {}
    for _, e in pairs(lv) do out[#out + 1] = e end
    table.sort(out, function(a, b) return a.species < b.species end)
    return out
end

return M
