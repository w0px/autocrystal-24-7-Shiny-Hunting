-- walker.lua (lives in modules/data/)
-- Walks the player somewhere in BizHawk: plans with world.lua from where
-- the game says we are (game_state.lua), then holds each direction until
-- the step happens and checks we landed where the plan said. Anything
-- unexpected - someone walked into the way, a door put us a step off, a
-- phone call - and it plans again from where we really are. At 1x, like a
-- player would: no savestates, nothing skipped.
--
-- Interruptions:
--   * a script (phone call, someone stopping you): its text is moved on
--     with B when the game waits for a button (button_wait.lua), until it
--     ends - B never says YES to anything;
--   * a wild battle: checked for a shiny first. A shiny stops the walk
--     (result "shiny") and nothing is pressed - it's yours (or the
--     catcher's). Anything else: RUN, as many tries as it takes;
--   * a trainer battle: fought out by data/fighter.lua when M.fighter is
--     set (best move, best matchup); a loss stops the walk ("whiteout").
--     Without a fighter it stops the walk (result "trainer").
--   * after a battle, the lead (the first that isn't fainted) under
--     M.LOW_HP (30%) of its HP, or anyone with a status (poisoned...):
--     before the first badge, the nearest Pokemon Center wherever we are;
--     in a cave (or tower, forest...) a low lead with the others healthy
--     fights on, even if it faints; else a Center within M.CENTER_NEAR
--     (150) steps - it goes there, heals and walks on; none that close -
--     the bag (data/bag.lua: Antidote etc., potions); still low or
--     poisoned - the nearest Center, however far. After a heal, the
--     town's Mart if the bag wants stock (data/mart.lua, M.mart).
--
-- Safety: on arriving in each map the walker checks the map data against
-- the game's own collision for the tiles around the player
-- (wPlayerTileCollision and wTileDown/Up/Left/Right); a mismatch stops it
-- (result "data") rather than walk on a wrong map.

local M = {}

local World, State, ButtonWait
local log = print

-- In-battle menu cursor (wMenuCursorY/X): RUN is row 2, column 2.
local MENU_CURSOR_Y, MENU_CURSOR_X = 0xCFA9, 0xCFAA
local RUN_CURSOR = {y = 2, x = 2}
-- LoadBattleMenu (09:4EF2): runs as the FIGHT/PKMN/PACK/RUN menu opens -
-- the same hook wild.lua uses. Until it has, the cursor bytes are stale.
local LOAD_BATTLE_MENU = 0x9 * 0x4000 + (0x4EF2 % 0x4000)
local menuOpened = false
local ENEMY_DVS = 0xD20C
local ENEMY_SPECIES, ENEMY_LEVEL = 0xD206, 0xD213   -- wEnemyMon: species, level
local TEMP_WILD = 0xD22E                             -- wTempWildMonSpecies: this battle's species, set first
-- The game's collision under and around the player (walk_loop.lua's check).
local STANDING_TILE, TILE_DOWN = 0xD4E4, 0xC2FA

M.stepsTaken = 0
M.plans = 0          -- plans made (1 per walk + every re-plan)
-- The last moves, for the log when something goes wrong: {map, x, y (where
-- it ended up), dir, kind, planned "x,y", result}.
M.trail = {}
local function remember(mv, r)
    local w = State.where()
    table.insert(M.trail, {map = w.map, x = w.x, y = w.y, dir = mv.dir, kind = mv.kind, plan = mv.x .. "," .. mv.y, r = r})
    if #M.trail > 12 then table.remove(M.trail, 1) end
end
function M.trail_text()
    local t = {}
    for _, e in ipairs(M.trail) do
        t[#t + 1] = string.format("%s %s>%d,%d%s", e.dir, e.kind == "step" and "" or e.kind .. " ", e.x, e.y,
            (e.r == "ok") and "" or string.format(" [%s, planned %s]", e.r, e.plan))
    end
    return table.concat(t, "  ")
end
-- Trainers on this map who could see (x, y) - in any way, within sight -
-- with the way they face and whether their beaten flag is set.
function M.trainers_near(key, x, y, flag)
    local out = {}
    for _, o in ipairs(World.map(key).objs) do
        local ox, oy, move, otype, sight, script, beat = o[1], o[2], o[4], o[7], o[8], o[9], o[11]
        if otype == "TRAINER" and sight > 0 then
            local dx, dy = x - ox, y - oy
            if (dx == 0 and dy ~= 0 and math.abs(dy) <= sight) or (dy == 0 and dx ~= 0 and math.abs(dx) <= sight) then
                out[#out + 1] = string.format("%s at %d,%d (%s, sight %d, %s)", script, ox, oy, move, sight,
                    beat == "" and "no beaten flag" or (flag(beat) and "flag says beaten" or "not beaten"))
            end
        end
    end
    return out
end
M.BUILD = "29 (nurse retries, Violet step by fly point)"   -- shown by walk_test, to tell a reload took

M.LOW_HP = 0.30       -- the lead under this share of its HP gets healed
M.CENTER_NEAR = 150   -- a Pokemon Center this many steps away is worth the walk (else potions)
M.HEALTHY = 0.50      -- in a cave, the others all over this: the lead fights on
-- One fainted (the user, 2026-11-09): a Center only when fewer than
-- M.CORE_NEEDED of the core are over M.CORE_HP - the core: the starter, the
-- specialists, the catcher once it's done levelling (M.core_slots(party) ->
-- {[slot] = true}, set by play; without it, everyone counts).
M.CORE_HP = 0.70
M.CORE_NEEDED = 2
M.core_slots = nil
-- Switch-training (opts.trainee): the partner who comes in to finish the
-- fights (M.partner_slot() -> its party slot, set by play) is looked after
-- too - under M.LOW_HP it heals like a low lead (the user's log,
-- 2026-11-09: Totodile at 24% couldn't come in any more, and the Lv 5
-- Caterpie ran from everything, the lead itself fine).
M.partner_slot = nil
M.CENTER_BEFORE_BADGE = true   -- no badges yet: always the Center (Cherrygrove and Violet are close)

