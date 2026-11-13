-- fighter.lua (lives in modules/data/)
-- Fights a battle to the end in BizHawk: picks the move that does the most
-- (expected) damage, switches to the party member with the best type
-- matchup when that's clearly better, sends out the best one after a
-- faint, takes the trainer's "change POKéMON?" offer when it helps, lets
-- evolutions happen, and learns a new move only when it hits harder than
-- the weakest damaging move it would replace (never over an HM move or a
-- status move).
--
-- Which question a YES/NO box asks comes from the game's own routines
-- (ROM hooks): ForgetMove ("Delete an older move...?"), LearnMove.cancel
-- ("Stop learning...?") and OfferSwitch ("...change POKéMON?"). Anything
-- else is answered NO (B), and the screen's text goes in the log. Text is
-- moved on with A - never B, which would cancel an evolution.
--
-- The choices (M.expected, M.matchup, M.best_move, M.pick, M.learn) are
-- plain functions on tables, so they're tested offline.

local M = {}

local Screen = require("data.screen")
local D, State, ButtonWait, Names
local log = print

local function rom(bank, addr) return bank == 0 and addr or bank * 0x4000 + (addr - 0x4000) end
-- (pokecrystal11.sym; English Crystal 1.0 and 1.1 share them)
local HOOKS = {
    battleMenu = rom(0x09, 0x4EF2),   -- LoadBattleMenu: FIGHT/PKMN/PACK/RUN opens
    moveSelect = rom(0x0F, 0x64BC),   -- MoveSelectionScreen
    partyMenu = rom(0x0F, 0x5313),    -- JumpToPartyMenuAndPrintText (in battle)
    monMenu = rom(0x09, 0x4E99),      -- BattleMonMenu: SWITCH/STATS/CANCEL
    yesNo = rom(0x00, 0x1DD2),        -- PlaceYesNoBox (YesNoBox falls into it)
    offer = rom(0x0F, 0x574B),        -- OfferSwitch
    forget = rom(0x01, 0x65D3),       -- ForgetMove: "Delete an older move...?"
    forgetList = rom(0x01, 0x65EE),   -- ForgetMove.loop: the list of moves
    stopLearning = rom(0x01, 0x65B5), -- LearnMove.cancel: "Stop learning...?"
    lost = rom(0x0F, 0x538E),         -- LostBattle
    evolve = rom(0x13, 0x65E1),       -- EvolutionAnimation: a party member evolves (B held: stops it)
    evolveStopped = rom(0x10, 0x6454),-- CancelEvolution: "Huh? X stopped evolving!"
}
local A = {
    menuY = 0xCFA9, menuX = 0xCFAA, tilemap = 0xC4A0,
    bmon = 0xC62C,            -- wBattleMon: the battle struct layout below
    emon = 0xD206,            -- wEnemyMon
    curBattleMon = 0xD0D4, curPartyMon = 0xD109, newMove = 0xD262,   -- wPutativeTMHMMove
    disabledMove = 0xC6F5,
    myLevels = 0xC6CC, enemyLevels = 0xC6D4,   -- wPlayer/EnemyStatLevels: atk def spd sat sdf acc eva, 7 = neutral
    numBalls = 0xD8D7, balls = 0xD8D8,  -- the Balls pocket: count, then {id, quantity}
    numItems = 0xD892,                  -- the Items pocket: count, then {id, quantity}
    curPocket = 0xCF65,                 -- wCurPocket: 0 Items, 1 Balls, 2 Key Items, 3 TM/HM
    curItem = 0xD106,                   -- wCurItem: the Pack's highlighted item
    joypadFilter = 0xCFA8,              -- wMenuJoypadFilter: the Pack's list takes Up/Down (& 0xC0)
    partyCount = 0xDCD7, partySpecies = 0xDCD8, party = 0xDCDF, partyLen = 0x30,
}
-- battle struct: species 0, moves 2-5, PP 8-11, level 13, status 14,
-- HP 16, max HP 18, atk 20, def 22, spd 24, sat 26, sdf 28, types 30/31.
-- party struct: species 0, moves 2-5, PP 23-26, level 31, status 32,
-- HP 34, max HP 36, atk 38, def 40, spd 42, sat 44, sdf 46.
local EGG = 0xFD

