-- team.lua (lives in modules/data/)
-- Picks the bot's team from what it owns, the user's way (2026-11-07):
--   * the starter, always (on top of the rest);
--   * a CATCHER - the lead while hunting: puts the shiny to sleep. With
--     M.SHINY_ONLY (the stream) a shiny; for testing any Pokemon: the best sleep move by
--     accuracy (Spore, Sleep Powder, Lovely Kiss, Hypnosis, Sing...), plus
--     False Swipe, some bulk and speed (to sleep it before it sleeps us);
--   * a SECOND CATCHER or a HEALER - one slot (the user, 2026-11-08): the
--     second catcher (a low-level one for the weak targets the catcher
--     can't weaken safely) while there are any, then a healer (Softboiled,
--     Milk Drink - Miltank) once the targets are past that;
--   * 2 SPECIALISTS (M.SPECIALISTS; the user, 2026-11-08: 3 is overkill
--     for a playthrough) - caught shinies only, the best two together: what
--     they'll be (strength of the form they reach by levelling), type
--     coverage with the starter (their own types' moves hitting others for
--     double), a physical and a special attacker among them, few shared
--     weaknesses, and rarity - a rare shiny (5% Teddiursa) beats a common one
--     about as strong;
--   * an HM SLAVE - carries the HMs so the fighters keep 4 battle moves: the
--     one able to learn the most of them, preferably no fighter. A shiny
--     with M.SHINY_ONLY, else any Pokemon.
-- A better team replaces the current one only when it's clearly better
-- (M.REPLACE_MARGIN), so the bot doesn't swap over small differences.
--
-- All plain functions on tables (battle_data.lua + a list of owned mons),
-- tested offline. The PC trips and training that follow are elsewhere.

local M = {}

local D
local names = {}