-- mem: data/memory.lua (for the battle menu hook), already set to Crystal's
-- ROM bank address (Mem.SetRomBankAddress("Crystal")).
-- M.fighter: data/fighter.lua, set up - then trainer battles are fought.
-- M.bag: data/bag.lua, set up - then a status is cured after battles and a
-- low lead healed. M.mart: data/mart.lua - then it shops after a heal.
M.fighter = nil
M.bag = nil
M.mart = nil
M.teamer = nil      -- data/teamer.lua: after a heal, the party set to the team (PC, order)
-- Field healing (data/pc.lua field_heal: the healer's Milk Drink /
-- Softboiled): function(share, opts) -> times healed. Set by play; nil: none.
M.field_heal = nil
-- spare_slot(k) -> true: party member k may faint rather than get an
-- Antidote (set by play: the first section, a Center near, not the starter,
-- catcher or last specialist - the user, 2026-11-08). nil: never.
M.spare_slot = nil
M.should_stop = nil -- the launcher's Stop button: true -> go() returns false, "stopped"
M.on_encounter = nil -- (species, level, atk, def, spe, spc DVs, shiny) for each wild one - the stream overlay
M.on_walk = nil      -- () between moves on the map - the launcher's autosave
function M.setup(world, state, buttonWait, mem, logger, fighter, bag, mart, teamer)
    World, State, ButtonWait = world, state, buttonWait
    M.fighter = fighter
    M.bag = bag
    M.mart = mart
    M.teamer = teamer
    log = logger or print
    mem.RegisterROMHook(LOAD_BATTLE_MENU, function() menuOpened = true end, "Walker Battle Menu")
end

local function frames(n) for _ = 1, n do emu.frameadvance() end end

local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end

-- Whether the game's collision around the player matches the map data.
local function data_matches()
    local w = State.where()
    local c = World.coll(w.map, w.x, w.y)
    if c == nil then return false, "no such tile in the data" end
    if c ~= State.read8(STANDING_TILE) then
        return false, string.format("standing on %02X, data says %02X", State.read8(STANDING_TILE), c)
    end
    local around = {{0, 1}, {0, -1}, {-1, 0}, {1, 0}}
    for i, o in ipairs(around) do
        local t = World.tile(w.map, w.x + o[1], w.y + o[2])
        local g = State.read8(TILE_DOWN + i - 1)
        -- (off the map with no connection the game reads its border block: skip those)
        if t ~= nil and t ~= g then
            return false, string.format("tile %d,%d is %02X in the game, %02X in the data", w.x + o[1], w.y + o[2], g, t)
        end
    end
    return true
end

-- A shiny in the wild battle now? (DVs: Def, Spe, Spc 10, Atk 2/3/6/7/10/11/14/15.)
function M.enemy_shiny()
    local a, b = State.read8(ENEMY_DVS), State.read8(ENEMY_DVS + 1)
    local atk, def, spe, spc = a >> 4, a & 15, b >> 4, b & 15
    return def == 10 and spe == 10 and spc == 10 and (atk & 2) == 2
end

local function at_battle_menu()
    if not menuOpened then return false end
    local y, x = State.read8(MENU_CURSOR_Y), State.read8(MENU_CURSOR_X)
    return (y == 1 or y == 2) and (x == 1 or x == 2)
end

