-- team_check.lua - shows what the bot sees you own, and the team it would
-- pick (data/collection.lua + data/team.lua). Reads only: presses nothing,
-- changes nothing. For checking the PC-box reading in the real game.
--
-- Crystal (English). Lua Console > Open Script > this file, anywhere in
-- the game. It lists the party and every box (shinies marked *), any box
-- it couldn't read, and the team: catcher, 2 specialists, HM slave,
-- healer - with why.

local print = AutocrystalConsolePrint or print
local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path
for _, name in ipairs({"data.game_state", "data.collection", "data.team", "data.pokemon_names"}) do package.loaded[name] = nil end

local State = require("data.game_state")
local C = require("data.collection")
local T = require("data.team")
local okNames, Names = pcall(require, "data.pokemon_names")
if not okNames then Names = {} end

local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
if version ~= 0x54 or region == 0x4A or region == 0x4B then print("team_check: Crystal (English) only."); return end
local D = dofile(script_dir .. "data/battle_data.lua")
C.setup(State, D.charmap)
T.setup(D, Names)
if not C.readSram then print("team_check: no save-RAM memory domain found in this BizHawk core."); return end
print(string.format("team_check: save RAM domain %s, current box %d, your ID %05d.", C.sramDomain or "?", C.current_box(), C.player_id()))

local function line(m)
    local mv = {}
    for _, id in ipairs(m.moves) do mv[#mv + 1] = D.moves[id] and D.moves[id][1]:lower():gsub("_", " ") or "?" end
    return string.format("%s%s Lv %d%s%s - %s", m.shiny and "*" or " ", Names[m.species] or ("#" .. m.species), m.level,
        m.egg and " (egg)" or "", (m.nickname ~= "" and m.nickname:upper() ~= (Names[m.species] or ""):upper()) and (" \"" .. m.nickname .. "\"") or "",
        table.concat(mv, ", "))
end

local all, bad = C.all()
local lastWhere = nil
local shinies = 0
for _, m in ipairs(all) do
    local where = m.where == "party" and "Party" or ("Box " .. m.box .. (m.box == C.current_box() and " (current)" or ""))
    if where ~= lastWhere then print(where .. ":"); lastWhere = where end
    print("  " .. line(m))
    if m.shiny then shinies = shinies + 1 end
end
if #bad > 0 then print("Boxes that didn't read (empty on a new game until the first save is normal): " .. table.concat(bad, ", ")) end
print(string.format("%d Pokemon, %d shiny.", #all, shinies))

local line_ = {}
for _, n in ipairs({"TOTODILE", "CROCONAW", "FERALIGATR"}) do
    for id, nm in pairs(Names) do if type(id) == "number" and nm:upper() == n then line_[#line_ + 1] = id end end
end
local team = T.pick(C.for_team(line_))
print("The team I'd pick:")
print("  Starter: " .. (team.starter and (Names[team.starter.species] .. " (" .. team.starter.key .. ")") or "none found"))
for _, w in ipairs(team.why) do print("  " .. w) end
local order = T.party_order(team, true)
print("  Hunting party order: " .. table.concat(order, ", "))