M.REPLACE_MARGIN = 0.08      -- a new team must score 8% more
M.PARTY = 6
M.SPECIALISTS = 2
-- The catcher's risk (play sets M.catcher_risk(mon, accuracy) -> share of
-- its HP lost before it lands its sleep move): points per 1% of HP.
M.catcher_risk = nil
M.RISK_WEIGHT = 1
-- A future catcher (the user, 2026-11-08: "if Butterfree is the main
-- catcher the bot should get it to 15 asap"): one that learns a sleep move
-- within this many levels and would then be clearly the better catcher -
-- trained to that level first. is_keeper(mon): the living dex's copy that
-- never evolves (set by play) - no Butterfree from that Caterpie.
M.PROSPECT_LEVELS = 10
M.is_keeper = nil
-- The stream's rule: every member but the starter a shiny - the catcher,
-- the HM slave and the healer too. Off for testing (regular Pokemon may
-- fill those, so everything can be seen working).
M.SHINY_ONLY = false
-- When specialists may be picked at all (play sets it: the first badge -
-- the user, 2026-11-09: "we agreed on picking the 2 specialists after
-- defeating Falkner"). Before that, shinies wait in the box untrained.
-- nil: always.
M.specialists_open = nil

-- Sleep moves (accuracy %, from the move data at setup) and the catcher's helpers.
local SLEEP = {"SPORE", "SLEEP_POWDER", "LOVELY_KISS", "HYPNOSIS", "SING"}
local HEALS = {"SOFTBOILED", "MILK_DRINK"}
local HMS = {"CUT", "FLASH", "SURF", "STRENGTH", "WHIRLPOOL", "WATERFALL", "FLY"}

local MV, SPECIAL_TYPES = {}, {}
function M.setup(battleData, speciesNames)
    D = battleData
    names = speciesNames or {}
    MV = {}
    for id, m in pairs(D.moves) do MV[m[1]] = id end
    -- (Gen 2: types from FIRE up are special - battle_data's types table)
    for id, n in pairs(D.types) do if id >= 20 then SPECIAL_TYPES[id] = true end end
end

local function name(sp) return names[sp] or ("#" .. tostring(sp)) end
M.name = name

-- The type chart as multipliers.
local function eff(atk, t1, t2)
    local x = 1
    for _, c in ipairs(D.chart) do
        if c[1] == atk then   -- (Ghost's immunities too: they hold without Foresight)
            if c[2] == t1 then x = x * c[3] / 10 end
            if c[2] == t2 and t2 ~= t1 then x = x * c[3] / 10 end
        end
    end
    return x
end
M.eff = eff

local function types_of(sp) local s = D.species[sp]; return s[2], s[3] end
local function all_types()
    local out = {}
    for id, n in pairs(D.types) do if n ~= "CURSE_TYPE" and n ~= "TYPELESS" and id ~= 19 then out[#out + 1] = id end end
    table.sort(out)
    return out
end

-- What a species becomes by levelling (level evolutions, in a chain).
function M.final_form(sp)
    local seen = {}
    while D.evos[sp] and not seen[sp] do
        seen[sp] = true
        local nxt = nil
        for _, e in ipairs(D.evos[sp]) do
            if e[1] == "level" or e[1] == "happiness" then nxt = e[3]; break end
        end
        if not nxt then break end
        sp = nxt
    end
    return sp
end

local function bst(sp) local b = D.species[sp][1]; return b[1] + b[2] + b[3] + b[4] + b[5] + b[6] end

-- Moves a mon knows or will learn by levelling up (by level `upto`).
local function learns(mon, moveId, upto)
    for _, m in ipairs(mon.moves or {}) do if m == moveId then return 0 end end
    local sp = mon.species
    for _ = 1, 3 do
        for _, lm in ipairs(D.learn[sp] or {}) do
            if lm[2] == moveId and lm[1] <= (upto or 100) then return lm[1] end
        end
        local nxt = nil
        for _, e in ipairs(D.evos[sp] or {}) do if e[1] == "level" or e[1] == "happiness" then nxt = e[3] end end
        if not nxt then break end
        sp = nxt
    end
    return nil
end
M.learns = learns

-- Rarity bonus: 0 for the commonest (30%+ at its best spot) up to ~2.5 for
-- 1%; not found wild (gifts, statics, eggs): a middling 1. By the line's
-- first form - an evolved copy was caught as that (a Pidgeot counts as the
-- Pidgey it was; the evolution stage's trained copies).
local baseOf = nil
local function line_base(sp)
    if not baseOf then
        baseOf = {}
        for from, list in pairs(D.evos or {}) do
            for _, e in ipairs(list) do if e[3] and e[1] ~= "trade" then baseOf[e[3]] = baseOf[e[3]] or from end end
        end
    end
    local seen = 0
    while baseOf[sp] and seen < 4 do sp = baseOf[sp]; seen = seen + 1 end
    return sp
end
M.line_base = line_base
function M.rarity_bonus(sp)
    sp = line_base(sp)
    local r = D.rarity[sp]
    if not r then return 1 end
    local pct = math.max(1, r[1])
    return math.max(0, math.log(30 / pct, 2)) / 2
end

-- ------------------------------------------------------------ roles

-- Catcher: {score, move, why} or nil. Its sleep move now, or by level 20.
function M.catcher_score(mon)
    local best, bestMove = 0, nil
    for _, n in ipairs(SLEEP) do
        local id = MV[n]
        local at = id and learns(mon, id, math.max(mon.level or 1, 20))
        if at then
            local acc = D.moves[id][5]
            -- (only one it knows - or has reached the level for - counts:
            -- the catcher has to put things to sleep NOW; a Lv 5 Hoothoot
            -- (Hypnosis at 16) isn't one yet)
            local s = at <= (mon.level or 1) and acc or 0
            if s > best then best, bestMove = s, id end
        end
    end
    if not bestMove or best <= 0 then return nil end
    local s = best
    if learns(mon, MV.FALSE_SWIPE, mon.level) then s = s + 30 end
    local b = D.species[mon.species][1]
    s = s + (b[1] + b[3] + b[6]) / 30          -- bulk: it stays in while the balls fly
    -- speed: moving first puts the target to sleep before it can do the
    -- same to us (a wild Gastly knows Hypnosis too) - species and level
    s = s + b[4] / 10 + (mon.level or 1) / 4
    -- what the section's wild ones do to it before it lands (M.catcher_risk,
    -- set by play: data/sweet_spot.lua) - 10% of its HP costs 10 points,
    -- about what Sleep Powder's 75% gains on Hypnosis' 60%
    if M.catcher_risk then
        local risk = M.catcher_risk(mon, best) or 0
        s = s - M.RISK_WEIGHT * 100 * risk
    end
    return s, bestMove
end

-- What species becomes by level L (level evolutions only).
function M.species_at(sp, L)
    for _ = 1, 3 do
        local nxt = nil
        for _, e in ipairs(D.evos[sp] or {}) do
            if e[1] == "level" and tonumber(e[2]) and tonumber(e[2]) <= L then nxt = e[3] end
        end
        if not nxt then break end
        sp = nxt
    end
    return sp
end

-- As a catcher once it has its best sleep move to come: {level, move, as =
-- the mon then, score} - or nil (none within M.PROSPECT_LEVELS, or it
-- knows its best one already).
function M.prospect(mon, up)
    local best = nil
    for _, n in ipairs(SLEEP) do
        local id = MV[n]
        local at = id and learns(mon, id, (mon.level or 1) + (up or M.PROSPECT_LEVELS))
        if at and at > (mon.level or 1) then
            local sp = M.species_at(mon.species, at)
            if sp ~= mon.species and M.is_keeper and M.is_keeper(mon) then at = nil end
            -- (what it is by then has to learn it then - not a later form)
            local ok = false
            for _, lm in ipairs(D.learn[sp] or {}) do if lm[2] == id and lm[1] == at then ok = true end end
            if not ok then at = nil end
            if at then
                local moves = {}
                for _, m in ipairs(mon.moves or {}) do moves[#moves + 1] = m end
                moves[#moves + 1] = id
                local as = {key = mon.key, species = sp, level = at, dvs = mon.dvs, moves = moves, shiny = mon.shiny}
                local s = M.catcher_score(as)
                if s and (not best or s > best.score) then best = {level = at, move = id, as = as, score = s} end
            end
        end
    end
    return best
end

-- Healer: score or nil.
function M.healer_score(mon)
    for _, n in ipairs(HEALS) do
        local id = MV[n]
        if id and learns(mon, id, 100) then return bst(M.final_form(mon.species)) / 100 end
    end
    return nil
end

-- HM slave (the user, 2026-11-10: "to qualify for an hm slave the pokemon
-- must at least be able to use cut"): Cut a must - the first HM the story
-- needs (Ilex Forest); then the story's other HMs a point each, Fly half,
-- Flash a quarter (never needed in Crystal - Dark Cave works without it);
-- and a bit for being a weak fighter (no loss to give it HM moves). By its
-- final form: the copy that evolves does the job (Furret, Kingler) - the
-- one that stays a Sentret or Krabby waits in the box (team.pick leaves the
-- living dex's keepers out).
local HM_POINTS = {CUT = 1, SURF = 1, STRENGTH = 1, WHIRLPOOL = 1, WATERFALL = 1, FLY = 0.5, FLASH = 0.25}
function M.hm_score(mon)
    local f = M.final_form(mon.species)
    local can = {}
    for _, h in ipairs(D.hmcompat[f] or {}) do can[h] = true end
    if not can[MV.CUT] then return nil end
    local s = 0
    for _, n in ipairs(HMS) do if can[MV[n]] then s = s + (HM_POINTS[n] or 1) end end
    return s + (600 - bst(f)) / 300
end

-- A specialist on its own: strength of its final form, rarity, and how
-- well it hits with its own types. (Gen 2: a move's type decides physical
-- or special - Fire, Water, Grass, Electric, Psychic, Ice, Dragon and Dark
-- use Special Attack, the rest Attack. So Ledian's Bug and Flying moves
-- use its Attack of 35: a poor fighter, whatever its Special.)
function M.specialist_value(mon)
    local f = M.final_form(mon.species)
    local b = D.species[f][1]
    local t1, t2 = types_of(f)
    local physical = not SPECIAL_TYPES[t1]
    local hit = physical and b[2] or b[5]
    if t2 ~= t1 and (SPECIAL_TYPES[t2] ~= nil) ~= (not physical) then
        hit = math.max(hit, SPECIAL_TYPES[t2] and b[5] or b[2])   -- (its other type may use the better stat)
    end
    local strength = bst(f) / 100 + (hit - 80) / 40      -- ~2-6 overall, +-1 for the attack it uses
    return strength + M.rarity_bonus(mon.species), physical, t1, t2
end

-- The specialists (+ the starter's types) together.
function M.team_value(specs, starter)
    local members = {}
    local value, phys, spec = 0, false, false
    for _, mon in ipairs(specs) do
        local v, physical, t1, t2 = M.specialist_value(mon)
        value = value + v
        if physical then phys = true else spec = true end
        members[#members + 1] = {t1, t2}
    end
    if starter then members[#members + 1] = {types_of(M.final_form(starter.species))} end
    -- Coverage: types something of ours hits for double with its own type.
    local covered = 0
    local types = all_types()
    for _, def in ipairs(types) do
        for _, m in ipairs(members) do
            if eff(m[1], def, def) > 1 or (m[2] ~= m[1] and eff(m[2], def, def) > 1) then covered = covered + 1; break end
        end
    end
    -- Shared weaknesses: attacking types that hit 2+ of ours for double.
    local shared = 0
    for _, atk in ipairs(types) do
        local n = 0
        for _, m in ipairs(members) do if eff(atk, m[1], m[2]) > 1 then n = n + 1 end end
        if n >= 2 then shared = shared + (n - 1) end
    end
    -- Two the same type: little point.
    local dup = 0
    for i = 1, #members do for j = i + 1, #members do
        if members[i][1] == members[j][1] then dup = dup + 1 end
    end end
    return value + covered * 0.35 - shared * 0.5 - dup * 1.5 + ((phys and spec) and 1 or 0)
end

-- The pair's three parts (the user, 2026-11-08: "coverage still matters as
-- well as rarity - I'd weight those 1/3 each - but a level 36 Pokemon
-- should be picked over a lv 20 one as a specialist"):
--   level    - their average level (an evolved, trained copy counts);
--   coverage - type coverage with the starter, shared weaknesses, the same
--              type twice, a physical and a special one, and how strong
--              their final forms are;
--   rarity   - M.rarity_bonus of each.
function M.team_parts(specs, starter)
    local members, lv, rar, strength = {}, 0, 0, 0
    local phys, spec = false, false
    for _, mon in ipairs(specs) do
        local v, physical, t1, t2 = M.specialist_value(mon)
        local r = M.rarity_bonus(mon.species)
        strength = strength + (v - r)
        rar = rar + r
        lv = lv + (mon.level or 1)
        if physical then phys = true else spec = true end
        members[#members + 1] = {t1, t2}
    end
    if #specs > 0 then lv = lv / #specs end
    if starter then members[#members + 1] = {types_of(M.final_form(starter.species))} end
    local covered, shared, dup = 0, 0, 0
    local types = all_types()
    for _, def in ipairs(types) do
        for _, m in ipairs(members) do
            if eff(m[1], def, def) > 1 or (m[2] ~= m[1] and eff(m[2], def, def) > 1) then covered = covered + 1; break end
        end
    end
    for _, atk in ipairs(types) do
        local n = 0
        for _, m in ipairs(members) do if eff(atk, m[1], m[2]) > 1 then n = n + 1 end end
        if n >= 2 then shared = shared + (n - 1) end
    end
    for i = 1, #members do for j = i + 1, #members do
        if members[i][1] == members[j][1] then dup = dup + 1 end
    end end
    local cov = strength + covered * 0.35 - shared * 0.5 - dup * 1.5 + ((phys and spec) and 1 or 0)
    return {level = lv, coverage = cov, rarity = rar}
end
M.PART_WEIGHTS = {level = 1 / 3, coverage = 1 / 3, rarity = 1 / 3}
-- Each pair's parts as a share of the best among all the pairs looked at
-- (Lv 20 against the best Lv 36: 0.56), then weighted: values in 0-1.
function M.weigh_parts(list)
    local hi = {}
    for _, p in ipairs(list) do
        for k, v in pairs(p) do if hi[k] == nil or v > hi[k] then hi[k] = v end end
    end
    local out = {}
    for i, p in ipairs(list) do
        local v = 0
        for k, w in pairs(M.PART_WEIGHTS) do
            local top = hi[k] or 0
            v = v + w * (top > 1e-9 and math.max(0, p[k]) / top or 1)
        end
        out[i] = v
    end
    return out
end

-- ------------------------------------------------------------ the team

-- owned: {{key, species, level, moves = {ids}, shiny = bool, starter = bool}, ...}
-- current: a previous result (or nil). Returns {starter, catcher, hm,
-- healer, specialists = {...}, value, why = {lines}, changed = bool}.
-- Really shiny (the testing switch marks regular ones shiny for the team -
-- collection.lua keeps the truth in realShiny).
local function real(m)
    if not m then return false end
    if m.realShiny ~= nil then return m.realShiny == true end
    return m.shiny == true
end
-- (the user, 2026-11-08: "the bot would replace the catcher as well as the
-- weakener with shinies if possible right" - a real shiny that can do a
-- job takes it from a regular one, whatever their scores; between two of
-- a kind, the better score)
-- The catcher's tier (the user's style, 2026-11-09, simpler than the day
-- before: "a regular Butterfree; if we get a shiny we replace the catcher
-- with a shiny Butterfree"): 2 a shiny of the Butterfree line, 1 a regular
-- one, nil anything else. Any Caterpie or Metapod is a future catcher
-- (Sleep Powder at 15), however far off.
M.STYLE_CATCHERS = {"CATERPIE", "METAPOD", "BUTTERFREE"}
local styleSet, styleFor, styleList = nil, nil, nil
function M.style_line(sp)
    if not styleSet or styleFor ~= names or styleList ~= M.STYLE_CATCHERS then
        styleSet, styleFor, styleList = {}, names, M.STYLE_CATCHERS
        local want = {}
        for _, n in ipairs(M.STYLE_CATCHERS) do want[n] = true end
        for id, n in pairs(names) do if type(id) == "number" and want[tostring(n):upper()] then styleSet[id] = true end end
    end
    return styleSet[sp] == true
end
-- The second catcher's regular one (the user, 2026-11-09: "thought we
-- agreed on Zubat at lv 9"): only a Zubat - its Leech Life is the one
-- regular weakening move that hurts Gastly too (all 45 target levels before
-- Falkner), trained to its best level (Lv 9, team.weakLevel). Only a shiny
-- Zubat replaces it (the user, 2026-11-09: "only zubat, it can only get
-- replaced by a shiny zubat, same with butterfree") - M.beats, shiny first.
M.STYLE_WEAK = {"ZUBAT"}
local weakSet, weakFor, weakList = nil, nil, nil
function M.weak_style(sp)
    if not weakSet or weakFor ~= names or weakList ~= M.STYLE_WEAK then
        weakSet, weakFor, weakList = {}, names, M.STYLE_WEAK
        local want = {}
        for _, n in ipairs(M.STYLE_WEAK) do want[n] = true end
        for id, n in pairs(names) do if type(id) == "number" and want[tostring(n):upper()] then weakSet[id] = true end end
    end
    return weakSet[sp] == true
end
function M.weak_ok(m) return M.weak_style(m.species) end
-- The HM slave's lines (the user, 2026-11-10: "the only hm slaves are
-- either sentret/furret or kingler later"): the first shiny Sentret
-- becomes the HM slave and is evolved to Furret; only a shiny Krabby,
-- levelled to Kingler (Cut, Surf, Strength, Whirlpool), replaces it.
-- (data/goals.lua's RESERVED_LINES gives each line's first shiny to its
-- last form.)
M.STYLE_HM = {"SENTRET", "FURRET", "KRABBY", "KINGLER"}
local hmSet, hmFor, hmList = nil, nil, nil
function M.hm_style(sp)
    if not hmSet or hmFor ~= names or hmList ~= M.STYLE_HM then
        hmSet, hmFor, hmList = {}, names, M.STYLE_HM
        local want = {}
        for _, n in ipairs(M.STYLE_HM) do want[n] = true end
        for id, n in pairs(names) do if type(id) == "number" and want[tostring(n):upper()] then hmSet[id] = true end end
    end
    return hmSet[sp] == true
end
function M.catcher_tier(m)
    local line = M.style_line(m.species)
    if not line then return nil end
    return real(m) and 2 or 1
end
-- A tie: the one in the party over one in the box - no PC trip for the
-- same thing (twins - every DV the same, Gen 2 has no ID number: the
-- user's two Spinaraks swapped at every Center, 2026-11-10).
function M.in_party_first(m, best)
    return best ~= nil and m.where == "party" and best.where ~= "party"
end
local function beats(m, s, bm, bs)
    if not bm then return true end
    local rm, rb = real(m), real(bm)
    if rm ~= rb then return rm end
    return s > bs or (s == bs and M.in_party_first(m, bm))
end
M.beats = beats

function M.pick(owned, current)
    local starter = nil
    for _, m in ipairs(owned) do if m.starter then starter = m end end
    local used = {}
    if starter then used[starter.key] = true end
    local why = {}
    local out = {starter = starter, specialists = {}}

    -- The catcher, by M.catcher_tier first (the user's style, 2026-11-09):
    -- a Butterfree - a shiny one over a regular one, nothing else. In a
    -- tier, the current catcher stays unless the other is clearly better
    -- (M.REPLACE_MARGIN).
    local bestC, bestCS, bestCM, bestCT
    local curKey = current and current.catcher and current.catcher.key
    local function c_better(m, tier, sc)
        if not bestC then return true end
        if tier ~= bestCT then return tier > bestCT end
        if bestC.key == curKey then return sc > bestCS * (1 + M.REPLACE_MARGIN) end
        if m.key == curKey then return sc * (1 + M.REPLACE_MARGIN) >= bestCS end
        return sc > bestCS or (sc == bestCS and M.in_party_first(m, bestC))
    end
    for _, m in ipairs(owned) do
        if not used[m.key] then
            local tier = M.catcher_tier(m)
            local sc, mv = nil, nil
            if tier then sc, mv = M.catcher_score(m) end
            if sc and c_better(m, tier, sc) then bestC, bestCS, bestCM, bestCT = m, sc, mv, tier end
        end
    end
    if bestC then
        used[bestC.key] = true; out.catcher = bestC
        why[#why + 1] = string.format("Catcher: %s (%s)", name(bestC.species), D.moves[bestCM][1]:gsub("_", " "):lower())
    end
    -- The future catcher: trained to its sleep move first, then it takes
    -- over at the next team pick. (Not marked used: it can be a specialist
    -- or anything else meanwhile.)
    local bestP, bestPT = nil, nil
    for _, m in ipairs(owned) do
        if m ~= bestC and not m.egg then
            -- (a higher tier than the catcher's - or the same tier and clearly
            -- better once it has its sleep move: a Caterpie trained to a
            -- Lv 15 Butterfree's Sleep Powder over a Gastly's Hypnosis)
            local tier = M.catcher_tier(m)
            local p = tier and (not bestCT or tier >= bestCT) and M.prospect(m, 100)
            if p and bestCT and tier == bestCT and p.score <= (bestCS or 0) * (1 + M.REPLACE_MARGIN) then p = nil end
            if p and (not bestP or tier > bestPT or (tier == bestPT and p.score > bestP.score)) then
                p.mon = m
                bestP, bestPT = p, tier
            end
        end
    end
    if bestP then
        out.prospect = bestP
        local m = bestP.mon
        why[#why + 1] = string.format("Future catcher: %s%s at Lv %d (%s) - trained there first", name(m.species),
            bestP.as.species ~= m.species and (" -> " .. name(bestP.as.species)) or "", bestP.level, D.moves[bestP.move][1]:gsub("_", " "):lower())
    end

    -- The specialists: the best combination of shinies left.
    local pool = {}
    local closed = M.specialists_open ~= nil and not M.specialists_open()
    if closed then why[#why + 1] = "Specialists: none yet - picked after the first badge" end
    -- (real shinies only - testing or the stream, the user 2026-11-08:
    -- "specialists fill their slots once shinies are caught")
    for _, m in ipairs(owned) do if not closed and real(m) and not used[m.key] then pool[#pool + 1] = m end end
    local bestSet, bestV = {}, 0
    local n = #pool
    local k = math.min(M.SPECIALISTS, n)
    -- (every pair looked at - and the current one - scaled together: level,
    -- coverage, rarity a third each, M.team_parts)
    local sets = {}
    local function try(set) sets[#sets + 1] = {table.unpack(set)} end
    if k == 1 then for a = 1, n do try({pool[a]}) end
    elseif k == 2 then for a = 1, n do for b = a + 1, n do try({pool[a], pool[b]}) end end
    elseif k >= 3 then for a = 1, n do for b = a + 1, n do for c = b + 1, n do try({pool[a], pool[b], pool[c]}) end end end end
    local still = nil
    if not closed and current and current.specialists and #current.specialists > 0 then
        local have = {}
        for _, m in ipairs(owned) do have[m.key] = m end
        still = {}
        for _, m in ipairs(current.specialists) do if have[m.key] and not used[m.key] and real(have[m.key]) then still[#still + 1] = have[m.key] end end
        if not (#still == #current.specialists and #still >= k and #still <= M.SPECIALISTS) then still = nil end
    end
    local parts = {}
    for i, set in ipairs(sets) do parts[i] = M.team_parts(set, starter) end
    if still then parts[#sets + 1] = M.team_parts(still, starter) end
    local vals = M.weigh_parts(parts)
    for i, set in ipairs(sets) do
        if vals[i] > bestV or #bestSet == 0 then bestSet, bestV = set, vals[i] end
    end
    -- Keep the current ones unless the new ones are clearly better.
    if still then
        local v = vals[#sets + 1]
        if bestV < v * (1 + M.REPLACE_MARGIN) + 1e-9 then bestSet, bestV = still, v end
    end
    for _, m in ipairs(bestSet) do
        used[m.key] = true
        out.specialists[#out.specialists + 1] = m
        local f = M.final_form(m.species)
        local r = D.rarity[m.species]
        why[#why + 1] = string.format("Specialist: %s%s (%s%s)", name(m.species), f ~= m.species and (" -> " .. name(f)) or "",
            D.types[D.species[f][2]]:lower() .. (D.species[f][3] ~= D.species[f][2] and ("/" .. D.types[D.species[f][3]]:lower()) or ""),
            r and string.format(", %d%% at best", r[1]) or ", not found wild")
    end
    out.value = bestV

    -- The second catcher (the user, 2026-11-08): a low-level one from the
    -- rest for the weak targets the main catcher can't weaken safely - its
    -- own slot, in the party all the time. Scored by M.weak_score(mon,
    -- catcher) (set by play: data/sweet_spot.lua) - nil once the catcher
    -- covers everything still wanted: then the slot is the healer's.
    -- (also while the future catcher trains: measured against what it will
    -- be - the Zubat is caught and trained meanwhile; the user, 2026-11-09)
    local wc = out.catcher or (out.prospect and out.prospect.as)
    if M.weak_score and wc then
        -- (its score counts how fast it weakens them too, at its best level
        -- a few up - weakLevel: trained to it, then no more EXP)
        local bestW, bestWS, bestL, bestN
        for _, m in ipairs(owned) do
            if not used[m.key] and M.weak_ok(m) then
                local s, L, n = M.weak_score(m, wc)
                if s and beats(m, s, bestW, bestWS) then bestW, bestWS, bestL, bestN = m, s, L, n end
            end
        end
        if bestW then
            used[bestW.key] = true; out.weak = bestW
            -- (set once, when it joins - recomputed at each pick it crept up a
            -- level at a time: its window starts at its level now, so Lv 8 then
            -- 9 then 10 - the user's log, 2026-11-09)
            local keep = current and current.weak and current.weak.key == bestW.key and current.weakLevel
            out.weakLevel = keep or bestL or bestW.level
            local at = (out.weakLevel > (bestW.level or 0)) and string.format(", best at Lv %d - trained there", out.weakLevel) or ""
            why[#why + 1] = string.format("Second catcher: %s Lv %d (weakens %d of the weak ones the catcher can't, worth %.1f by how fast%s)", name(bestW.species),
                bestW.level or 0, bestN or math.floor(bestWS), bestWS, at)
        end
    end

    -- The healer: the same slot, when no second catcher is needed.
    if not out.weak then
        local bestL, bestLS
        for _, m in ipairs(owned) do
            if not used[m.key] and (m.shiny or not M.SHINY_ONLY) then
                local s = M.healer_score(m)
                if s and beats(m, s, bestL, bestLS) then bestL, bestLS = m, s end
            end
        end
        if bestL then used[bestL.key] = true; out.healer = bestL; why[#why + 1] = "Healer: " .. name(bestL.species) end
    end

    -- The HM slave: from the rest (after the healer - a Milk Drink Miltank
    -- can carry Surf and Strength, but healers are rare and HM carriers aren't).
    -- (a real shiny over a regular one, whatever the scores - the user,
    -- 2026-11-10: "a non shiny can never outperform a shiny as hm slave";
    -- then the most HMs it can learn, M.hm_score; the healer the same)
    -- (real shinies only - the user, 2026-11-10: "we dont need to have an hm
    -- user before we catch a shiny one" - nothing before Falkner needs an HM;
    -- never the living dex's keeper: it stays in the box)
    local bestH, bestHS
    for _, m in ipairs(owned) do
        if not used[m.key] and real(m) and M.hm_style(m.species) and not (M.is_keeper and M.is_keeper(m)) then
            local s = M.hm_score(m)
            if s and beats(m, s, bestH, bestHS) then bestH, bestHS = m, s end
        end
    end
    if bestH then
        used[bestH.key] = true; out.hm = bestH
        local hms = {}
        local f = M.final_form(bestH.species)
        for _, h in ipairs(D.hmcompat[f]) do hms[#hms + 1] = D.moves[h][1]:lower() end
        why[#why + 1] = string.format("HM slave: %s%s (%s)", name(bestH.species), f ~= bestH.species and (" -> " .. name(f)) or "", table.concat(hms, ", "))
    end

    -- Changed from the current team?
    local function keys(t)
        local ks = {}
        for _, r in ipairs({"starter", "catcher", "hm", "healer", "weak"}) do if t[r] then ks[#ks + 1] = r .. "=" .. t[r].key end end
        if t.prospect then ks[#ks + 1] = "prospect=" .. t.prospect.mon.key end
        local sk = {}
        for _, m in ipairs(t.specialists or {}) do sk[#sk + 1] = m.key end
        table.sort(sk)
        ks[#ks + 1] = table.concat(sk, ",")
        return table.concat(ks, ";")
    end
    out.changed = current == nil or keys(current) ~= keys(out)
    out.why = why
    return out
end

-- The party in order for hunting (catcher first) or for the story (the
-- strongest first): a list of keys. Six at most: starter, catcher, the
-- specialists, the second catcher or the healer, the future catcher (in
-- training - the HM slave waits in the box if there's no room), the HM slave.
function M.party_order(team, hunting)
    local out, seen = {}, {}
    local function add(m)
        if m and not seen[m.key] and #out < M.PARTY then seen[m.key] = true; out[#out + 1] = m.key end
    end
    if hunting then add(team.catcher) end
    add(team.starter)
    for _, m in ipairs(team.specialists) do add(m) end
    if not hunting then add(team.catcher) end
    add(team.weak)
    add(team.healer)
    add(team.prospect and team.prospect.mon)
    add(team.hm)
    return out
end

return M
