-- walk_test.lua - try the walker (data/walker.lua) in the game.
--
-- HOW TO USE (Crystal, English; stop the bot first - one script at a time):
--   1. Load a save anywhere in the overworld with at least one Pokemon,
--      e.g. on Route 29 or in Cherrygrove. A savestate before is a good idea.
--   2. Lua Console > Open Script > this file.
-- What it does (TEST below):
--   "heal"  - walks to the Pokemon Center it can reach most cheaply, has the
--             nurse heal the party, walks back to where you stood and faces
--             the way you faced.
--   "trip"  - walks to TO_MAP / TO_X / TO_Y (a map name from
--             data/world_data.lua) and back to where you stood: a long
--             test of maps, ledges, caves and running from wild battles.
--             Set for Azalea Town (in front of the Pokemon Center) - from
--             Route 29 that's Routes 30-33, Violet City and Union Cave,
--             about 470 steps there and 445 back.
--   "to"    - walks to TO_MAP / TO_X / TO_Y and stops.
--   "grass" - walks to the nearest tall grass on this map and paces there,
--             FIGHTING the wild Pokemon it meets (data/fighter.lua: best
--             move, best matchup, learns stronger moves, lets evolutions
--             happen) until GRASS_FIGHTS battles are done. A shiny still
--             stops it, untouched.
--   "hp"    - heals a lead under 30% HP the way the walks do after a
--             battle - the Pokemon Center if it's within 150 steps (or any
--             distance before the first badge; then walks back), else potions
--             - and stops; in a cave with the others healthy, nothing. HP_TEST_NO_CENTER =
--             true tries the potions even with a Center close by.
--   "shop"  - walks to the Mart in the town of the nearest Pokemon Center,
--             buys what the bag is short of (data/mart.lua: potions up to
--             5, Antidotes up to 3, Poke Balls with the rest above $500)
--             and walks back. The walks shop like this after every heal.
--   "cure"  - just cures the party's status problems with items from the
--             PACK (data/bag.lua) and stops - the walks do this after
--             every battle too.
-- Trainer battles on any walk are fought too (a loss stops it). After a
-- battle, a poisoned (asleep, burned...) POKéMON gets an ANTIDOTE (the item
-- for it) from the PACK, if there is one; a lead under 30% HP is healed
-- (see "hp").
-- It says what it's doing in the Lua Console. Wild battles on the way: run
-- from - except a shiny, where it stops and pauses the game (yours). A
-- trainer who sees you: fought (see "grass").

local TEST = "trip"
local TO_MAP, TO_X, TO_Y = "AzaleaTown", 15, 10
local GRASS_FIGHTS = 5
local HP_TEST_NO_CENTER = false   -- "hp": true = act as if no Center is close by (potions)

local print = AutocrystalConsolePrint or print
local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path
-- BizHawk keeps required modules between script runs (one Lua state for the
-- console): drop the walker's so a reload always runs the files as they are now.
for _, name in ipairs({"data.world", "data.game_state", "data.walker", "data.button_wait", "data.pokemon_names", "data.fighter", "data.bag", "data.mart", "data.screen"}) do
    package.loaded[name] = nil
end

local Mem = require("data.memory")
local ButtonWait = require("data.button_wait")
local World = require("data.world")
local State = require("data.game_state")
local Walker = require("data.walker")
local Fighter = require("data.fighter")
local Bag = require("data.bag")
local Mart = require("data.mart")
local okNames, Names = pcall(require, "data.pokemon_names")
if not okNames then Names = {} end

local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
if version ~= 0x54 or region == 0x4A or region == 0x4B then
    print("walk_test: this is for Pokemon Crystal (English) only.")
    return