-- A wild battle: shiny -> "shiny" (untouched); else run until it's over.
-- untilMenu: stop at the battle menu instead ("menu") - for fighting it.
-- atMenu: the battle menu is up already (the fighter handed it back to run).
local function run_from_wild(untilMenu, atMenu)
    local waited = 0
    if not atMenu then
        menuOpened = false
        -- The stream overlay's encounter list (species, level, DVs): as soon
        -- as the wild one is on screen - wEnemyMon holds this battle's once
        -- its species is wTempWildMonSpecies and it isn't the last one
        -- reported (the struct keeps the last battle's until then) - else
        -- at the battle menu at the latest.
        local reported = false
        local function report(atMenuNow)
            if reported or not M.on_encounter then return end
            local sp = State.read8(ENEMY_SPECIES)
            local a, b = State.read8(ENEMY_DVS), State.read8(ENEMY_DVS + 1)
            local key = sp .. ":" .. a .. ":" .. b .. ":" .. State.read8(ENEMY_LEVEL)
            if not atMenuNow and (sp == 0 or sp ~= State.read8(TEMP_WILD) or key == M.lastEncounterKey) then return end
            reported, M.lastEncounterKey = true, key
            pcall(M.on_encounter, sp, State.read8(ENEMY_LEVEL), a >> 4, a & 15, b >> 4, b & 15, M.enemy_shiny())
        end
        -- Text first ("Wild X appeared!"), up to the menu.
        while State.in_battle() and waited < 1800 do
            report(false)
            if at_battle_menu() then break end
            waited = waited + ButtonWait.advance(press, "B")
        end
        if not State.in_battle() then return "over" end
        report(true)
        if M.enemy_shiny() then return "shiny" end
    end
    if untilMenu then return "menu" end
    for attempt = 1, 10 do
        frames(10)   -- (the menu takes buttons a moment after it opens)
        -- To RUN: down a row, right a column, then A.
        local tries = 0
        while State.in_battle() and tries < 12 do
            local y, x = State.read8(MENU_CURSOR_Y), State.read8(MENU_CURSOR_X)
            if y == RUN_CURSOR.y and x == RUN_CURSOR.x then break end
            press(y < RUN_CURSOR.y and "Down" or x < RUN_CURSOR.x and "Right" or y > RUN_CURSOR.y and "Up" or "Left")
            frames(4)
            tries = tries + 1
        end
        menuOpened = false
        press("A")
        -- Out ("Got away safely!"), or back at the menu ("Can't escape!").
        waited = 0
        frames(20)
        while State.in_battle() and waited < 1200 do
            if at_battle_menu() then break end
            waited = waited + ButtonWait.advance(press, "B")
        end
        if not State.in_battle() then
            frames(30)
            return "over"
        end
        log("Can't escape! Trying again.")
    end
    return "stuck"
end

-- Wait out a script (a phone call, a cutscene), moving its text on with B.
local function sit_out_script(limit)
    local n = 0
    while State.script_running() and not State.in_battle() and n < (limit or 3600) do
        n = n + ButtonWait.advance(press, "B")
    end
    frames(4)
end

-- A shiny (the battle menu is up): opts.catch - catch it (fighter.fight
-- with catch: sleep it, weaken it safely, balls); else stop ("shiny") and
-- leave it to the user. No balls left: stop too ("shiny"). Caught or not
-- is told by opts.count_owned() before and after. nil to walk on, or why to stop.
-- M.on_catch_result({species, level, shiny, outcome, balls}) after each:
-- outcome "caught" | "fainted" | "fled" | "lost" | "noballs" | "stuck" |
-- "stopped" (not catching) - the launcher's Discord message.
local function tell_result(species, level, shiny, outcome, balls)
    if M.on_catch_result then
        pcall(M.on_catch_result, {species = species, level = level, shiny = shiny, outcome = outcome, balls = balls or {}})
    end
end
local function handle_shiny(opts, notShiny)
    local say = opts.say or log
    if not (opts.catch and M.fighter) then
        if not notShiny then tell_result(State.read8(ENEMY_SPECIES), State.read8(ENEMY_LEVEL), true, "stopped") end
        return "shiny"
    end
    local species, level = State.read8(ENEMY_SPECIES), State.read8(ENEMY_LEVEL)
    local name = M.fighter.species_name(species)
    if notShiny then
        say(string.format("A wild %s (Lv %d) - one I'm after. Catching it.", name, level))
    else
        say(string.format("A SHINY %s (Lv %d)! Catching it.", name, level))
    end
    local before = opts.count_owned and opts.count_owned()
    local mapBefore = State.where().map
    -- (a regular one - the catcher or the Zubat: crits risked, it doesn't
    -- matter if it faints; the user, 2026-11-09 - 10 balls at a full-HP Caterpie)
    local r = M.fighter.fight({say = say, menuOpen = true, catch = true, regular = notShiny})
    local last = M.fighter.lastCatch or {}
    if r == "noballs" then tell_result(species, level, not notShiny, "noballs", last.balls); return "shiny" end
    if r == "stuck" then tell_result(species, level, not notShiny, "stuck", last.balls); return "battle" end
    local after = opts.count_owned and opts.count_owned()
    local caught = before and after and after > before
    tell_result(species, level, not notShiny,
        caught and "caught" or r == "lost" and "lost" or last.endHp == 0 and "fainted" or "fled", last.balls)
    local what = notShiny and "" or "shiny "
    if caught then
        say(string.format("Caught the %s%s!", what, name))
    elseif r == "lost" then
        say(string.format("Lost the battle against the %s%s.", what, name))
    else
        say(string.format("The %s%s got away (or fainted) - not caught.", what, name))
    end
    if notShiny then
        if opts.on_caught then opts.on_caught(species, level, caught) end
    elseif opts.on_shiny then opts.on_shiny(species, level, caught) end
    if r == "lost" and State.where().map ~= mapBefore then return "whiteout" end
    return nil
end

-- Whatever stops walking: returns nil to go on, or a reason to stop.
-- opts.script(): runs a script (cutscene, someone talking) to its end -
-- the story's driver, which answers its questions; without it, its text is
-- moved on with B (which says NO to any question).
-- After each battle, standing still: 1-M.JITTER random frames (1.2's Wild
-- mode does the same, data/rng_enabler.lua) - so the walking, as regular
-- as it is, doesn't fall into step with the RNG from one encounter to the
-- next.
M.JITTER = 64
local function jitter()
    if M.JITTER and M.JITTER > 0 then pcall(require("data.rng_enabler").enable_randomness, M.JITTER) end
end

local interruptions_inner
local function interruptions(opts)
    local battle = State.in_battle()
    local stop = interruptions_inner(opts)
    if battle and not State.in_battle() and stop == nil then jitter() end
    return stop
end

interruptions_inner = function(opts)
    for _ = 1, 10 do
        if State.in_battle() then
            local mode = State.read8(State.ADDR.battleMode)
            if mode == 2 and not M.fighter then return "trainer" end
            local fight = mode == 2
            local wild = mode ~= 2
            if not fight and opts.fight_wild and M.fighter then
                -- (a wild one to fight - after the shiny check, which needs
                -- the battle menu up: the DVs are in by then - and only if
                -- the old Kill mode's rules say so: fighter.wild_verdict)
                local r = run_from_wild(true)
                if r == "shiny" then
                    local stop = handle_shiny(opts)
                    if stop then return stop end
                    r = "over"
                end
                if r == "menu" and M.wanted_catch(opts) then
                    -- (training while hunting - but this is one we're after: catch it, don't fight it)
                    local stop = handle_shiny(opts, true)
                    if stop then return stop end
                    r = "over"
                end
                if r == "menu" then
                    local party, active = M.fighter.party_mons()
                    local ok, why, kind = M.fighter.wild_verdict(party[active + 1], M.fighter.battle_mon(ENEMY_SPECIES), State.read8(0xC6F5))
                    -- (switch-training: the trainee needn't win it - a teammate
                    -- comes in; but not against a poisoner/sleeper/paralyzer:
                    -- the one coming in takes its free hit)
                    -- (training someone - opts.trainee its fingerprint - but
                    -- someone else is in front: no fight for nothing - the
                    -- user's Lv 17 Totodile, after a Center put it first)
                    local lead = party[active + 1]
                    if type(opts.trainee) == "string" and lead and lead.fp ~= opts.trainee then
                        ok, kind = false, "lead"
                        why = (M.fighter.species_name(lead.species) or "?") .. " is in front, not the one in training"
                    end
                    if ok or (opts.trainee and kind ~= "status" and kind ~= "lead") then
                        fight = true
                    else
                        ;(opts.say or log)(string.format("Not fighting the wild %s (Lv %d): %s - running.",
                            M.fighter.species_name(State.read8(ENEMY_SPECIES)), State.read8(ENEMY_LEVEL), why))
                        local r2 = run_from_wild(false, true)
                        if r2 == "stuck" then return "battle" end
                    end
                end
            end
            if fight then
                local mapBefore = State.where().map
                local r, why = M.fighter.fight({say = opts.say or log, menuOpen = wild, wild = wild, trainee = wild and opts.trainee})
                if r == "flee" then
                    ;(opts.say or log)("Running: " .. tostring(why) .. ".")
                    local r2 = run_from_wild(false, true)
                    if r2 == "stuck" then return "battle" end
                    if opts.on_battle_over then opts.on_battle_over(State.read8(ENEMY_SPECIES), State.read8(ENEMY_LEVEL)) end
                    r = "fled"
                end
                if r == "lost" then
                    -- A battle the story lets you lose (the rival's in
                    -- Cherrygrove) goes on where it was; a real loss whites
                    -- out - to the last Pokemon Center.
                    local changed = false
                    for _ = 1, 600 do
                        if State.where().map ~= mapBefore then changed = true; break end
                        if ButtonWait.waiting() then ButtonWait.advance(press, "A") else emu.frameadvance() end
                    end
                    if changed then return "whiteout" end
                    ;(opts.say or log)("Lost - but this is a battle the story lets you lose. Going on.")
                end
                if r == "stuck" then return "battle" end
                if r ~= "fled" and opts.on_fight_over then opts.on_fight_over(mode == 2) end
            elseif State.in_battle() then
                local r = run_from_wild(opts.catch_species ~= nil)
                if r == "menu" then
                    -- (one we're after - opts.catch_species - and not got yet: catch it)
                    if M.wanted_catch(opts) then
                        local stop = handle_shiny(opts, true)
                        if stop then return stop end
                        r = "shiny done"
                    else
                        r = run_from_wild(false, true)
                    end
                end
                if r == "shiny" then
                    local stop = handle_shiny(opts)
                    if stop then return stop end
                    r = "shiny done"
                end
                if r == "stuck" then return "battle" end
                -- (species and level stay in wEnemyMon after the battle)
                if r ~= "shiny done" and opts.on_battle_over then opts.on_battle_over(State.read8(ENEMY_SPECIES), State.read8(ENEMY_LEVEL)) end
            end
        elseif State.script_running() then
            if opts.script then opts.script() else sit_out_script() end
        else
            return nil
        end
    end
    return State.in_battle() and "battle" or nil
end
M.interruptions = interruptions

-- Turn to face a way without stepping: a one-frame tap from standing
-- turns (held any longer, the game may turn and then step).
function M.face(dir)
    for _ = 1, 4 do
        if State.facing() == dir then return true end
        joypad.set({[dir] = true}); emu.frameadvance()
        joypad.set({})
        frames(8)
    end
    return State.facing() == dir
end

-- One move of a plan. Returns "ok", "elsewhere" (moved, but not where the
-- plan said), "blocked" (didn't move), or "interrupted".
--
-- Walking on without a stop, like a player holding the pad: the game reads
-- the pad only between steps (on the frame after one ends - wX/YCoord
-- change as it ends) and ignores it mid-step. So once a step is under way
-- the walker already holds the NEXT move's way (a turn pressed a moment
-- early), and when it lands it's straight on to that move - no letting go,
-- no standing still on every tile. It stops only before a warp's fade or a
-- forced step, or at the end.
local CHAINS = {step = true, jump = true}   -- (a step across a map connection is a "step" too)
-- nextMv: the plan's next move (nil if this one leaves the map); more:
-- whether any walking follows at all (across an edge, the new map's plan).
local function do_move(mv, nextMv, more)
    local before = State.where()
    local warp = mv.kind == "warp" or mv.kind == "carpet"
    local chain = CHAINS[mv.kind] and more
    local ahead = chain and nextMv and nextMv.dir or nil
    -- Hold the way until the step starts (a first tap may only turn us).
    local held, started = 0, false
    while held < 40 do
        if State.in_battle() or State.script_running() then joypad.set({}); return "interrupted" end
        joypad.set({[mv.dir] = true})
        emu.frameadvance()
        held = held + 1
        local w = State.where()
        if State.moving() or w.map ~= before.map or w.x ~= before.x or w.y ~= before.y then started = true; break end
    end
    if not started then joypad.set({}); return "blocked" end
    -- Let the step (or jump, or warp - and the step out of the door after
    -- it, which the game takes for you) finish: on the planned tile (and,
    -- unless we walk straight on, standing still there), or still for a
    -- good while somewhere else.
    local n, still, committed = 0, 0, false
    local pushed = warp or mv.kind == "pushed"
    while n < (pushed and 400 or 120) do
        -- (the next way only once a real step is under way - held through
        -- a bump, it would step off from the wrong tile)
        committed = committed or State.stepping()
        if ahead and committed then joypad.set({[ahead] = true}) end
        emu.frameadvance()
        n = n + 1
        if State.in_battle() then return "interrupted" end
        -- (a phone call or someone stopping you as the step ends: not a
        -- bump - sit it out and go on, rather than walk round this tile)
        if not pushed and State.script_running() then joypad.set({}); return "interrupted" end
        local w = State.where()
        local arrived = w.map == mv.map and w.x == mv.x and w.y == mv.y
        if arrived and chain then break end
        local settled = not State.moving() and (not warp or w.map ~= before.map)
        still = settled and still + 1 or 0
        if arrived and still >= 3 then break end
        if not arrived and still >= (pushed and 90 or 20) then break end
    end
    M.stepsTaken = M.stepsTaken + (mv.kind == "jump" and 2 or 1)
    local w = State.where()
    if w.map == mv.map and w.x == mv.x and w.y == mv.y then return "ok" end
    if w.map == before.map and w.x == before.x and w.y == before.y then return "blocked" end
    return "elsewhere"
end

local function at_goal(goal, w)
    if w.map ~= goal.map then return false end
    for _, t in ipairs(goal.tiles or {{goal.x, goal.y, goal.face}}) do
        if t[1] == w.x and t[2] == w.y then return true, t[3] end
    end
    return false
end

-- ------------------------------------------------------------ healing

-- The Pokemon Center cheapest to walk to from start ({map, x, y, face}),
-- of the four fewest maps away: {key, nurse = {x, y}, steps, cost}, or nil.
-- skip[key]: leave that one out.
function M.nearest_center(start, flag, skip)
    local dist, centers = World.map_distances(start.map), {}
    for key, m in pairs(World.data.maps) do
        if m.name:match("Pokecenter1F$") and dist[key] and not (skip and skip[key]) then centers[#centers + 1] = key end
    end
    table.sort(centers, function(a, b) return dist[a] < dist[b] end)
    local best
    for i = 1, math.min(4, #centers) do
        local key = centers[i]
        for _, o in ipairs(World.data.maps[key].objs) do
            if o[3] == "NURSE" then
                local spots = World.talk_spots(key, o[1], o[2])
                local path, cost = World.route(start, {map = key, tiles = spots}, {flag = flag, slack = 1, limit = 60000})
                if path and (not best or cost < best.cost) then best = {key = key, nurse = {o[1], o[2]}, cost = cost, steps = #path} end
            end
        end
    end
    return best
end

function M.center_name(key)
    local n = World.map(key).name:gsub("Pokecenter1F$", "")
    return n .. " Pokemon Center"
end

-- Standing at the counter facing the nurse: talk, A at the text, YES (the
-- default) at "Shall we heal...?", through the healing and the goodbye,
-- until her script is over.
-- (the A that should start her script can be lost - the user's log,
-- 2026-11-09: in the Violet Center the "talk" was over in a second, nothing
-- healed, and the poisoned Totodile fainted on the way to the Mart: up to
-- NURSE_TRIES presses until her script runs)
M.NURSE_TRIES = 3
function M.talk_to_nurse()
    for _ = 1, M.NURSE_TRIES do
        press("A")
        local n, idle, started = 0, 0, false
        while n < 1800 do
            local running = State.script_running()
            if running then started = true end
            if not running and n > 30 then break end
            if ButtonWait.waiting() then
                press("A"); idle = 0; n = n + 5
            else
                emu.frameadvance(); n = n + 1; idle = idle + 1
                if idle >= 40 then press("A"); idle = 0 end   -- the YES/NO box: YES is already picked
            end
        end
        if started then break end
        frames(20)
    end
    frames(20)
    local hp = State.party_hp()
    return hp ~= nil and hp >= 0.999
end

local SERIOUS = {shiny = true, whiteout = true, data = true, battle = true, trainer = true}

-- After a heal: the Mart in the same town, if there is one and the bag
-- wants something (data/mart.lua's rules). nil, or why the walk must stop.
local function shop_after(c, opts, say)
    if not M.mart then return nil end
    local town = World.map(c.key).name:gsub("Pokecenter1F$", "")
    local mk = World.key_of(town .. "Mart")
    if not mk then return nil end
    local want = M.mart.wants()
    if not want then return nil end
    local clerk = nil
    for _, o in ipairs(World.map(mk).objs) do if o[3] == "CLERK" and not clerk then clerk = o end end
    if not clerk then return nil end
    say(string.format("Shopping at the %s Mart: %s.", town, M.mart.describe(want)))
    M.healing = true
    local ok, why = M.go_talk(mk, clerk[1], clerk[2], opts)
    if ok then M.mart.buy({say = say}) end
    M.healing = false
    if not ok then
        if SERIOUS[why] then return why end
        say(string.format("(Couldn't get to the Mart: %s - walking on.)", tostring(why)))
    end
    return nil
end

-- Walk to Center c, heal (and shop), and return nil (go on) or why the
-- walk must stop.
local function heal_at(c, hpState, opts, say)
    -- (a side trip: the walk's own done-check doesn't end it - the user's
    -- log, 2026-11-09: Abe beaten, the walk to the Violet Center ended at
    -- once and the nurse was "talked to" from the gym)
    if opts and opts.done then
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.done = nil
        opts = o
    end
    M.healing = true
    local ok, why = M.go_talk(c.key, c.nurse[1], c.nurse[2], opts)
    local healed = ok and M.talk_to_nurse()
    -- (not healed: once more before writing this Center off - else the
    -- next one is towns away: Violet -> Cherrygrove, the user's log,
    -- 2026-11-09)
    if ok and not healed then
        ok, why = M.go_talk(c.key, c.nurse[1], c.nurse[2], opts)
        healed = ok and M.talk_to_nurse()
    end
    M.healing = false
    if ok then
        say(healed and "Healed at the counter." or "Talked to the nurse, but the party isn't at full HP.")
        if not healed then hpState.skip = hpState.skip or {}; hpState.skip[c.key] = true end
        local stop = shop_after(c, opts, say)
        if stop then return stop end
        if M.teamer then
            M.healing = true
            stop = M.teamer.manage(c.key, opts)
            M.healing = false
            if stop then return stop end
        end
        return nil
    end
    if SERIOUS[why] then return why end
    say(string.format("(Couldn't get to the %s: %s - walking on.)", M.center_name(c.key), tostring(why)))
    hpState.skip = hpState.skip or {}
    hpState.skip[c.key] = true
    return nil
end
M.heal_at = heal_at       -- (data/joey.lua: a trip to buy balls)

-- Every party member but the lead (index i) that isn't fainted or an egg has
-- at least M.HEALTHY of its HP - and there's at least one.
function M.others_healthy(party, i)
    local n = 0
    for k, m in ipairs(party) do
        if k ~= i and not m.egg and m.hp > 0 then
            if m.hp < M.HEALTHY * m.maxhp then return false end
            n = n + 1
        end
    end
    return n > 0
end

-- After each battle (every plan, in fact): is the lead under M.LOW_HP, or
-- anyone poisoned (asleep, burned...)? Then, in this order:
--   * before the first badge: the nearest Center, wherever we are;
--   * in a cave with the others healthy: a low lead fights on (a status
--     still counts);
--   * a Center within M.CENTER_NEAR steps: go there - it heals both. A
--     poisoned one that wouldn't make it (1 HP every 4 steps) gets its
--     Antidote first;
--   * no Center in reach: the bag - cures, potions;
--   * still low or still poisoned: the nearest Center, however far.
-- nil to go on, or why the walk must stop.
-- Whether the wild one in battle is one to catch though not shiny:
-- opts.catch_species[species] is true, or a function of its level (the
-- hunt's second catcher: only levels that would do the job).
function M.wanted_catch(opts)
    local w = opts.catch_species and opts.catch_species[State.read8(ENEMY_SPECIES)]
    if type(w) == "function" then return w(State.read8(ENEMY_LEVEL)) and true or false end
    return w and true or false
end

local function look_after_party(hpState, opts, say, flag)
    local party = M.bag.party()
    local i = M.bag.lead(party)
    if not i then return nil end
    local m = party[i]
    local low = m.maxhp > 0 and m.hp < M.LOW_HP * m.maxhp
    local sick, poisoned, sig = {}, {}, ""
    for k, p in ipairs(party) do
        if not p.egg and p.hp > 0 and p.status ~= 0 then
            sick[#sick + 1] = k
            sig = sig .. k .. ":" .. p.status .. " "
            if p.status & 0x08 ~= 0 then poisoned[k] = p end
        end
    end
    -- (out of PP: a Center refills it - nobody with an attack left, or the
    -- catcher with no sleep move left; the user's log, 2026-11-08: it ran
    -- from everything for an hour)
    local ppWhy, nearOnly = nil, false
    if M.fighter and M.fighter.pp_trouble then ppWhy, nearOnly = M.fighter.pp_trouble() end
    if ppWhy and hpState.ppTried ~= ppWhy then
        hpState.ppTried = ppWhy
        local w0 = State.where()
        local c0 = M.nearest_center({map = w0.map, x = w0.x, y = w0.y, face = State.facing()}, flag, hpState.skip)
        -- (half PP: only a Center nearby; out of attacks: however far)
        if c0 and nearOnly and c0.steps > M.CENTER_NEAR then c0 = nil end
        if c0 then
            say(string.format("%s - the %s refills it (%d steps).", ppWhy:gsub("^%l", string.upper), M.center_name(c0.key), c0.steps))
            local stop = heal_at(c0, hpState, opts, say)
            if stop then return stop end
            party = M.bag.party()
            i = M.bag.lead(party)
            if not i then return nil end
            m = party[i]
            low = m.maxhp > 0 and m.hp < M.LOW_HP * m.maxhp
        end
    elseif not ppWhy then
        hpState.ppTried = nil
    end
    -- (one fainted: a Center, the nearest however far - unless 2 of the
    -- core are over 70% (the user, 2026-11-09: "this can cause useless
    -- interactions"). The user's log that day: Totodile fainted to a Sage,
    -- the standing Caterpie was "the lead" and over 30%, and it went on to
    -- Elder Li with only a Lv 6 Caterpie - whited out.)
    local down = {}
    for _, p in ipairs(party) do
        if not p.egg and p.maxhp > 0 and p.hp == 0 then down[#down + 1] = M.bag.name_of(p.species) end
    end
    local coreFit = 0
    if #down > 0 then
        local core = M.core_slots and M.core_slots(party) or nil
        for k, p in ipairs(party) do
            if not p.egg and (core == nil or core[k]) and p.maxhp > 0 and p.hp > M.CORE_HP * p.maxhp then coreFit = coreFit + 1 end
        end
    end
    if #down > 0 and coreFit < M.CORE_NEEDED then
        local fstate = "fainted:" .. table.concat(down, ",")
        if hpState.said ~= fstate then
            local w = State.where()
            local c = M.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, flag, hpState.skip)
            if c then
                hpState.said = fstate
                say(string.format("%s fainted and only %d of the team's core %s over %d%% HP - the %s is %d steps away: going to heal there.",
                    table.concat(down, " and "), coreFit, coreFit == 1 and "is" or "are", math.floor(M.CORE_HP * 100 + 0.5), M.center_name(c.key), c.steps))
                local stop = heal_at(c, hpState, opts, say)
                if stop then return stop end
                party = M.bag.party()
                i = M.bag.lead(party)
                if not i then return nil end
                m = party[i]
                low = m.maxhp > 0 and m.hp < M.LOW_HP * m.maxhp
                sick, poisoned, sig = {}, {}, ""
                for k, p in ipairs(party) do
                    if not p.egg and p.hp > 0 and p.status ~= 0 then
                        sick[#sick + 1] = k
                        sig = sig .. k .. ":" .. p.status .. " "
                        if p.status & 0x08 ~= 0 then poisoned[k] = p end
                    end
                end
            end
        end
    end
    -- (the switch-training partner low)
    local pk = opts.trainee and M.partner_slot and M.partner_slot() or nil
    local pm = pk and pk ~= i and party[pk] or nil
    if pm and not pm.egg and pm.hp > 0 and pm.maxhp > 0 and pm.hp < M.LOW_HP * pm.maxhp then
        local pstate = "partner:" .. pk .. ":" .. pm.hp
        if hpState.said ~= pstate then
            hpState.said = pstate
            local pw = State.where()
            local pc = M.nearest_center({map = pw.map, x = pw.x, y = pw.y, face = State.facing()}, flag, hpState.skip)
            local pwho = string.format("%s, who comes in to finish the training fights, is down to %d%% HP", M.bag.name_of(pm.species), math.floor(100 * pm.hp / pm.maxhp))
            if pc and ((M.CENTER_BEFORE_BADGE and State.badges() == 0) or pc.steps <= M.CENTER_NEAR) then
                say(string.format("%s - the %s is %d steps away: going to heal there.", pwho, M.center_name(pc.key), pc.steps))
                local stop = heal_at(pc, hpState, opts, say)
                if stop then return stop end
            elseif M.bag.has_heals() then
                say(pwho .. " - using a potion.")
                M.bag.heal_lead(0.8, {say = say, slot = pk})
            elseif pc then
                say(string.format("%s and no potions - walking to the %s (%d steps).", pwho, M.center_name(pc.key), pc.steps))
                local stop = heal_at(pc, hpState, opts, say)
                if stop then return stop end
            end
            party = M.bag.party()
            i = M.bag.lead(party)
            if not i then return nil end
            m = party[i]
            low = m.maxhp > 0 and m.hp < M.LOW_HP * m.maxhp
        end
    end
    if not low and #sick == 0 then hpState.said = nil; return nil end
    -- (the healer first: free, here and now - a Center only if it can't)
    if low and M.field_heal and (M.field_heal(1, {say = say}) or 0) > 0 then
        party = M.bag.party()
        i = M.bag.lead(party)
        if not i then return nil end
        m = party[i]
        low = m.maxhp > 0 and m.hp < M.LOW_HP * m.maxhp
        if not low then say(M.bag.name_of(m.species) .. " is topped up by the team's healer - no Center needed.") end
        if not low and #sick == 0 then hpState.said = nil; return nil end
    end
    local state = (low and ("low" .. i) or "") .. "|" .. sig
    if hpState.said == "done:" .. state then return nil end    -- (did all there is, nothing's changed)
    local w = State.where()
    local always = M.CENTER_BEFORE_BADGE and State.badges() == 0
    local env = World.map(w.map) and World.map(w.map).env
    local what = {}
    if low then what[1] = string.format("%s is down to %d%% HP", M.bag.name_of(m.species), math.floor(100 * m.hp / m.maxhp)) end
    for _, k in ipairs(sick) do
        what[#what + 1] = string.format("%s is %s", M.bag.name_of(party[k].species), M.bag.status_name(party[k].status))
    end
    if low and not always and (env == "CAVE" or env == "DUNGEON") and M.others_healthy(party, i) then
        if hpState.cave ~= i then
            say(what[1] .. ", but we're in a cave and the others are healthy - fighting on.")
            hpState.cave = i
        end
        low = false
        table.remove(what, 1)
        if #sick == 0 then return nil end
    end
    local who = table.concat(what, ", ")
    local here = {map = w.map, x = w.x, y = w.y, face = State.facing()}
    local c = M.nearest_center(here, flag, hpState.skip)
    if c and (always or c.steps <= M.CENTER_NEAR) then
        -- (poison costs 1 HP every 4 steps out here - one that wouldn't
        -- make it gets its cure now)
        local danger, any = {}, false
        for k, p in pairs(poisoned) do
            if p.hp * 4 <= c.steps + 8 and not (M.spare_slot and M.spare_slot(k)) then danger[k] = true; any = true end
        end
        if any then M.bag.cure_party({say = say, only = danger}) end
        say(string.format("%s - the %s is %d steps away: going to heal there.", who, M.center_name(c.key), c.steps))
        return heal_at(c, hpState, opts, say)
    end
    -- No Center in reach: the bag.
    local far = c and string.format(" (the nearest Center is %d steps)", c.steps) or ""
    if #sick > 0 then
        say(who .. far .. " - using the bag.")
        M.bag.cure_party({say = say})
    end
    if low and M.bag.has_heals() then
        if #sick == 0 then say(who .. far .. " - using a potion.") end
        local _, ok = M.bag.heal_lead(M.LOW_HP, {say = say})
        if ok then low = false end
    end
    local stillPoisoned = false
    for _, p in ipairs(M.bag.party()) do
        if not p.egg and p.hp > 0 and p.status & 0x08 ~= 0 then stillPoisoned = true end
    end
    if (low or stillPoisoned) and c then
        say(string.format("%s - walking to the %s (%d steps).", low and "Still low and no potions left" or "Still poisoned, no Antidote",
            M.center_name(c.key), c.steps))
        return heal_at(c, hpState, opts, say)
    end
    if low or stillPoisoned then say("No Pokemon Center I can walk to - going on.") end
    -- (all done that can be: not again until something changes)
    party = M.bag.party()
    i = M.bag.lead(party)
    local after = ""
    for k, p in ipairs(party) do
        if not p.egg and p.hp > 0 and p.status ~= 0 then after = after .. k .. ":" .. p.status .. " " end
    end
    local lowNow = i and party[i].hp < M.LOW_HP * party[i].maxhp
    hpState.said = "done:" .. ((lowNow and ("low" .. i)) or "") .. "|" .. after
    return nil
end

-- Walk to goal: {map, x, y, face} or {map, tiles = {{x, y, face}, ...}}.
-- opts: flags (world_data.flags, for which people are shown / trainers
-- beaten - read live), surf, trainers (walk through their sight),
-- on_battle_over(species, level) after running from a wild one,
-- on_map(key) on arriving in each map (after its data check), say(text)
-- for the log/overlay, max_plans.
-- opts.fight_wild: fight wild battles too (testing the fighter) - a shiny
-- still stops it. on_fight_over(wasTrainer) after a battle fought and won.
-- Returns true, or false and why ("shiny", "trainer", "whiteout", "battle", "data",
-- "no route: ...", "stuck").
function M.go(goal, opts)
    opts = opts or {}
    local say = opts.say or log
    local flag = State.flag_checker(opts.flags or World.data.flags)
    local avoid = {}            -- tiles that bumped us lately: {[map] = {["x,y"] = plans left}}
    local checkedMap = nil
    local hpState = {}          -- look_after_hp's: Centers that didn't work out, said-so's
    for plan = 1, opts.max_plans or 200 do
        -- (the launcher's Stop: between moves - a battle is finished first)
        if M.should_stop and M.should_stop() then return false, "stopped" end
        -- (what the walk was for got done on the way - a trainer who spotted
        -- us and was beaten: the user's log, 2026-11-08, it then waited ~45 s
        -- for a way to talk to Rod in Falkner's gym, already beaten)
        if opts.done and opts.done() then return true end
        -- (between moves, on the map: the launcher's autosave, when it's time)
        if M.on_walk and not State.in_battle() then pcall(M.on_walk) end
        local where0 = State.where()
        local stop = interruptions(opts)
        if stop == "trainer" then
            say("Trainer battle at " .. where0.map .. " " .. where0.x .. "," .. where0.y .. ". Last moves: " .. M.trail_text())
            local near = M.trainers_near(where0.map, where0.x, where0.y, flag)
            say(#near > 0 and ("Trainers in line with that tile: " .. table.concat(near, "; ")) or "No trainer in the data is in line with that tile.")
        end
        if stop then return false, stop end
        -- (the lead low on HP, someone poisoned: a Center in reach, else
        -- the bag - not while already on the way to a Center or Mart)
        if M.bag and not M.healing then
            stop = look_after_party(hpState, opts, say, flag)
            if stop then return false, stop end
        end
        local w = State.where()
        local reached, face = at_goal(goal, w)
        if reached then
            if not face then return true end
            M.face(face)
            -- (turning must not have stepped us off the goal - if it did,
            -- walk back and try again)
            if at_goal(goal, State.where()) then return true end
        end
        if checkedMap ~= w.map then
            -- (The game refreshes its copy of the tiles around you as you
            -- move - right after a warp or a forced step it can lag a
            -- moment: look again before calling it wrong.)
            local ok, why = data_matches()
            for _ = 1, 3 do
                if ok then break end
                frames(30)
                w = State.where()
                ok, why = data_matches()
            end
            if not ok then
                say(string.format("Map data doesn't match the game on %s (%s) - stopping.", w.map, why))
                return false, "data"
            end
            checkedMap = w.map
            if opts.on_map then opts.on_map(w.map) end
        end
        -- Where people are now (and tiles that bumped us lately).
        local live = State.people()
        for k, left in pairs(avoid[w.map] or {}) do
            if left > 0 then live[k] = true; avoid[w.map][k] = left - 1 end
        end
        M.plans = M.plans + 1
        -- (goal.pacing: a step of the hunt's loop round the grass - once on
        -- that map, the way that stays in the grass, not out and back in
        -- over a ledge)
        local path, why = World.route({map = w.map, x = w.x, y = w.y, face = State.facing()}, goal, {flag = flag, live = {[w.map] = live}, surf = opts.surf or State.surfing(),
            trainers = opts.trainers, pacing = goal.pacing and w.map == goal.map or nil})
        if not path then
            -- Someone in the only way? Give them a moment.
            if next(live) then
                frames(60)
            else
                return false, "no route: " .. tostring(why)
            end
        else
            -- (a short way on this map - pacing, back to the grass loop - isn't news)
            if plan == 1 and (goal.map ~= w.map or #path > 15) then
                local route = World.describe(path, w.map)
                say(string.format("Walking to %s (%d steps%s).", World.map(goal.map).name, #path, route ~= "" and ": " .. route or ""))
            end
            -- Follow it until the map changes or something unexpected happens.
            local planMap = w.map
            for i, mv in ipairs(path) do
                -- (the next move rides along while it's on this map and plan)
                if M.should_stop and M.should_stop() then return false, "stopped" end
                local nextMv = path[i + 1]
                if mv.map ~= planMap then nextMv = nil end   -- (this move leaves the map: a new plan follows)
                local r = do_move(mv, nextMv, i < #path)
                remember(mv, r)
                if r ~= "ok" and r ~= "interrupted" then
                    local now = State.where()
                    say(string.format("(%s: going %s from %d,%d to %d,%d, I'm at %d,%d - planning again.)", r, mv.dir, w.x, w.y, mv.x, mv.y, now.x, now.y))
                end
                if r == "blocked" then
                    local tx, ty = w.x + World.DIRS[mv.dir].dx, w.y + World.DIRS[mv.dir].dy
                    avoid[w.map] = avoid[w.map] or {}
                    avoid[w.map][tx .. "," .. ty] = 3
                    frames(10)
                    break
                elseif r ~= "ok" then
                    break
                end
                w = State.where()
                if mv.map ~= planMap then break end   -- a new map: plan again with its people
            end
        end
    end
    return false, "stuck"
end

-- Walk up to the person at (x, y) on a map and face them (across a
-- counter if there is one) - then the caller presses A.
function M.go_talk(map, x, y, opts)
    local spots = World.talk_spots(map, x, y)
    if #spots == 0 then return false, "nowhere to talk from" end
    return M.go({map = map, tiles = spots}, opts)
end

return M