local name_of, move_name   -- (defined with the RAM readers below)
local H = {}        -- set by the hooks (to the frame they ran on), taken by the loop
-- The living dex's keepers (data/goals.lua: the copy of each form that
-- stays as it is): fingerprints (data/family.lua) - their evolution is
-- stopped with B. Set by whoever has the plan (play, hunt, evolve).
M.no_evolve = {}
-- copies(fp, species) -> how many of that fingerprint and species are
-- owned (play sets it; nil: 1) - data/goals.lua's stays.
M.copies = nil
-- Fingerprints never brought in for switch-training: the catcher once it's
-- at its sweet spot (data/sweet_spot.lua) - more EXP would take it past it.
M.no_partner = {}
-- The one to bring in first for switch-training when it can take the wild
-- one on (the starter - the user, 2026-11-09: the Metapod being trained got
-- the low-level Zubat in, which fainted - "just switchtrain with Totodile").
M.partner_first = nil
-- Fingerprints never sent in to fight (the user, 2026-11-09: "the only
-- important thing is that the Zubat never gets used in a Joey battle or
-- something" - EXP would take it past the level where it's crit-safe):
-- only as the last one standing, or to weaken a catch.
M.no_fight = {}
local ctx = nil     -- the question the next YES/NO asks: "forget" / "stop" / "offer"

function M.setup(battleData, state, buttonWait, mem, names, logger)
    D, State, ButtonWait, Names = battleData, state, buttonWait, names or {}
    log = logger or print
    M.build_chart()
    if mem then
        for name, addr in pairs(HOOKS) do
            mem.RegisterROMHook(addr, function()
                H[name] = emu.framecount()
                if name == "forget" then ctx = "forget"
                elseif name == "stopLearning" then ctx = "stop"
                elseif name == "offer" then ctx = "offer" end
            end, "Fighter " .. name)
        end
    end
end

-- ------------------------------------------------------------ the choices

local EFF = {}      -- EFF[attacking type][defending type] = multiplier
function M.build_chart()
    EFF = {}
    for _, c in ipairs(D.chart) do
        EFF[c[1]] = EFF[c[1]] or {}
        EFF[c[1]][c[2]] = c[3] / 10
    end
end
function M.effectiveness(atype, t1, t2)
    local row = EFF[atype] or {}
    local m = row[t1] or 1
    if t2 ~= t1 then m = m * (row[t2] or 1) end
    return m
end

-- Moves that don't hit (or hit oddly) on their own: no damage counted.
local NO_DAMAGE = {EFFECT_SELFDESTRUCT = true, EFFECT_OHKO = true, EFFECT_COUNTER = true,
    EFFECT_MIRROR_COAT = true, EFFECT_FUTURE_SIGHT = true, EFFECT_PRESENT = true, EFFECT_BEAT_UP = true}
local HITS = {EFFECT_MULTI_HIT = 3, EFFECT_DOUBLE_HIT = 2, EFFECT_POISON_MULTI_HIT = 2, EFFECT_TRIPLE_KICK = 2.3}
local SLOW = {EFFECT_HYPER_BEAM = 0.5, EFFECT_RAZOR_WIND = 0.5, EFFECT_SKY_ATTACK = 0.5,
    EFFECT_SOLARBEAM = 0.5, EFFECT_SKULL_BASH = 0.5, EFFECT_FLY = 0.6}
local VARIES = {EFFECT_MAGNITUDE = 70, EFFECT_RETURN = 70, EFFECT_FRUSTRATION = 30, EFFECT_HIDDEN_POWER = 50,
    EFFECT_REVERSAL = 40}

-- Expected damage of move id from att on def (a mon: {level, hp, atk,
-- def, sat, sdf, t1, t2, status}). Gen 2's formula, no random roll or
-- crits, times accuracy.
function M.expected(att, def, moveId)
    local mv = D.moves[moveId]
    if not mv then return 0 end
    local _, eff, power, typ, acc = mv[1], mv[2], mv[3], mv[4], mv[5]
    if NO_DAMAGE[eff] then return 0 end
    local m = M.effectiveness(typ, def.t1, def.t2)
    if m == 0 then return 0 end
    local hit = acc / 100
    if eff == "EFFECT_LEVEL_DAMAGE" or eff == "EFFECT_PSYWAVE" then return att.level * hit end
    if eff == "EFFECT_STATIC_DAMAGE" then return power * hit end
    if eff == "EFFECT_SUPER_FANG" then return math.floor(def.hp / 2) * hit end
    if eff == "EFFECT_DREAM_EATER" and (def.status or 0) & 7 == 0 then return 0 end   -- only on a sleeper
    if eff == "EFFECT_SNORE" and (att.status or 0) & 7 == 0 then return 0 end
    power = VARIES[eff] or power
    if power <= 1 then return 0 end
    local special = typ >= 20
    local a = special and att.sat or att.atk
    local d = special and def.sdf or def.def
    if not a or not d or d == 0 then return 0 end
    local dmg = math.floor(math.floor(math.floor(2 * att.level / 5 + 2) * power * a / d) / 50) + 2
    if typ == att.t1 or typ == att.t2 then dmg = dmg * 1.5 end
    dmg = dmg * m * (HITS[eff] or 1) * (SLOW[eff] or 1) * hit
    if eff == "EFFECT_FALSE_SWIPE" then dmg = math.min(dmg, def.hp - 1) end   -- never the last HP
    return dmg
end

-- The best move a mon has against def: slot (1-4), id, damage as a share
-- of def's HP now. mon.moves = {{id, pp}, ...}; skips no-PP and disabled.
function M.best_move(mon, def, disabled)
    local best, bestSlot, bestId = -1, nil, nil
    for slot, mvs in ipairs(mon.moves) do
        if mvs[1] ~= 0 and mvs[2] > 0 and mvs[1] ~= disabled then
            local d = M.expected(mon, def, mvs[1])
            if d > best then best, bestSlot, bestId = d, slot, mvs[1] end
        end
    end
    if not bestSlot then return nil, nil, 0 end
    return bestSlot, bestId, best / math.max(1, def.hp)
end

-- PP (the user's log, 2026-11-08: the whole party used up its attacks
-- grinding, then ran from everything - a Center refills PP):
-- an attack (a move that does damage) with PP left?
function M.has_attack_pp(mon)
    for _, mvs in ipairs(mon.moves or {}) do
        local mv = D.moves[mvs[1]]
        if mv and mvs[2] > 0 and not NO_DAMAGE[mv[2]] and mv[3] > 1 then return true end
    end
    return false
end
-- Knows a sleep move, but has no PP left in any: the move's name, else nil.
function M.sleep_pp_out(mon)
    local known = nil
    for _, mvs in ipairs(mon.moves or {}) do
        local mv = D.moves[mvs[1]]
        if mv and mv[2] == "EFFECT_SLEEP" then
            if mvs[2] > 0 then return nil end
            known = known or mvs[1]
        end
    end
    return known and move_name(known) or nil
end
-- Its PP left as a share of its full PP (all its moves; PP Ups count:
-- each adds a fifth of the move's base PP). nil if it can't be read.
function M.pp_share(mon)
    local now, full = 0, 0
    for k, mvs in ipairs(mon.moves or {}) do
        local mv = D.moves[mvs[1]]
        if mv and mvs[1] ~= 0 then
            local raw = mon.ppRaw and mon.ppRaw[k]
            local ups = raw and (raw >> 6) or 0
            local base = mv[6] or 0
            full = full + base + (base // 5) * ups
            now = now + (raw and (raw & 0x3F) or mvs[2])
        end
    end
    if full <= 0 then return nil end
    return now / full
end

-- Its sleep move's PP left as a share (the best-stocked one it knows; PP
-- Ups count) - nil if it knows none.
function M.sleep_pp_share(mon)
    local best = nil
    for k, mvs in ipairs(mon.moves or {}) do
        local mv = D.moves[mvs[1]]
        if mv and mv[2] == "EFFECT_SLEEP" then
            local raw = mon.ppRaw and mon.ppRaw[k]
            local full = (mv[6] or 0) + ((mv[6] or 0) // 5) * (raw and (raw >> 6) or 0)
            local now = raw and (raw & 0x3F) or mvs[2]
            if full > 0 and (not best or now / full > best) then best = now / full end
        end
    end
    return best
end

-- Why the party needs a Center for PP (the user, 2026-11-08: "no PP on the
-- lead, or 50% or less on 2 or more Pokemon, should always go to a Center
-- if one is nearby"): reason, and whether only a NEAR Center is worth it -
-- or nil. However far (stuck without): the lead has no attack left, nobody
-- has, or one that puts to sleep (the catcher) has no PP for it. Near only:
-- M.PP_LOW_COUNT or more at M.PP_LOW or less of their PP.
M.PP_LOW, M.PP_LOW_COUNT = 0.5, 2
function M.pp_trouble()
    local mons = M.party_mons()
    local anyAttack, alive, lowOnes = false, 0, {}
    for _, m in ipairs(mons) do
        if not m.egg and m.hp > 0 then
            if alive == 0 and not M.has_attack_pp(m) then
                return string.format("%s, out in front, has no PP left in its attacks", name_of(m.species)), false
            end
            alive = alive + 1
            if M.has_attack_pp(m) then anyAttack = true end
            local sm = M.sleep_pp_out(m)
            if sm then return string.format("%s has no PP left for %s", name_of(m.species), sm), false end
        end
        local share = not m.egg and M.pp_share(m)
        if share and share <= M.PP_LOW then lowOnes[#lowOnes + 1] = string.format("%s %d%%", name_of(m.species), math.floor(share * 100 + 0.5)) end
    end
    if alive > 0 and not anyAttack then return "nobody in the party has PP left in an attack", false end
    if #lowOnes >= M.PP_LOW_COUNT then
        return string.format("%d are at half their PP or less (%s)", #lowOnes, table.concat(lowOnes, ", ")), true
    end
    -- (the catcher's sleep move under half its PP: a Center nearby - the
    -- user, 2026-11-08: a shiny needs the tries)
    for _, m in ipairs(mons) do
        local ss = not m.egg and m.hp > 0 and M.sleep_pp_share(m)
        if ss and ss < M.PP_LOW then
            return string.format("%s's sleep move is down to %d%% of its PP", name_of(m.species), math.floor(ss * 100 + 0.5)), true
        end
    end
    return nil
end

-- ------------------------------------------------------------ stat moves
-- Leer before Scratch: a stat move is worth a turn when the fight gets
-- shorter for it. The battle stats already hold the stages so far; one
-- more stage scales them by the game's table (StatLevelMultipliers: -1 66%,
-- +1 150%...). Turns are counted at the AVERAGE damage roll (~92.5% of the
-- top one), and only while we'd outlast the extra turn.
local STAGE = {[1] = 0.25, [2] = 0.28, [3] = 0.33, [4] = 0.40, [5] = 0.50, [6] = 0.66, [7] = 1, [8] = 1.5, [9] = 2,
    [10] = 2.5, [11] = 3, [12] = 3.5, [13] = 4}
-- effect -> {whose ("enemy"/"self"), stat field, stage index (1 atk 2 def 4 sat 5 sdf), change}
local SETUP = {
    EFFECT_DEFENSE_DOWN = {"enemy", "def", 2, -1},       -- Leer, Tail Whip
    EFFECT_DEFENSE_DOWN_2 = {"enemy", "def", 2, -2},     -- Screech
    EFFECT_SP_DEF_DOWN_2 = {"enemy", "sdf", 5, -2},      -- (Fake Tears isn't in Gen 2; kept for completeness)
    EFFECT_ATTACK_UP = {"self", "atk", 1, 1},            -- Meditate, Sharpen
    EFFECT_ATTACK_UP_2 = {"self", "atk", 1, 2},          -- Swords Dance
    EFFECT_SP_ATK_UP = {"self", "sat", 4, 1},            -- Growth
}
M.AVG_ROLL = 0.925

-- Turns for mon to knock enemy out with its best move (at the average roll).
function M.turns_to_ko(mon, enemy, disabled)
    local slot, id = M.best_move(mon, enemy, disabled)
    if not id then return math.huge end
    local dmg = M.expected(mon, enemy, id) * M.AVG_ROLL
    if dmg <= 0 then return math.huge end
    return math.ceil(enemy.hp / dmg)
end

-- A stat move to use now, or nil: {slot, id, turns = with, without}.
-- levels: {mine = {7 bytes}, theirs = {7 bytes}} (stat stages, 7 neutral).
function M.setup_move(mon, enemy, disabled, levels)
    local without = M.turns_to_ko(mon, enemy, disabled)
    if without <= 2 or without == math.huge then return nil end      -- (it's over soon anyway)
    local _, _, dmgIn = M.best_move(enemy, mon)                       -- (their best hit on us: share of our HP)
    local best = nil
    for slot, mvs in ipairs(mon.moves) do
        local mv = D.moves[mvs[1]]
        local s = mv and SETUP[mv[2]]
        if s and mvs[2] > 0 and mvs[1] ~= disabled then
            local who, field, idx, change = s[1], s[2], s[3], s[4]
            local stages = levels and (who == "enemy" and levels.theirs or levels.mine) or nil
            local cur = stages and stages[idx] or 7
            if not STAGE[cur] then cur = 7 end      -- (a misread: take it as neutral)
            local new = math.max(1, math.min(13, cur + change))
            if new ~= cur then
                local function scaled(m)
                    local c = {}
                    for k, v in pairs(m) do c[k] = v end
                    c[field] = math.floor(m[field] * STAGE[new] / STAGE[cur])
                    return c
                end
                local me2, en2 = mon, enemy
                if who == "enemy" then en2 = scaled(enemy) else me2 = scaled(mon) end
                local after = M.turns_to_ko(me2, en2, disabled)
                local acc = mv[5] / 100
                local with = 1 / math.max(0.3, acc) + after             -- (a miss costs another turn)
                -- worth it: a turn shorter at least, and we last that long
                if with <= without - 1 and dmgIn * math.ceil(with) < 1 and (not best or with < best.turns) then
                    best = {slot = slot, id = mvs[1], turns = with, without = without}
                end
            end
        end
    end
    return best
end

-- How mon fares against enemy: what it deals per turn as a share of the
-- enemy's HP (capped at 1) minus what it takes as a share of its own,
-- plus a bit for striking first when it can knock them out.
function M.matchup(mon, enemy)
    local _, _, off = M.best_move(mon, enemy)
    local _, _, dmgIn = M.best_move(enemy, mon)
    local score = math.min(off, 1) - math.min(dmgIn, 1)
    if off >= 1 and (mon.spd or 0) > (enemy.spd or 0) then score = score + 0.5 end
    return score, off, dmgIn
end

-- Which party member to send out: the best matchup of those who can
-- fight (hp > 0, not an egg), except `exclude`. Returns index (0-based), score.
function M.pick(party, enemy, exclude)
    for pass = 1, 2 do
        local bestI, best
        for i, mon in ipairs(party) do
            if mon.hp > 0 and not mon.egg and (i - 1) ~= exclude and (pass == 2 or not M.no_fight[mon.fp or ""]) then
                local s = M.matchup(mon, enemy)
                if not best or s > best then bestI, best = i - 1, s end
            end
        end
        if bestI then return bestI, best end
    end
    return nil
end

-- Switch out now? (Switching costs a free hit, so only for a clear gain:
-- the active one can't knock them out this turn, the other one is a good
-- deal better, and takes the incoming hit comfortably.)
function M.should_switch(party, active, activeIndex, enemy)
    local cur, curOff = M.matchup(active, enemy)
    if curOff >= 1 then return nil end
    local i, s = M.pick(party, enemy, activeIndex)
    if not i then return nil end
    local _, _, dmgIn = M.matchup(party[i + 1], enemy)
    if s - cur > 0.5 and dmgIn < 0.5 then return i, s, cur end
    return nil
end

-- ------------------------------------------------------------ wild battles
-- The old Kill mode's rules (the user bot's modules/data/move_choice.lua,
-- M.kill, and wild.lua's flee checks), for fighting wild ones:
--   * "risky": it knows a move, with PP left, that's super effective against
--     ours (Vine Whip against Totodile) - fixed-damage moves (Seismic Toss,
--     SonicBoom, Super Fang, Psywave) don't count, type doesn't change them;
--   * nothing we have can hurt it;
--   * ours at 25% HP or less, or out of PP for every damaging move.
-- Any of those: run. Checked when it appears and again every turn.
M.WILD_LOW_HP = 0.25
local FIXED = {EFFECT_LEVEL_DAMAGE = true, EFFECT_STATIC_DAMAGE = true, EFFECT_SUPER_FANG = true, EFFECT_PSYWAVE = true}

-- The enemy's first move (PP left) that's super effective against mon and
-- really hurts (a hit expected to take M.THREAT_SHARE of its HP or more),
-- or nil. (A Lv 2 Spearow's Peck is super effective on Butterfree, for 1-2
-- HP - no reason to run or switch; the user, 2026-11-08.)
M.THREAT_SHARE = 0.25
function M.threat(enemy, mon)
    for _, mvs in ipairs(enemy.moves) do
        local mv = D.moves[mvs[1]]
        if mv and mvs[2] > 0 and mv[3] > 1 and not FIXED[mv[2]] and M.effectiveness(mv[4], mon.t1, mon.t2) > 1 then
            local hp = math.max(1, mon.hp or 1)
            if not (enemy.atk and enemy.level) or M.expected(enemy, mon, mvs[1]) >= M.THREAT_SHARE * hp then return mvs[1] end
        end
    end
    return nil
end

-- Moves that poison, put to sleep or paralyze (a sure one or a chance on
-- a hit). Burn isn't here - rare enough to risk (the user, 2026-11-08).
local STATUS_EFFECTS = {EFFECT_POISON = "poison", EFFECT_TOXIC = "poison", EFFECT_POISON_HIT = "poison",
    EFFECT_POISON_MULTI_HIT = "poison", EFFECT_SLEEP = "put to sleep", EFFECT_PARALYZE = "paralyze",
    EFFECT_PARALYZE_HIT = "paralyze", EFFECT_THUNDER = "paralyze", EFFECT_TRI_ATTACK = "paralyze"}
-- The enemy's move that could do that (PP left): id, what - or nil.
function M.status_move(enemy)
    for _, mvs in ipairs(enemy.moves or {}) do
        local mv = D.moves[mvs[1]]
        if mv and mvs[2] > 0 and STATUS_EFFECTS[mv[2]] then return mvs[1], STATUS_EFFECTS[mv[2]] end
    end
    return nil
end
-- Does mon knock it out before it moves: faster, and its best move does
-- it even at the lowest roll (no critical hit), with 90%+ accuracy?
function M.one_shot(mon, enemy, disabled)
    if (mon.spd or 0) <= (enemy.spd or 0) then return false end
    local _, id = M.best_move(mon, enemy, disabled)
    local mv = id and D.moves[id]
    if not mv or mv[5] < 90 then return false end
    local dmg = M.expected(mon, enemy, id) / (mv[5] / 100) * 0.85
    return dmg >= enemy.hp
end
-- Can the one out win this wild one alone, safely (the user, 2026-11-08:
-- "at some point the trainee can stand up on its own")? It fights it
-- (wild_verdict) and knocks it out before losing M.SOLO_MAX_TAKEN of its HP
-- (the enemy's best hit, expected, once per turn it gets). Alone, it gets
-- all the EXP - switch-training halves it, and the switch gives a free hit.
M.SOLO_MAX_TAKEN = 0.5
-- (the user, 2026-11-09: a Lv 7 Zubat took a Lv 2 Zubat on alone - Leech
-- Life at ~7% a hit, 16 turns - ran out of PP and walked to a Center)
-- * its best move's lowest roll, no crit, does at least SOLO_MIN_HIT of
--   the enemy's HP - else switch-training;
-- * it has the PP for it;
-- * and alone is more EXP per second than switch-training (half the EXP,
--   the partner's quick finish): seconds per fight from the user's logs -
--   finding the next one T_FIND, a turn T_TURN, the end T_END, the switch
--   and the second EXP share T_SWITCH; the HP it loses costs a share of a
--   Center trip (T_HEAL for the usable 70%).
M.SOLO_MIN_HIT = 0.25
M.T_FIND, M.T_TURN, M.T_END, M.T_SWITCH, M.T_HEAL = 6, 5, 4, 7, 40
M.MIN_ROLL = 217 / 255
function M.solo_ok(mon, enemy, disabled, partner)
    if not M.wild_verdict(mon, enemy, disabled) then return false end
    local turns = M.turns_to_ko(mon, enemy, disabled)
    if turns == math.huge then return false end
    local slot, id = M.best_move(mon, enemy, disabled)
    local mv = id and D.moves[id]
    if not mv then return false end
    local full = (enemy.maxhp and enemy.maxhp > 0) and enemy.maxhp or enemy.hp
    local minHit = M.expected(mon, enemy, id) / math.max(0.01, mv[5] / 100) * M.MIN_ROLL
    if minHit < M.SOLO_MIN_HIT * full and minHit < enemy.hp then return false, turns, "weak" end
    if mon.moves[slot] and mon.moves[slot][2] < turns then return false, turns, "pp" end
    local _, _, shareIn = M.best_move(enemy, mon)
    local hits = turns - (((mon.spd or 0) > (enemy.spd or 0)) and 1 or 0)
    local taken = (shareIn or 0) * hits
    if taken >= M.SOLO_MAX_TAKEN then return false, turns, "hurt" end
    -- (EXP per second: alone, all of it; switch-training, half)
    local ofMax = (mon.maxhp and mon.maxhp > 0) and taken * mon.hp / mon.maxhp or taken
    local alone = M.T_FIND + turns * M.T_TURN + M.T_END + ofMax / 0.7 * M.T_HEAL
    local pTurns = partner and M.turns_to_ko(partner, enemy) or 1
    if pTurns == math.huge then return true, turns end
    local shared = M.T_FIND + M.T_SWITCH + pTurns * M.T_TURN + M.T_END
    if alone >= 2 * shared then return false, turns, "slow" end
    return true, turns
end

-- Fight this wild one? true, or false and why (for the log), and the kind
-- ("status": it could poison / sleep / paralyze - run even when training).
function M.wild_verdict(mon, enemy, disabled)
    if mon.maxhp > 0 and mon.hp <= M.WILD_LOW_HP * mon.maxhp then
        return false, string.format("%s is at %d%% HP", name_of(mon.species), math.floor(100 * mon.hp / mon.maxhp))
    end
    local t = M.threat(enemy, mon)
    if t then
        return false, string.format("it knows %s, super effective against %s", move_name(t), name_of(mon.species))
    end
    local slot, _, share = M.best_move(mon, enemy, disabled)
    if not slot or share <= 0 then
        if not M.has_attack_pp(mon) then return false, string.format("%s has no PP left in its attacks", name_of(mon.species)) end
        return false, string.format("nothing %s has hurts it", name_of(mon.species))
    end
    -- (a poisoner, sleeper or paralyzer not knocked out first: run - a
    -- status costs a Center trip or an Antidote; the user, 2026-11-08)
    local sid, what = M.status_move(enemy)
    if sid and not M.one_shot(mon, enemy, disabled) then
        return false, string.format("it can %s us (%s) and %s can't knock it out first", what, move_name(sid), name_of(mon.species)), "status"
    end
    return true
end

-- ------------------------------------------------------------ healing in battle
-- The one fighting is critically low (HEAL_HP of its HP or less - a
-- setting) in a battle we can't run from (a trainer) or don't want to (a
-- shiny being caught): a potion from the Pack instead of a move, when
--   * the enemy's next hit could knock it out (its best move, expected,
--     takes half of what's left or more) - not when it barely scratches;
--   * we can't end it first (one hit from us does it, and we're faster);
--   * the potion gives back more than that hit takes (else it's a turn
--     lost for nothing, again and again);
--   * at most MAX_HEALS a battle, and not again after the Pack didn't work.
-- The potion: the smallest that fills it up, else the biggest there is;
-- never ENERGYPOWDER / ENERGY ROOT (friendship); a FULL RESTORE only when
-- it's all there is. (Wild battles that aren't a catch: we run at 25%.)
M.HEAL_HP = 0.25
M.MAX_HEALS = 3
-- spare(mon) -> true: this one may faint rather than get a potion (set by
-- play - the user, 2026-11-08: in the first section, with a Pokemon Center
-- near, a teammate that isn't the starter or the last specialist can go
-- down; the Center brings it back for free).
M.spare = nil
local BITTER = {ENERGYPOWDER = true, ENERGY_ROOT = true}

-- The potion for `missing` HP from bag {[id] = count}: id, HP it gives.
function M.potion(missing, bag)
    local fill, big, restore = nil, nil, nil
    for _, h in ipairs(D.heals or {}) do
        local id, amount = h[1], h[2]
        local n = D.items[id]
        if (bag[id] or 0) > 0 and not BITTER[n] then
            if n == "FULL_RESTORE" then restore = {id, amount}
            else
                if amount >= missing and (not fill or amount < fill[2]) then fill = {id, amount} end
                if not big or amount > big[2] then big = {id, amount} end
            end
        end
    end
    local pick = fill or big or restore
    if pick then return pick[1], math.min(pick[2], missing) end
    return nil
end

-- Heal now? {id = item, gives = HP} or nil, and why not (for tests/log).
function M.heal_action(me, enemy, bag, st, disabled)
    st = st or {}
    if M.HEAL_HP <= 0 or me.maxhp <= 0 or me.hp <= 0 or me.hp > M.HEAL_HP * me.maxhp then return nil, "not low" end
    if (st.heals or 0) >= M.MAX_HEALS or (st.healFails or 0) >= 2 then return nil, "no more heals this battle" end
    if M.spare and M.spare(me) then return nil, "it can be spared - a Pokemon Center is near" end
    local _, _, shareIn = M.best_move(enemy, me)
    local hit = shareIn * me.hp                      -- (their best hit, expected, in HP)
    if hit < 0.5 * me.hp then return nil, "its hits barely hurt" end
    if M.turns_to_ko(me, enemy, disabled) <= 1 and (me.spd or 0) > (enemy.spd or 0) then return nil, "we finish it first" end
    local id, gives = M.potion(me.maxhp - me.hp, bag)
    if not id then return nil, "no potions" end
    if gives <= hit then return nil, "the potion gives back less than one hit takes" end
    return {id = id, gives = gives, hit = hit}
end

-- ------------------------------------------------------------ catching
-- A shiny to catch (the user's way: put it to sleep with the catcher, then
-- balls). Each turn, M.catch_action:
--   1. not asleep (or frozen), and ours has a sleep move with PP: use it;
--   2. above CATCH_HP of its HP: weaken - only with a move whose WORST case
--      (top damage roll, a critical hit, every hit of a multi-hit move)
--      can't knock it out, and that can't poison, burn, confuse or trap it
--      (damage after the turn) or lock ours in; at most 15 weakening turns,
--      and 3 in a row that don't take it lower end it;
--   3. else the best ball there is (never a Master Ball): Ultra 2x, Great
--      1.5x, Poke 1x (x lower HP), Level Ball by levels.
-- The live bot's auto-catch (autocrystal/modules/wild.lua) is the model:
-- its 40% target, its stall limits, its ball choice and Pack driving.
M.CATCH_HP = 0.40
-- A rare one (5% or less at its best spot anywhere - battle_data's rarity):
-- never weakened with a move a critical hit could knock it out with - the
-- balls go at it asleep, whatever its HP (the user, 2026-11-08: "we risk a
-- crit unless it's a 5% or 1% encounter").
M.RARE_PCT = 5
-- Nobody can weaken it any more without risking a critical hit, and it's
-- down to this share of its HP or less: balls, not the risk (the user,
-- 2026-11-09 - a sleeping Pidgey at 60% HP takes a Poke Ball 64% of the
-- time, against 77% at 40%: not worth a knocked-out shiny).
M.BALLS_AT = 0.65
-- What to do when no move of anyone's is crit-safe: "rare" (balls - a 1-5%
-- one), "low" (balls - at M.BALLS_AT or less), else "risky" (a move only a
-- crit could knock it out with).
-- canSleep: it's asleep, or someone still has PP for a sleep move. Without
-- (the user, 2026-11-09): a common one is weakened the regular way, risking
-- a crit, down to CATCH_HP - a rare one (Phanpy, Dunsparce, Teddiursa)
-- never.
-- (the user, 2026-11-09: "zubat can risk a crit if the species is common
-- and is not able to get slept" - while it can be put to sleep, never a
-- risk: balls, whatever its HP. "low" at M.BALLS_AT or less, "asleep" above)
function M.no_safe_choice(enemy, canSleep)
    if M.is_rare(enemy.species) then return "rare" end
    if canSleep ~= false then
        if enemy.maxhp and enemy.maxhp > 0 and enemy.hp <= M.BALLS_AT * enemy.maxhp then return "low" end
        return "asleep"
    end
    return "risky"
end
-- (switching in the one with the sleep move, or the weakener, as often as
-- it takes - a cap only against a loop)
M.SWITCH_CAP = 40
function M.is_rare(sp)
    local r = D.rarity and D.rarity[sp]
    return r ~= nil and r[1] <= M.RARE_PCT
end
local SAFE_WEAKEN = {EFFECT_NORMAL_HIT = true, EFFECT_FLINCH_HIT = true, EFFECT_STOMP = true, EFFECT_PRIORITY_HIT = true,
    EFFECT_ALWAYS_HIT = true, EFFECT_PARALYZE_HIT = true, EFFECT_THUNDER = true, EFFECT_FREEZE_HIT = true,
    EFFECT_ATTACK_DOWN_HIT = true, EFFECT_DEFENSE_DOWN_HIT = true, EFFECT_SPEED_DOWN_HIT = true, EFFECT_SP_ATK_DOWN_HIT = true,
    EFFECT_SP_DEF_DOWN_HIT = true, EFFECT_ACCURACY_DOWN_HIT = true, EFFECT_EVASION_DOWN_HIT = true, EFFECT_RECOIL_HIT = true,
    EFFECT_LEECH_HIT = true, EFFECT_TWISTER = true, EFFECT_FALSE_SWIPE = true, EFFECT_MULTI_HIT = true, EFFECT_DOUBLE_HIT = true,
    EFFECT_TRIPLE_KICK = true, EFFECT_LEVEL_DAMAGE = true, EFFECT_STATIC_DAMAGE = true, EFFECT_SUPER_FANG = true,
    EFFECT_PAY_DAY = true, EFFECT_JUMP_KICK = true, EFFECT_GUST = true, EFFECT_EARTHQUAKE = true}
local MAX_HITS = {EFFECT_MULTI_HIT = 5, EFFECT_DOUBLE_HIT = 2, EFFECT_POISON_MULTI_HIT = 2, EFFECT_TRIPLE_KICK = 6}
local BALLS = {[2] = 2, [4] = 1.5, [5] = 1}          -- Ultra, Great, Poke: x the HP factor
local LEVEL_BALL, LURE_BALL, MASTER_BALL = 159, 160, 1

-- The most a move could do to def in one turn: top roll, a critical hit
-- (Gen 2: x2), every hit, +25%. For fixed damage, exactly that. noCrit:
-- without the critical hit (the risk taken when nobody can do it safely).
function M.max_damage(att, def, moveId, noCrit)
    local mv = D.moves[moveId]
    if not mv then return 0 end
    local eff, power, typ = mv[2], mv[3], mv[4]
    if NO_DAMAGE[eff] then return 1e9 end
    local m = M.effectiveness(typ, def.t1, def.t2)
    if m == 0 then return 0 end
    if eff == "EFFECT_LEVEL_DAMAGE" then return att.level end
    if eff == "EFFECT_PSYWAVE" then return math.floor(att.level * 1.5) end
    if eff == "EFFECT_STATIC_DAMAGE" then return power end
    if eff == "EFFECT_SUPER_FANG" then return math.max(1, math.floor(def.hp / 2)) end
    if eff == "EFFECT_FALSE_SWIPE" then return 0 end      -- (always leaves it 1 HP: never knocks it out)
    power = VARIES[eff] and 150 or power
    if power <= 1 then return 0 end
    local special = typ >= 20
    local a = special and att.sat or att.atk
    local d = special and def.sdf or def.def
    if not a or not d or d == 0 then return 1e9 end
    -- The game's order (BattleCommand_DamageCalc, then _Stab): the base /
    -- 50, a held type item's +10%, a critical hit x2, +2, STAB x1.5, the
    -- type, a badge's +1/8 for its type (ours only); the random roll can
    -- only lower it. Worst case: the critical hit, the item's boost if it
    -- holds anything at all, the badge's if we have it (or don't know).
    local dmg = math.floor(math.floor(math.floor(2 * att.level / 5 + 2) * power * a / d) / 50)
    if att.item and att.item ~= 0 then dmg = math.floor(dmg * 110 / 100) end
    dmg = dmg * (noCrit and 1 or 2) + 2
    if typ == att.t1 or typ == att.t2 then dmg = dmg * 1.5 end
    dmg = dmg * m
    if M.badgeTypes == nil or M.badgeTypes[typ] then dmg = dmg * 1.125 end
    return dmg * (MAX_HITS[eff] or 1)
end

-- The types our badges boost (BadgeTypeBoosts, in wJohtoBadges /
-- wKantoBadges bit order); set from RAM at each battle's start. nil = not
-- known: every type counts as boosted.
local JOHTO_BOOSTS = {2, 7, 0, 8, 9, 1, 25, 26}      -- Flying Bug Normal Ghost Steel Fighting Ice Dragon
local KANTO_BOOSTS = {5, 21, 23, 22, 3, 24, 20, 4}   -- Rock Water Electric Grass Poison Psychic Fire Ground
M.badgeTypes = nil
function M.badge_types(johto, kanto)
    local t = {}
    for i = 0, 7 do
        if (johto >> i) & 1 == 1 then t[JOHTO_BOOSTS[i + 1]] = true end
        if (kanto >> i) & 1 == 1 then t[KANTO_BOOSTS[i + 1]] = true end
    end
    return t
end

-- The weakening move: the most expected damage among moves that can't
-- knock it out (and are safe in kind). slot, id - or nil. riskCrit: only
-- a critical hit could knock it out (nobody can do it safely).
function M.weaken_move(mon, def, disabled, riskCrit)
    local best, bestSlot, bestId = 0, nil, nil
    for slot, mvs in ipairs(mon.moves) do
        local mv = D.moves[mvs[1]]
        if mv and mvs[2] > 0 and mvs[1] ~= disabled and SAFE_WEAKEN[mv[2]] and M.max_damage(mon, def, mvs[1], riskCrit) < def.hp then
            local e = M.expected(mon, def, mvs[1])
            if mv[2] == "EFFECT_FALSE_SWIPE" then e = math.min(M.expected(mon, {hp = 1e9, def = def.def, sdf = def.sdf, t1 = def.t1, t2 = def.t2}, mvs[1]), def.hp - 1) end
            if e > best then best, bestSlot, bestId = e, slot, mvs[1] end
        end
    end
    return bestSlot, bestId
end

-- A sleep move ours has with PP: slot, id - the most accurate.
function M.sleep_move(mon, disabled)
    local best, bestSlot, bestId = -1, nil, nil
    for slot, mvs in ipairs(mon.moves) do
        local mv = D.moves[mvs[1]]
        if mv and mv[2] == "EFFECT_SLEEP" and mvs[2] > 0 and mvs[1] ~= disabled and mv[5] > best then
            best, bestSlot, bestId = mv[5], slot, mvs[1]
        end
    end
    return bestSlot, bestId
end

-- The best ball in the bag ({[id] = count}) for this target: id or nil.
function M.best_ball(bag, me, enemy)
    local hpf = enemy.maxhp > 0 and (3 * enemy.maxhp - 2 * enemy.hp) / (3 * enemy.maxhp) or 1
    local chance = {}
    for id, x in pairs(BALLS) do chance[id] = x * hpf end
    chance[LEVEL_BALL] = (enemy.level >= me.level and 1) or (enemy.level >= me.level // 2 and 2) or (enemy.level >= me.level // 4 and 4) or 8
    chance[LURE_BALL] = hpf            -- (only a fishing battle gets more)
    local best, bestC = nil, -1
    for id, c in pairs(chance) do
        if (bag[id] or 0) > 0 and id ~= MASTER_BALL and c > bestC then best, bestC = id, c end
    end
    return best
end

-- This turn: {kind = "sleep" | "weaken", slot, id} or {kind = "ball", id}
-- (id nil: no balls left). st: the catch's state across turns.
function M.catch_action(me, enemy, bag, st, disabled)
    st = st or {}
    -- (ours asleep or frozen: while it's still high, sit it out - a turn
    -- with a move picked does nothing but pass; a ball at full HP would be
    -- wasted (the user, 2026-11-08). Low enough: a ball - that works asleep)
    if (me.status or 0) & 0x07 ~= 0 or (me.status or 0) & 0x20 ~= 0 then
        if enemy.hp > M.CATCH_HP * enemy.maxhp and (st.waitTurns or 0) < 10 then
            st.waitTurns = (st.waitTurns or 0) + 1
            local slot = M.weaken_move(me, enemy, disabled)
            if not slot then
                for i, mvs in ipairs(me.moves) do if mvs[1] ~= 0 and mvs[2] > 0 and mvs[1] ~= disabled then slot = slot or i end end
            end
            if slot then return {kind = "wait", slot = slot, oursAsleep = true} end
        end
        return {kind = "ball", id = M.best_ball(bag, me, enemy), oursAsleep = true}
    end
    local asleep = (enemy.status or 0) & 0x07 ~= 0 or (enemy.status or 0) & 0x20 ~= 0
    if not asleep then
        -- (always, while the move has PP - the user, 2026-11-09: no giving
        -- up after a few misses)
        local slot, id = M.sleep_move(me, disabled)
        if slot then
            st.sleepTries = (st.sleepTries or 0) + 1
            return {kind = "sleep", slot = slot, id = id}
        end
    end
    if enemy.hp > M.CATCH_HP * enemy.maxhp and (st.weakenTurns or 0) < 15 and (st.stall or 0) < 3 then
        if st.lowest == nil or enemy.hp < st.lowest then st.lowest, st.stall = enemy.hp, 0 else st.stall = (st.stall or 0) + 1 end
        -- (a regular one: a move only a crit could knock it out with is fine)
        local slot, id = M.weaken_move(me, enemy, disabled, st.regular)
        if slot then
            st.weakenTurns = (st.weakenTurns or 0) + 1
            return {kind = "weaken", slot = slot, id = id}
        end
        -- (still high, but every move ours has could knock it out at worst:
        -- the caller may bring in a teammate that can weaken it safely)
        return {kind = "ball", id = M.best_ball(bag, me, enemy), noSafeMove = true}
    end
    return {kind = "ball", id = M.best_ball(bag, me, enemy)}
end

-- A teammate to weaken it with, when the one out can't do it safely:
-- one that has a move that can't knock it out even at worst (weaken_move),
-- and takes the enemy's hits easily (its best expected hit under a third
-- of the teammate's HP - switching in costs a free hit). The one with the
-- strongest safe move (fewest turns). party index (0-based) or nil.
function M.weakener(party, active, enemy)
    local best, bestDmg = nil, 0
    for i, mon in ipairs(party) do
        if (i - 1) ~= active and mon.hp > 0 and not mon.egg and (mon.status or 0) & 0x27 == 0 then
            local slot, id = M.weaken_move(mon, enemy)
            if slot then
                local _, _, shareIn = M.best_move(enemy, mon)
                local dmg = M.expected(mon, enemy, id)
                if shareIn < 1 / 3 and dmg > bestDmg then best, bestDmg = i - 1, dmg end
            end
        end
    end
    return best
end

-- How good a move is for this mon in general (for learning): power x
-- STAB x accuracy x hits x the attack stat it uses (Gen 2: by type -
-- Fire, Water, Grass, Electric, Psychic, Ice, Dragon, Dark special); 0
-- for status moves.
function M.rating(mon, moveId)
    local mv = D.moves[moveId]
    if not mv then return 0 end
    local _, eff, power, typ, acc = mv[1], mv[2], mv[3], mv[4], mv[5]
    if NO_DAMAGE[eff] then return 0 end
    if eff == "EFFECT_LEVEL_DAMAGE" or eff == "EFFECT_PSYWAVE" then power = math.max(40, mon.level) end
    if eff == "EFFECT_STATIC_DAMAGE" or eff == "EFFECT_SUPER_FANG" then power = 40 end
    if eff == "EFFECT_DREAM_EATER" or eff == "EFFECT_SNORE" then power = 0 end
    power = VARIES[eff] or power
    if power <= 1 then return 0 end
    local stab = (typ == mon.t1 or typ == mon.t2) and 1.5 or 1
    local stat = (typ >= 20 and mon.sat or mon.atk) or 1
    return power * stab * (acc / 100) * (HITS[eff] or 1) * (SLOW[eff] or 1) * stat
end

-- Learn newMove? Returns the slot (1-4) to forget, or nil to keep all four.
-- A sleep move is always learned when it's better than the one it has (or
-- it has none): the catcher's tool (the user's Butterfree, 2026-11-08 -
-- Sleep Powder at 15 came with four moves known, and status moves rate 0,
-- so it was turned down). It goes in place of the weaker sleep move, else
-- a move that does no damage (String Shot, Harden), else the weakest.
function M.learn(mon, newMove)
    local nm = D.moves[newMove]
    if nm and nm[2] == "EFFECT_SLEEP" then
        local sleepSlot, sleepAcc, idle, worst, worstSlot = nil, -1, nil, nil, nil
        for slot, mvs in ipairs(mon.moves) do
            local mv = D.moves[mvs[1]]
            if mv and not D.hm[mvs[1]] then
                if mv[2] == "EFFECT_SLEEP" then
                    if mv[5] > sleepAcc then sleepSlot, sleepAcc = slot, mv[5] end
                else
                    local r = M.rating(mon, mvs[1])
                    if r <= 0 then idle = idle or slot
                    elseif not worst or r < worst then worst, worstSlot = r, slot end
                end
            end
        end
        if sleepSlot then
            if nm[5] > sleepAcc then return sleepSlot, 0, 1 end
            return nil, 0, 0
        end
        local slot = idle or worstSlot
        if slot then return slot, 0, 1 end
        return nil, 0, 0
    end
    local new = M.rating(mon, newMove)
    if new <= 0 then return nil end
    local worst, worstSlot
    for slot, mvs in ipairs(mon.moves) do
        local id = mvs[1]
        if id ~= 0 and not D.hm[id] then
            local r = M.rating(mon, id)
            if r > 0 and (not worst or r < worst) then worst, worstSlot = r, slot end
        end
    end
    if worstSlot and new > worst * 1.1 then return worstSlot, worst, new end
    return nil, worst, new
end

-- ------------------------------------------------------------ reading RAM

local function r(a) return State.read8(a) end
local function r16(a) return r(a) * 256 + r(a + 1) end

local function species_types(sp)
    local s = D.species[sp]
    if s then return s[2], s[3] end
    return 0, 0
end

-- A mon from a battle struct (wBattleMon / wEnemyMon): with in-battle stats.
function M.battle_mon(base)
    local m = {species = r(base), item = r(base + 1), level = r(base + 13), status = r(base + 14),
        hp = r16(base + 16), maxhp = r16(base + 18), atk = r16(base + 20), def = r16(base + 22),
        spd = r16(base + 24), sat = r16(base + 26), sdf = r16(base + 28), t1 = r(base + 30), t2 = r(base + 31),
        moves = {}}
    for i = 0, 3 do m.moves[i + 1] = {r(base + 2 + i), r(base + 8 + i) & 0x3F} end
    return m
end

-- The party, each from its party struct (the active one from the battle struct).
function M.party_mons()
    local n, out = math.min(r(A.partyCount), 6), {}
    local active = r(A.curBattleMon)
    for i = 0, n - 1 do
        local base = A.party + i * A.partyLen
        local m
        if i == active and State.in_battle() then
            m = M.battle_mon(A.bmon)
        else
            m = {species = r(base), item = r(base + 1), level = r(base + 31), status = r(base + 32),
                hp = r16(base + 34), maxhp = r16(base + 36), atk = r16(base + 38), def = r16(base + 40),
                spd = r16(base + 42), sat = r16(base + 44), sdf = r16(base + 46), moves = {}}
            m.t1, m.t2 = species_types(m.species)
            for k = 0, 3 do m.moves[k + 1] = {r(base + 2 + k), r(base + 23 + k) & 0x3F} end
        end
        m.egg = r(A.partySpecies + i) == EGG
        -- (the PP bytes as the party struct has them: PP Ups in the top 2 bits)
        m.ppRaw = {}
        for k = 0, 3 do m.ppRaw[k + 1] = r(base + 23 + k) end
        -- (who it is: species:DVs:OT, as data/pc.lua's fingerprint - from the party struct)
        m.fp = require("data.family").fp(r(base), r(base + 21), r(base + 22), r(base + 6) * 256 + r(base + 7))
        out[#out + 1] = m
    end
    return out, active
end

-- The screen's text (all 18 rows of 20 tiles), for the log.
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

name_of = function(sp) return Names[sp] or ("#" .. tostring(sp)) end
move_name = function(id)
    local mv = D.moves[id]
    if not mv then return "#" .. tostring(id) end
    return (mv[1]:gsub("_M$", ""):gsub("_", " "):lower():gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end
M.move_name = move_name
M.species_name = function(sp) return name_of(sp) end

-- ------------------------------------------------------------ driving it

local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end

-- Walk a menu cursor to (y, x): reads wMenuCursorY/X between presses.
local function cursor_to(y, x)
    for _ = 1, 12 do
        local cy, cx = r(A.menuY), r(A.menuX)
        if cy == y and (x == nil or cx == x) then return true end
        press(cy < y and "Down" or cy > y and "Up" or (x and cx < x) and "Right" or "Left")
        frames(4)
    end
    return r(A.menuY) == y and (x == nil or r(A.menuX) == x)
end

-- The Balls pocket: {[id] = count} and the order {id, ...}.
function M.balls_bag()
    local bag, order = {}, {}
    local n = math.min(r(A.numBalls), 12)
    for i = 0, n - 1 do
        local id = r(A.balls + i * 2)
        if id == 0xFF then break end
        bag[id] = (bag[id] or 0) + r(A.balls + i * 2 + 1)
        order[#order + 1] = id
    end
    return bag, order
end

local function is_ball(id) return id == 1 or id == 2 or id == 4 or id == 5 or (id >= 157 and id <= 164) end

-- From the battle menu with the cursor on PACK: open it, go to the Balls
-- pocket, to ballId, and use it. (The live bot's way: A until the list takes
-- input; Right only while the highlighted item isn't a ball - the Pack
-- remembers its pocket; Up/Down by the highlighted item, each press waiting
-- for it to change; A only on that exact ball; USE is already highlighted
-- in the submenu - no Up, it wraps to QUIT.) true, or false (backed out).
local function throw_ball(ballId)
    local function open() return (r(A.joypadFilter) & 0xC0) == 0xC0 end
    for _ = 1, 4 do
        press("A")
        for _ = 1, 40 do if open() or not State.in_battle() then break end; emu.frameadvance() end
        if open() then break end
    end
    if not open() then return false end
    frames(10)
    for _ = 1, 3 do
        if is_ball(r(A.curItem)) then break end
        local before = r(A.curItem)
        press("Right")
        for _ = 1, 20 do if r(A.curItem) ~= before then break end; emu.frameadvance() end
        frames(6)
    end
    for _ = 1, 16 do
        local cur = r(A.curItem)
        if cur == ballId then
            press("A")
            -- USE / QUIT: A once it's waiting, with the cursor on USE.
            for _ = 1, 90 do if Screen.menu_waiting() then break end; emu.frameadvance() end
            if r(A.menuY) == 1 then press("A"); return true end
            press("B"); frames(10); press("B")
            return false
        end
        local _, order = M.balls_bag()
        local target, here = nil, nil
        for i, id in ipairs(order) do if id == ballId then target = i end; if id == cur then here = i end end
        if not target then break end
        press((here == nil or here > target) and "Up" or "Down")
        for _ = 1, 15 do if r(A.curItem) ~= cur then break end; emu.frameadvance() end
    end
    press("B")
    return false
end

-- The Items pocket: {[id] = count} and the order {id, ...}.
function M.items_bag()
    local bag, order = {}, {}
    local n = r(A.numItems)
    if n > 20 then n = 0 end
    for i = 0, n - 1 do
        local id = r(A.numItems + 1 + i * 2)
        if id == 0xFF then break end
        bag[id] = (bag[id] or 0) + r(A.numItems + 2 + i * 2)
        order[#order + 1] = id
    end
    return bag, order
end

-- From the battle menu with the cursor on PACK: open it, round to the
-- Items pocket, the potion, USE, then the one fighting (party slot,
-- 0-based) on "Use on which PKMN?". As throw_ball: each step waits for
-- what it pressed to show (the pocket, the highlighted item, the menus).
-- true once it's given; false after backing out (the battle menu again).
local function use_potion(itemId, slot0)
    local function open() return (r(A.joypadFilter) & 0xC0) == 0xC0 end
    local function back_out()
        for _ = 1, 3 do press("B"); frames(15) end
        return false
    end
    for _ = 1, 4 do
        press("A")
        for _ = 1, 40 do if open() or not State.in_battle() then break end; emu.frameadvance() end
        if open() then break end
    end
    if not open() then return false, "notopen" end
    frames(10)
    for _ = 1, 4 do
        local p = r(A.curPocket)
        if p == 0 then break end
        press(p == 3 and "Right" or "Left")                 -- (Items is the first pocket)
        for _ = 1, 20 do if r(A.curPocket) ~= p then break end; emu.frameadvance() end
        frames(6)
    end
    if r(A.curPocket) ~= 0 then return back_out() end
    for _ = 1, 24 do
        local cur = r(A.curItem)
        if cur == itemId then
            press("A")
            -- USE / QUIT: A once it's waiting, with the cursor on USE.
            for _ = 1, 90 do if Screen.menu_waiting() then break end; emu.frameadvance() end
            if r(A.menuY) ~= 1 then return back_out() end
            press("A")
            -- "Use on which PKMN?": the party list (give it time to draw).
            frames(30)
            for _ = 1, 120 do if Screen.menu_waiting() then break end; emu.frameadvance() end
            frames(8)
            cursor_to(slot0 + 1)
            if r(A.menuY) ~= slot0 + 1 then return back_out() end
            press("A")
            return true
        end
        local _, order = M.items_bag()
        local target, here = nil, nil
        for i, id in ipairs(order) do if id == itemId then target = i end; if id == cur then here = i end end
        if not target then break end
        press((here == nil or here > target) and "Up" or "Down")
        for _ = 1, 15 do if r(A.curItem) ~= cur then break end; emu.frameadvance() end
    end
    return back_out()
end

-- A party member started evolving (the hook): a keeper? Then hold B until
-- the game says it stopped. Returns the frames it took (0 if nothing to do).
local function check_evolve(say)
    if not H.evolve then return 0 end
    H.evolve = nil
    local slot = r(A.curPartyMon)
    local base = A.party + slot * A.partyLen
    local fp = require("data.family").fp(r(base), r(base + 21), r(base + 22), r(base + 6) * 256 + r(base + 7))
    -- (how many copies stay: of twins - every DV the same - one may evolve)
    local have = M.copies and M.copies(fp, r(base)) or 1
    if not require("data.goals").stays(M.no_evolve, fp, r(base), have) then return 0 end
    say(string.format("%s is the one that stays a %s in the living dex - stopping its evolution (B).", name_of(r(base)), name_of(r(base))))
    H.evolveStopped = nil
    local n = 0
    while n < 900 and not H.evolveStopped do
        joypad.set({B = true}); emu.frameadvance(); n = n + 1
    end
    H.evolveStopped = nil
    emu.frameadvance()
    return n
end

-- Fight the battle out. opts.say(text) for the log. Returns "won", "lost"
-- or "stuck"; with opts.wild, "flee" when M.wild_verdict says run (the
-- battle menu is up: the caller runs), and no switching (the old Kill mode
-- never did). opts.catch: catch it instead (M.catch_action each turn) -
-- "noballs" when there are none left (the battle menu is up).
function M.fight(opts)
    opts = opts or {}
    local say = opts.say or log
    -- (keep what the game did in the last second - the battle menu may
    -- have opened just before we were called - and drop anything older,
    -- from earlier battles)
    local now = emu.framecount()
    -- (a time ahead of now: a savestate was loaded since - drop it too)
    for k, f in pairs(H) do if now - f > 60 or f > now then H[k] = nil end end
    if not H.forget and not H.stopLearning and not H.offer then ctx = nil end
    if opts.menuOpen then H.battleMenu = now end    -- (the caller waited for it)
    M.badgeTypes = M.badge_types(r(0xD857), r(0xD858))   -- (wJohtoBadges, wKantoBadges)
    local want = {}            -- what we chose and are steering the menus to
    local switchedFor = {}     -- enemy species we've already switched for (once each)
    local cst = {regular = opts.regular}   -- the catch's state across turns (regular: not a shiny - crits risked)
    -- (the Discord message's "Caught with 3 Poke Balls" / "Fainted after...":
    -- cst.balls = {[ball id] = thrown}, cst.endHp = the wild one's HP at the end)
    cst.balls = {}
    M.lastCatch = cst
    local lastEnemy = nil
    local n = 0
    local idle, wasIdle = 0, false
    while State.in_battle() and n < 60 * 60 * 20 do
        if not wasIdle then idle = 0 end
        wasIdle = false
        if H.lost then break end
        if H.evolve then
            n = n + check_evolve(say) + 1
        elseif H.forget then
            -- "Delete an older move to make room for X?" - decide (the YES/NO follows)
            H.forget = nil
            local party = M.party_mons()
            local who = r(A.curPartyMon)
            local mon, new = party[who + 1], r(A.newMove)
            local slot, worst, rate = M.learn(mon, new)
            want.forgetSlot = slot
            if slot then
                say(string.format("%s learns %s in place of %s.", name_of(mon.species), move_name(new), move_name(mon.moves[slot][1])))
            else
                say(string.format("%s doesn't learn %s (keeps its moves).", name_of(mon.species), move_name(new)))
            end
        elseif H.forgetList then
            H.forgetList = nil
            frames(10)
            if want.forgetSlot then cursor_to(want.forgetSlot) end
            want.forgetSlot = nil
            press("A")
            n = n + 60
        elseif H.offer then
            -- The trainer's next mon is loaded: would another of ours do better?
            H.offer = nil
            local party, active = M.party_mons()
            local enemy = M.battle_mon(A.emon)
            local cur = M.matchup(party[active + 1], enemy)
            local i, s = M.pick(party, enemy, active)
            want.offerTo = (i and s - cur > 0.3) and i or nil
            if want.offerTo then
                say(string.format("%s is coming - switching to %s.", name_of(enemy.species), name_of(party[i + 1].species)))
                want.switchTo = i
            end
        elseif H.yesNo or Screen.yes_no_waiting() then
            -- (the box's hook, or one seen on screen waiting for input)
            H.yesNo = nil
            Screen.wait_yes_no(300)        -- (answer once it takes input)
            local q = ctx; ctx = nil
            local yes = false
            if q == "forget" then yes = want.forgetSlot ~= nil
            elseif q == "stop" then yes = true
            elseif q == "offer" then yes = want.offerTo ~= nil
            else
                local text = M.screen_text()
                if text:match("Use next") then          -- (a wild battle, after a faint)
                    yes = true
                    -- (only one that mustn't fight is left - the Zubat: run instead)
                    if not opts.catch then
                        local party, active = M.party_mons()
                        local other = false
                        for i, mon in ipairs(party) do
                            if (i - 1) ~= active and mon.hp > 0 and not mon.egg and not M.no_fight[mon.fp or ""] then other = true end
                        end
                        if not other then
                            yes = false
                            say("Only the second catcher is left - it doesn't fight: running.")
                        end
                    end
                else say("(A YES/NO I didn't expect - answering NO: " .. text .. ")") end
            end
            Screen.answer(yes, press)
            n = n + 13
        elseif H.partyMenu then
            H.partyMenu = nil
            frames(15)
            local party, active = M.party_mons()
            local enemy = M.battle_mon(A.emon)
            local target = want.switchTo
            if (not target or party[target + 1].hp == 0) and opts.catch then
                -- (catching: it's asleep and still high - the one fainted was
                -- weakening it: another that can weaken it safely (the user,
                -- 2026-11-08); else whoever can sleep it, else whoever lasts longest)
                target = nil
                local enemyAsleep = (enemy.status or 0) & 0x07 ~= 0
                if enemyAsleep and enemy.hp > M.CATCH_HP * enemy.maxhp then target = M.weakener(party, active, enemy) end
                if target then
                    say(string.format("Sending out %s to go on weakening %s.", name_of(party[target + 1].species), name_of(enemy.species)))
                else
                    local bestHp = -1
                    for i, mon in ipairs(party) do
                        if mon.hp > 0 and not mon.egg and (i - 1) ~= active then
                            local s = mon.hp + (M.sleep_move(mon) and 10000 or 0)
                            if s > bestHp then target, bestHp = i - 1, s end
                        end
                    end
                    if target then say(string.format("Sending out %s to go on catching.", name_of(party[target + 1].species))) end
                end
            elseif not target or party[target + 1].hp == 0 then
                target = M.pick(party, enemy, active)
                if target then say(string.format("Sending out %s against %s.", name_of(party[target + 1].species), name_of(enemy.species))) end
            end
            want.switchTo = nil
            if target then cursor_to(target + 1) end
            press("A")
            n = n + 60
        elseif H.monMenu then
            -- SWITCH / STATS / CANCEL: SWITCH - picked by what's on screen
            -- (the ▶ read off the tile map, A until it's gone from there: an
            -- A while the box was drawing was lost - seen in the game,
            -- 2026-11-08, stuck on this box)
            H.monMenu = nil
            local ok, why = Screen.choose("SWITCH", press)
            if not ok then say("(The SWITCH box: " .. tostring(why) .. " - backing out.)"); press("B") end
            n = n + 30
        elseif H.moveSelect then
            H.moveSelect = nil
            frames(10)
            if want.move then cursor_to(want.move) end
            want.move = nil
            press("A")
            n = n + 30
        elseif H.battleMenu then
            H.battleMenu = nil
            frames(10)
            local party, active = M.party_mons()
            local me, enemy = party[active + 1], M.battle_mon(A.emon)
            if enemy.species ~= lastEnemy then
                lastEnemy = enemy.species
                say(string.format("%s (Lv %d) vs %s (Lv %d).", name_of(me.species), me.level, name_of(enemy.species), enemy.level))
            end
            -- (did the last potion go through? the count in the Pack says)
            if cst.healPending then
                local bag = M.items_bag()
                if (bag[cst.healPending.id] or 0) >= cst.healPending.count then cst.healFails = (cst.healFails or 0) + 1 end
                cst.healPending = nil
            end
            -- Critically low against a trainer, or while catching: a potion?
            if not opts.wild or opts.catch then
                local bag = M.items_bag()
                local heal = M.heal_action(me, enemy, bag, cst, r(A.disabledMove))
                if heal then
                    cst.heals = (cst.heals or 0) + 1
                    cst.healPending = {id = heal.id, count = bag[heal.id] or 0}
                    say(string.format("%s is at %d/%d HP and %s could knock it out - using a %s.", name_of(me.species), me.hp, me.maxhp,
                        name_of(enemy.species), D.items[heal.id] and D.items[heal.id]:gsub("_", " "):lower() or "potion"))
                    cursor_to(2, 1)                            -- PACK
                    local used, why = use_potion(heal.id, active)
                    if not used then
                        cst.healFails = (cst.healFails or 0) + 1
                        cst.healPending = nil
                        say("(Couldn't use it from the Pack - fighting on.)")
                        -- (the Pack never opened: the battle menu is still up - decide again)
                        if why == "notopen" then H.battleMenu = emu.framecount() end
                    end
                    n = n + 40
                    goto continue
                end
            end
            if opts.catch then
                local asleep = enemy.status & 0x07 ~= 0
                local meAsleep = (me.status or 0) & 0x07 ~= 0
                local sl = M.sleep_move(me, r(A.disabledMove))
                local sleeper = nil
                -- (no sleep move out - or ours was put to sleep itself (a wild
                -- Gastly's Hypnosis): an awake one that has one, twice at most)
                if not asleep and (not sl or meAsleep) and (cst.switches or 0) < M.SWITCH_CAP then
                    for i, mon in ipairs(party) do
                        if (i - 1) ~= active and mon.hp > 0 and not mon.egg and (mon.status or 0) & 0x07 == 0 and M.sleep_move(mon) then
                            sleeper = i - 1; break
                        end
                    end
                end
                if sleeper then
                    cst.switches = (cst.switches or 0) + 1
                    want.switchTo = sleeper
                    say(string.format("Switching to %s to put %s to sleep%s.", name_of(party[sleeper + 1].species), name_of(enemy.species),
                        meAsleep and (" - " .. name_of(me.species) .. " is asleep") or ""))
                    cursor_to(1, 2); press("A")              -- PKMN
                else
                    local act = M.catch_action(me, enemy, M.balls_bag(), cst, r(A.disabledMove))
                    -- (a regular one with nothing that can't knock it out outright: balls, no switching)
                    local helper = act.noSafeMove and not cst.regular and (cst.weakSwitches or 0) < M.SWITCH_CAP and M.weakener(party, active, enemy)
                    -- (nobody can weaken it safely: risk a critical hit - a move
                    -- only a crit could knock it out with - unless it's a rare
                    -- one: then the balls go at it asleep, whatever its HP)
                    if act.noSafeMove and not helper and not cst.regular then
                        local canSleep = asleep
                        if not canSleep then
                            for _, mon in ipairs(party) do
                                if mon.hp > 0 and not mon.egg and M.sleep_move(mon) then canSleep = true end
                            end
                        end
                        local choice = M.no_safe_choice(enemy, canSleep)
                        if choice == "rare" then
                            if not cst.rareSaid then
                                cst.rareSaid = true
                                say(string.format("Nobody here can weaken %s without risking a critical hit - it's a rare one (%d%% at best): balls only.",
                                    name_of(enemy.species), D.rarity[enemy.species][1]))
                            end
                        elseif choice == "low" or choice == "asleep" then
                            if not cst.lowSaid then
                                cst.lowSaid = true
                                say(string.format("%s is at %d%% HP and the next hit could knock it out with a critical hit - balls from here%s.",
                                    name_of(enemy.species), math.floor(enemy.hp * 100 / enemy.maxhp + 0.5),
                                    choice == "asleep" and " (it can be put to sleep: no risk taken)" or ""))
                            end
                        else
                            local slot, id = M.weaken_move(me, enemy, r(A.disabledMove), true)
                            if slot then
                                cst.weakenTurns = (cst.weakenTurns or 0) + 1
                                act = {kind = "weaken", slot = slot, id = id, risky = true}
                            end
                        end
                    end
                    if helper then
                        -- (ours could knock it out with a critical hit: a weaker teammate does the weakening)
                        cst.weakSwitches = (cst.weakSwitches or 0) + 1
                        want.switchTo = helper
                        say(string.format("Switching to %s to weaken %s - every move %s has could knock it out with a critical hit.",
                            name_of(party[helper + 1].species), name_of(enemy.species), name_of(me.species)))
                        cursor_to(1, 2); press("A")              -- PKMN
                    elseif act.kind == "ball" then
                        if not act.id then
                            say("No balls left - stopping here, the battle menu is up. It's yours.")
                            return "noballs"
                        end
                        local bag = M.balls_bag()
                        say(string.format("Throwing a %s (%d left) - %s at %d/%d HP%s.", D.items[act.id] and D.items[act.id]:gsub("_", " "):lower() or "ball",
                            (bag[act.id] or 1) - 1, name_of(enemy.species), enemy.hp, enemy.maxhp, asleep and ", asleep" or ""))
                        cursor_to(2, 1)                        -- PACK
                        cst.throws = (cst.throws or 0) + 1
                        if throw_ball(act.id) then
                            cst.balls[act.id] = (cst.balls[act.id] or 0) + 1
                        else
                            say("(Couldn't get to the ball in the Pack - trying again next turn.)")
                        end
                    else
                        want.move = act.slot
                        if act.kind == "wait" then
                            say(string.format("%s is asleep and %s is at %d/%d HP - waiting it out (a ball now would be wasted).",
                                name_of(me.species), name_of(enemy.species), enemy.hp, enemy.maxhp))
                        else
                            say(string.format("%s uses %s (%s).", name_of(me.species), move_name(act.id),
                                act.kind == "sleep" and "to put it to sleep"
                                    or act.risky and "to weaken it - nobody can do it safely, only a critical hit would knock it out"
                                    or "to weaken it - it can't knock it out"))
                        end
                        cursor_to(1, 1); press("A")            -- FIGHT
                    end
                end
                n = n + 40
                goto continue
            end
            -- A teammate who can take this one on (passes the Kill rules), the
            -- best matchup - never the catcher at its sweet spot (EXP would
            -- take it past it - M.no_partner). 0-based index or nil.
            local function train_partner()
                local partner, best = nil, nil
                for i, mon in ipairs(party) do
                    if i > 1 and mon.hp > 0 and not mon.egg and not M.no_partner[mon.fp or ""] and M.wild_verdict(mon, enemy, nil) then
                        if M.partner_first and mon.fp == M.partner_first then return i - 1 end
                        local sc = M.matchup(mon, enemy)
                        if not best or sc > best then partner, best = i - 1, sc end
                    end
                end
                return partner
            end
            -- (opts.trainee: true, or the fingerprint of the one in training -
            -- then only it counts as the trainee)
            local isTrainee = opts.trainee == true or (opts.trainee ~= nil and opts.trainee ~= false and me.fp == opts.trainee)
            if opts.wild and isTrainee and active == 0 and not cst.trainSwitched then
                -- Switch-training: the one being trained leads (it's in the
                -- battle, so it shares the EXP), and on the first turn a
                -- teammate who can take this one on comes in and wins -
                -- unless it can win alone, safely: then all the EXP is its.
                cst.trainSwitched = true
                local partner = train_partner()
                local solo, turns, whyNot = M.solo_ok(me, enemy, r(A.disabledMove), partner and party[partner + 1] or nil)
                if solo then partner = nil end
                if solo then
                    say(string.format("%s takes %s on alone (about %d turn%s) - all the EXP.", name_of(me.species), name_of(enemy.species),
                        turns, turns == 1 and "" or "s"))
                end
                local because = ({weak = "its best hit does under a quarter", pp = "not enough PP to win alone",
                    hurt = "it would get hurt too much", slow = "faster for the EXP"})[whyNot or ""]
                -- (nobody to switch to, and it can't win alone properly: run -
                -- no PP spent on a fight it can't finish)
                if not solo and not partner and (whyNot == "weak" or whyNot == "pp") then
                    return "flee", string.format("%s can't take %s on alone (%s) and nobody can come in", name_of(me.species), name_of(enemy.species), because)
                end
                if partner then
                    want.switchTo = partner
                    say(string.format("Switch-training: %s out, %s in - they share the EXP%s.", name_of(me.species), name_of(party[partner + 1].species),
                        because and (" (" .. because .. ")") or ""))
                    cursor_to(1, 2); press("A")            -- PKMN
                    n = n + 40
                    goto continue
                end
            end
            if opts.wild then
                local ok, why, kind = M.wild_verdict(me, enemy, r(A.disabledMove))
                if not ok and kind ~= "status" and isTrainee and active == 0 and not cst.lowSwitched then
                    -- (the trainee dipped too low: a teammate takes over rather
                    -- than running - the trainee was in, it still gets its EXP;
                    -- the user, 2026-11-08)
                    cst.lowSwitched = true
                    local partner = train_partner()
                    if partner then
                        want.switchTo = partner
                        say(string.format("%s is low (%s) - %s takes over; they share the EXP.", name_of(me.species), why,
                            name_of(party[partner + 1].species)))
                        cursor_to(1, 2); press("A")            -- PKMN
                        n = n + 40
                        goto continue
                    end
                end
                if not ok then return "flee", why end
            end
            local to = not opts.wild and not switchedFor[enemy.species] and M.should_switch(party, me, active, enemy)
            if to then
                switchedFor[enemy.species] = true
                want.switchTo = to
                say(string.format("Switching to %s - a better matchup against %s.", name_of(party[to + 1].species), name_of(enemy.species)))
                cursor_to(1, 2)                 -- PKMN
            else
                local levels = {mine = {}, theirs = {}}
                for i = 1, 7 do levels.mine[i] = r(A.myLevels + i - 1); levels.theirs[i] = r(A.enemyLevels + i - 1) end
                local setup = M.setup_move(me, enemy, r(A.disabledMove), levels)
                if setup then
                    want.move = setup.slot
                    say(string.format("%s uses %s first (about %d turns to win instead of %d).", name_of(me.species), move_name(setup.id),
                        math.ceil(setup.turns), setup.without))
                else
                    local slot, id, share = M.best_move(me, enemy, r(A.disabledMove))
                    want.move = slot
                    if id then
                        say(string.format("%s uses %s (%s).", name_of(me.species), move_name(id),
                            share >= 1 and "knocks it out" or string.format("~%d%% of its HP", math.floor(share * 100))))
                    end
                end
                cursor_to(1, 1)                 -- FIGHT
            end
            press("A")
            n = n + 40
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "A")
        else
            emu.frameadvance()
            n = n + 1
            -- Watchdog: nothing for 1.5 s but a ▶ on screen - a menu whose
            -- hook was missed or whose press was lost. Act on what it shows.
            wasIdle = true
            idle = idle + 1
            if idle >= 90 then
                idle = 0
                local c = Screen.cursor()
                local w = c and c.word:upper() or ""
                if w == "SWITCH" or w == "STATS" then
                    say("(The SWITCH box was left waiting - picking SWITCH from the screen.)")
                    local ok = Screen.choose("SWITCH", press)
                    if not ok then press("B") end
                elseif w == "FIGHT" or w == "PKMN" or w == "PACK" or w == "RUN" then
                    say("(The battle menu was left waiting - deciding again.)")
                    H.battleMenu = emu.framecount()
                elseif c then
                    say("(A menu was left waiting in battle: " .. Screen.text() .. " - pressing B.)")
                    press("B")
                end
            end
        end
        ::continue::
    end
    -- (out of the battle: let the screen come back - an evolution may come now)
    local lost = H.lost
    cst.endHp = r16(A.emon + 16)     -- (wEnemyMon's HP: 0 = it fainted)
    for _ = 1, 600 do
        if H.evolve then check_evolve(say) end
        if not State.in_battle() and not ButtonWait.waiting() then break end
        if ButtonWait.waiting() then ButtonWait.advance(press, "A") else emu.frameadvance() end
    end
    frames(30)
    if lost then return "lost" end
    if State.in_battle() then return "stuck" end
    return "won"
end

return M