end
Mem.SetRomBankAddress("Crystal")
ButtonWait.setup(version, region)
ButtonWait.register(Mem)
local t0 = os.clock()
World.load(dofile(script_dir .. "data/world_data.lua"))
local battleData = dofile(script_dir .. "data/battle_data.lua")
require("data.screen").setup(State, Mem, battleData.charmap)   -- (what's on screen: menus waiting, YES/NO boxes)
Fighter.setup(battleData, State, ButtonWait, Mem, Names, print)
Bag.setup(battleData, State, ButtonWait, Mem, Names, print)
Mart.setup(battleData, State, ButtonWait, Mem, print)
Walker.setup(World, State, ButtonWait, Mem, print, Fighter, Bag, Mart)
print(string.format("walk_test: world loaded (%d ms), walker build %s.", math.floor((os.clock() - t0) * 1000), tostring(Walker.BUILD)))

local function say(s) print(os.date("%H:%M:%S ") .. s) end
local snap = State.snapshot()
local here = World.map(snap.map)
say(string.format("I'm on %s at %d,%d facing %s. Party HP %s, %d balls, $%d, %d badges, %s.",
    here and here.name or snap.map, snap.x, snap.y, snap.facing or "?",
    snap.hp and (math.floor(snap.hp * 100) .. "%") or "-", snap.balls, snap.money, snap.badges, snap.time))
if not here then say("This map isn't in the data - stopping."); return end

local flags = World.data.flags
local flagOn = State.flag_checker(flags)
-- A check on the event flags (the walker reads trainers' beaten flags from
-- them): the gym leaders' should agree with the badges.
do
    local leaders, beaten, total = 0, 0, 0
    for _, n in ipairs({"FALKNER", "BUGSY", "WHITNEY", "MORTY", "JASMINE", "CHUCK", "PRYCE", "CLAIR"}) do
        if flagOn("EVENT_BEAT_" .. n) then leaders = leaders + 1 end
    end
    for name in pairs(flags) do
        if name:match("^EVENT_BEAT_") then total = total + 1; if flagOn(name) then beaten = beaten + 1 end end
    end
    say(string.format("Flags: %d of 8 Johto gym leaders beaten (badges say %d)%s; %d of %d EVENT_BEAT_ flags set.",
        leaders, snap.badges, leaders == snap.badges and "" or " - MISMATCH, the flag reading is off", beaten, total))
end

-- What the walk says as it goes: each new map, each wild battle run from.
local battles = 0
local fights = 0
local walkOpts = {say = say,
    on_fight_over = function(trainer)
        fights = fights + 1
        local hp = State.party_hp()
        say(string.format("Won the %s battle. Party HP %s.", trainer and "trainer" or "wild", hp and (math.floor(hp * 100) .. "%") or "?"))
    end,
    on_map = function(key) say("Now on " .. World.map(key).name .. ".") end,
    on_battle_over = function(species, level)
        battles = battles + 1
        say(string.format("Ran from a wild %s (Lv %d).", Names[species] or ("#" .. species), level))
    end}
local function summary(what, f0, steps0, plans0)
    say(string.format("%s %d steps, %d plans, %d wild battles run from, %.1f minutes at 1x.", what,
        Walker.stepsTaken - steps0, Walker.plans - plans0, battles, (emu.framecount() - f0) / 59.73 / 60))
end

local function finish(ok, why)
    if ok then return true end
    if why == "shiny" then
        say("A SHINY! Stopped - nothing pressed. It's all yours.")
        client.pause()
    elseif why == "trainer" then
        say("A trainer spotted me - I don't fight yet. Over to you.")
    elseif why == "whiteout" then
        say("Lost the battle - whited out. Stopped.")
    else
        say("Stopped: " .. tostring(why))
    end
    return false
end

if TEST == "heal" then
    local start = {map = snap.map, x = snap.x, y = snap.y, face = snap.facing}
    -- The Pokemon Center that's cheapest to reach from here (of the few
    -- fewest maps away).
    local best = Walker.nearest_center(start, flagOn)
    if not best then say("No Pokemon Center I can walk to from here."); return end
    say(string.format("Nearest: the %s (%d steps).", Walker.center_name(best.key), best.steps))
    local frames0 = emu.framecount()
    if not finish(Walker.go_talk(best.key, best.nurse[1], best.nurse[2], walkOpts)) then return end
    say("At the counter - talking to the nurse.")
    Walker.talk_to_nurse()
    local hp = State.party_hp()
    say(hp and hp >= 0.999 and "Party healed." or string.format("Party HP now %s - did the heal happen?", hp and math.floor(hp * 100) .. "%" or "?"))
    if not finish(Walker.go(start, walkOpts)) then return end
    say(string.format("Back where I started, facing %s. %d steps, %.1f minutes at 1x.",
        State.facing() or "?", Walker.stepsTaken, (emu.framecount() - frames0) / 59.73 / 60))
elseif TEST == "trip" then
    local start = {map = snap.map, x = snap.x, y = snap.y, face = snap.facing}
    local key = World.key_of(TO_MAP)
    if not key then say("No map called " .. TO_MAP); return end
    local f0 = emu.framecount()
    if not finish(Walker.go({map = key, x = TO_X, y = TO_Y}, walkOpts)) then summary("Stopped after", f0, 0, 0); return end
    summary(string.format("Arrived at %s %d,%d:", TO_MAP, TO_X, TO_Y), f0, 0, 0)
    local f1, s1, p1, b1 = emu.framecount(), Walker.stepsTaken, Walker.plans, battles
    battles = 0
    if not finish(Walker.go(start, walkOpts)) then summary("Stopped on the way back after", f1, s1, p1); return end
    summary(string.format("Back where I started, facing %s:", State.facing() or "?"), f1, s1, p1)
    battles = battles + b1
    summary("Whole trip:", f0, 0, 0)
