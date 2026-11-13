-- pc_try.lua - tries the PC and party-order driving (data/pc.lua) in the
-- real game, with nothing that sticks: everything it does, it undoes.
--   1. walks to the nearest Pokemon Center's PC (or uses the one you're at);
--   2. deposits your LAST party member, then withdraws it again;
--   3. swaps your first two party members, then swaps them back.
-- Needs at least 2 Pokemon in the party and room for 1 in the current box.
-- Releasing is impossible by design (pc.lua presses A in the
-- WITHDRAW/DEPOSIT submenu only on row 1, and NO to any YES/NO), but a
-- savestate before is still a good idea.
--
-- Crystal (English). Stop the bot first. Lua Console > Open Script > this file.

local print = AutocrystalConsolePrint or print
local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path
for _, name in ipairs({"data.world", "data.game_state", "data.walker", "data.button_wait", "data.pokemon_names", "data.fighter",
    "data.bag", "data.mart", "data.screen", "data.collection", "data.pc"}) do package.loaded[name] = nil end

local Mem = require("data.memory")
local ButtonWait = require("data.button_wait")
local World = require("data.world")
local State = require("data.game_state")
local Walker = require("data.walker")
local Fighter = require("data.fighter")
local Bag = require("data.bag")
local C = require("data.collection")
local PC = require("data.pc")
local okNames, Names = pcall(require, "data.pokemon_names")
if not okNames then Names = {} end

local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
if version ~= 0x54 or region == 0x4A or region == 0x4B then print("pc_try: Crystal (English) only."); return end
Mem.SetRomBankAddress("Crystal")
ButtonWait.setup(version, region)
ButtonWait.register(Mem)
World.load(dofile(script_dir .. "data/world_data.lua"))
local D = dofile(script_dir .. "data/battle_data.lua")
require("data.screen").setup(State, Mem, D.charmap)
Fighter.setup(D, State, ButtonWait, Mem, Names, print)
Bag.setup(D, State, ButtonWait, Mem, Names, print)
Walker.setup(World, State, ButtonWait, Mem, print, Fighter, Bag)
C.setup(State, D.charmap)
PC.setup(State, ButtonWait, Mem, Names, print)

local function say(s) print(os.date("%H:%M:%S ") .. s) end
local function party_text()
    local t = {}
    for _, m in ipairs(C.party()) do t[#t + 1] = (m.shiny and "*" or "") .. (Names[m.species] or "#" .. m.species) end
    return table.concat(t, ", ")
end
if not C.readSram then say("No save-RAM memory domain in this BizHawk core - stopping."); return end
local party = C.party()
if #party < 2 then say("Needs at least 2 Pokemon in the party."); return end
local box = C.box(C.current_box())
if not box then say("The current box doesn't read right (a new game before the first save?) - stopping."); return end
if #box >= 20 then say("The current box is full - no room to deposit. Stopping."); return end
say(string.format("pc_try: party %s; box %d has %d.", party_text(), C.current_box(), #box))

-- 1. To the PC: the tile with the PC's collision, in this or the nearest Center.
local w = State.where()
local key = w.map
if not World.map(key).name:match("Pokecenter1F$") then
    local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, State.flag_checker(World.data.flags))
    if not c then say("No Pokemon Center I can walk to."); return end
    key = c.key
end
local m = World.map(key)
local spots = {}
for y = 0, m.h * 2 - 1 do for x = 0, m.w * 2 - 1 do
    if World.coll(key, x, y) == PC.PC_TILE then for _, s in ipairs(World.talk_spots(key, x, y)) do spots[#spots + 1] = s end end
end end
if #spots == 0 then say("No PC tile in " .. m.name); return end
say("Walking to the PC in " .. m.name .. ".")
local ok, why = Walker.go({map = key, tiles = spots}, {say = say})
if not ok then say("Couldn't get there: " .. tostring(why)); return end

-- 2. Deposit the last party member, then withdraw it again.
local last = party[#party]
local fp = PC.fingerprint(last)
local nm = Names[last.species] or "it"
say("Depositing " .. nm .. ".")
local n = PC.use_pc({{op = "deposit", fp = fp, name = nm}}, {say = say})
say(string.format("Deposit: %s. Party now: %s.", n == 1 and "done" or "NOT done", party_text()))
if n == 1 then
    for _ = 1, 30 do emu.frameadvance() end
    say("Withdrawing " .. nm .. " again.")
    n = PC.use_pc({{op = "withdraw", fp = fp, name = nm}}, {say = say})
    say(string.format("Withdraw: %s. Party now: %s.", n == 1 and "done" or "NOT done", party_text()))
end

-- 3. Swap the first two, then back.
party = C.party()
local a, b = PC.fingerprint(party[1]), PC.fingerprint(party[2])
say("Swapping the first two.")
local ok1 = PC.order_party({b, a}, {say = say})
say(string.format("Swap: %s. Party now: %s.", ok1 and "done" or "NOT done", party_text()))
local ok2 = PC.order_party({a, b}, {say = say})
say(string.format("Swap back: %s. Party now: %s.", ok2 and "done" or "NOT done", party_text()))
say("pc_try finished.")
for _ = 1, 2 do joypad.set({}); emu.frameadvance() end