elseif TEST == "grass" then
    -- The nearest tall grass tile (with a grass tile next to it) on this map.
    local key = snap.map
    local m = World.map(key)
    local spots = {}
    for y = 0, m.h * 2 - 1 do
        for x = 0, m.w * 2 - 1 do
            local c = World.coll(key, x, y)
            if c and World.GRASS[c] then
                for _, d in ipairs({{1, 0}, {0, 1}}) do
                    local c2 = World.coll(key, x + d[1], y + d[2])
                    if c2 and World.GRASS[c2] then spots[#spots + 1] = {x, y, x + d[1], y + d[2]} end
                end
            end
        end
    end
    if #spots == 0 then say("No tall grass on this map."); return end
    table.sort(spots, function(a, b)
        return math.abs(a[1] - snap.x) + math.abs(a[2] - snap.y) < math.abs(b[1] - snap.x) + math.abs(b[2] - snap.y)
    end)
    local g = spots[1]
    say(string.format("Pacing in the grass at %d,%d / %d,%d until %d wild battles are fought.", g[1], g[2], g[3], g[4], GRASS_FIGHTS))
    walkOpts.fight_wild = true
    local f0, flip = emu.framecount(), false
    for _ = 1, 400 do
        if fights >= GRASS_FIGHTS then break end
        flip = not flip
        local ok, why = Walker.go({map = key, x = flip and g[1] or g[3], y = flip and g[2] or g[4]}, walkOpts)
        if not ok then finish(false, why); summary("Stopped after", f0, 0, 0); return end
    end
    summary(string.format("Fought %d wild battles:", fights), f0, 0, 0)
elseif TEST == "to" then
    local key = World.key_of(TO_MAP)
    if not key then say("No map called " .. TO_MAP); return end
    local f0 = emu.framecount()
    if finish(Walker.go({map = key, x = TO_X, y = TO_Y}, walkOpts)) then summary("Arrived:", f0, 0, 0) end
elseif TEST == "hp" then
    -- A walk to where I stand: no steps - except that a low lead gets
    -- healed first (the Center if it's close by, else potions), then back.
    if HP_TEST_NO_CENTER then Walker.CENTER_NEAR = 0; Walker.CENTER_BEFORE_BADGE = false end
    local party = Bag.party()
    local i = Bag.lead(party)
    if i then
        local m = party[i]
        say(string.format("Lead: %s, HP %d/%d (%d%%; heals under %d%%).", Names[m.species] or ("#" .. m.species),
            m.hp, m.maxhp, math.floor(100 * m.hp / math.max(1, m.maxhp)), math.floor(Walker.LOW_HP * 100)))
    end
    local f0 = emu.framecount()
    if finish(Walker.go({map = snap.map, x = snap.x, y = snap.y, face = snap.facing}, walkOpts)) then
        summary("Done, back where I started:", f0, 0, 0)
    end
elseif TEST == "shop" then
    local start = {map = snap.map, x = snap.x, y = snap.y, face = snap.facing}
    local want = Mart.wants()
    say(want and ("Short of: " .. Mart.describe(want) .. ".") or "The bag has all it needs (or the money's at $500) - nothing to buy.")
    if not want then return end
    local c = Walker.nearest_center(start, flagOn)
    local town = c and World.map(c.key).name:gsub("Pokecenter1F$", "")
    local mk = town and World.key_of(town .. "Mart")
    if not mk then say("No Mart in the nearest Center's town" .. (town and (" (" .. town .. ")") or "") .. "."); return end
    local clerk
    for _, o in ipairs(World.map(mk).objs) do if o[3] == "CLERK" and not clerk then clerk = o end end
    local f0 = emu.framecount()
    if not finish(Walker.go_talk(mk, clerk[1], clerk[2], walkOpts)) then return end
    Mart.buy({say = say})
    if finish(Walker.go(start, walkOpts)) then summary("Back where I started:", f0, 0, 0) end
elseif TEST == "cure" then
    local party = Bag.party()
    local _, bag = Bag.items()
    for i, m in ipairs(party) do
        local item = Bag.choose(m.status, bag)
        say(string.format("%d. %s: %s%s", i, Names[m.species] or ("#" .. m.species), Bag.status_name(m.status),
            m.status ~= 0 and (item and (" - would use " .. Bag.item_name(item)) or " - nothing in the bag for it") or ""))
    end
    local n = Bag.cure_party({say = say})
    say(string.format("Cured %d.", n))
end
for _ = 1, 2 do joypad.set({}); emu.frameadvance() end
