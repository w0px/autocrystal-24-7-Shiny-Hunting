-- collection.lua (lives in modules/data/)
-- Everything the player owns: the party (WRAM) and the 14 PC boxes (the
-- cartridge's save RAM - BizHawk's "CartRAM" memory domain). For the team
-- planner (data/team.lua): who's where, which are shiny, which is the
-- starter.
--
-- Where things are (pokecrystal11.sym, ram/sram.asm):
--   party:           wPartyCount D:CDD7, species list, 6 x 48-byte party_structs at DCDF
--   the current box: sBox, SRAM bank 1 at $AD10 (the game works on it there)
--   boxes 1-7:       SRAM bank 2 from $A000, 8-14: bank 3 from $A000, $450 bytes each
--                    (the numbered copy of the current box is out of date - it's
--                    written back when you change boxes, which saves the game)
--   wCurBox D:B72    the current box, 0-13
-- A box: count, species list (21), 20 x 32-byte box_structs, OT names (20 x
-- 11), nicknames (20 x 11). A party_struct starts with the same 32 bytes.
-- Each mon's 32 bytes: species 0, item 1, moves 2-5, OT ID 6-7, exp 8-10,
-- stat exp 11-20, DVs 21-22, PP 23-26, happiness 27, pokerus 28, caught
-- data 29-30, level 31.
--
-- M.readSram (an SRAM offset -> byte) and State.read8 can be swapped for
-- fakes in tests.

local M = {}

local State
local charmap = {}

local A = {
    partyCount = 0xDCD7, partySpecies = 0xDCD8, party = 0xDCDF, partyLen = 0x30,
    partyNicknames = 0xDE41,     -- wPartyMonNicknames (6 x 11)
    curBox = 0xDB72, playerId = 0xD47B,
}
local BOX_LENGTH, MONS_PER_BOX, BOXMON = 0x450, 20, 32
local EGG = 0xFD

-- SRAM offset of a box: bank * $2000 + (address - $A000).
local CUR_BOX = 1 * 0x2000 + (0xAD10 - 0xA000)
local function box_offset(n)   -- n = 1..14
    if n <= 7 then return 2 * 0x2000 + (n - 1) * BOX_LENGTH end
    return 3 * 0x2000 + (n - 8) * BOX_LENGTH
end

function M.setup(state, map)
    State = state
    charmap = map or {}
    if memory and not M.readSram then
        -- (the save RAM's domain name depends on BizHawk's Game Boy core)
        local ok, list = pcall(memory.getmemorydomainlist)
        local names = {}
        if ok and type(list) == "table" then for _, d in pairs(list) do names[d] = true end
        elseif ok and type(list) == "string" then for d in list:gmatch("[^\r\n]+") do names[d] = true end end
        for _, d in ipairs({"CartRAM", "Cart RAM", "SRAM", "SaveRAM"}) do
            if names[d] then M.sramDomain = d; break end
        end
        if M.sramDomain then
            M.readSram = function(off) return memory.readbyte(off, M.sramDomain) end
        end
    end
end

-- Shiny by DVs: Defense, Speed and Special 10, Attack 2/3/6/7/10/11/14/15.
function M.shiny(dvAtkDef, dvSpdSpc)
    local atk, def, spd, spc = dvAtkDef >> 4, dvAtkDef & 15, dvSpdSpc >> 4, dvSpdSpc & 15
    return def == 10 and spd == 10 and spc == 10 and (atk & 2) == 2
end

-- One mon from 32 bytes read by rd(i), i = 0..31.
-- The testing switch: every Pokemon counts as shiny (team, goals) - so the
-- whole run can be tested without waiting for shinies. Never on the stream.
M.ALL_SHINY = false

local function mon_from(rd)
    local m = {species = rd(0), item = rd(1), moves = {}, pp = {},
        otId = rd(6) * 256 + rd(7), exp = rd(8) * 65536 + rd(9) * 256 + rd(10),
        dvs = {rd(21), rd(22)}, happiness = rd(27), level = rd(31)}
    -- (Gen 2 has no ID number for a Pokemon - the closest thing is
    -- everything else that can differ: stat EXP and Crystal's caught data
    -- (time, level, place) too - data/pc.lua's ident, for twins: two shinies
    -- of a species share all DVs 1 time in 8)
    local se = {}
    for i = 11, 20 do se[#se + 1] = string.format("%02X", rd(i)) end
    m.statExp = table.concat(se)
    m.caught = rd(29) * 256 + rd(30)
    for i = 0, 3 do
        local mv = rd(2 + i)
        if mv ~= 0 then m.moves[#m.moves + 1] = mv; m.pp[#m.pp + 1] = rd(23 + i) & 0x3F end
    end
    m.shiny = M.shiny(m.dvs[1], m.dvs[2])
    -- (who it is, wherever it sits: species, DVs, trainer ID - as data/pc.lua's fingerprint)
    m.fp = require("data.family").fp(m.species, m.dvs[1], m.dvs[2], m.otId)   -- (the same after evolving)
    if M.ALL_SHINY then m.realShiny, m.shiny = m.shiny, true end   -- (the testing switch)
    return m
end

local function name_from(rd, base)
    local t = {}
    for i = 0, 10 do
        local b = rd(base + i)
        if b == 0x50 then break end
        t[#t + 1] = charmap[b] or "?"
    end
    return table.concat(t)
end

local function valid_species(sp) return sp ~= nil and sp >= 1 and sp <= 251 end

-- The party: {{key = "party:1", slot = 1, species, level, moves, shiny,
-- hp, maxhp, status, egg, nickname, ...}, ...}
function M.party()
    local r = State.read8
    local out = {}
    local n = r(A.partyCount)
    if n > 6 then return out end
    for i = 1, n do
        local base = A.party + (i - 1) * A.partyLen
        local m = mon_from(function(k) return r(base + k) end)
        m.egg = r(A.partySpecies + i - 1) == EGG
        m.status = r(base + 32)
        m.hp = r(base + 34) * 256 + r(base + 35)
        m.maxhp = r(base + 36) * 256 + r(base + 37)
        m.nickname = name_from(r, A.partyNicknames + (i - 1) * 11)
        m.key, m.where, m.slot = "party:" .. i, "party", i
        if valid_species(m.species) then out[#out + 1] = m end
    end
    return out
end

-- Box n (1-14): its mons, or nil and why if it doesn't read right (a new
-- game's boxes before the first save can hold anything).
function M.box(n)
    local cur = State.read8(A.curBox) + 1
    local off = (n == cur) and CUR_BOX or box_offset(n)
    local rs = M.readSram
    local count = rs(off)
    if count > MONS_PER_BOX then return nil, "count " .. count end
    if count > 0 and rs(off + 1 + count) ~= 0xFF then return nil, "species list not ended" end
    local out = {}
    for i = 1, count do
        local sp = rs(off + i)
        local base = off + 1 + MONS_PER_BOX + 1 + (i - 1) * BOXMON
        local m = mon_from(function(k) return rs(base + k) end)
        if sp ~= m.species and sp ~= EGG then return nil, "species list doesn't match slot " .. i end
        m.egg = sp == EGG
        m.nickname = name_from(rs, off + 1 + MONS_PER_BOX + 1 + MONS_PER_BOX * BOXMON + MONS_PER_BOX * 11 + (i - 1) * 11)
        m.key, m.where, m.box, m.slot = "box:" .. n .. ":" .. i, "box", n, i
        if valid_species(m.species) then out[#out + 1] = m end
    end
    return out
end

function M.current_box() return State.read8(A.curBox) + 1 end
function M.player_id() return State.read8(A.playerId) * 256 + State.read8(A.playerId + 1) end

-- Everything owned (party, then boxes 1-14), and a list of boxes that
-- didn't read right.
function M.all()
    local out, bad = {}, {}
    for _, m in ipairs(M.party()) do out[#out + 1] = m end
    for n = 1, 14 do
        local list, why = M.box(n)
        if list then for _, m in ipairs(list) do out[#out + 1] = m end
        else bad[#bad + 1] = n .. " (" .. why .. ")" end
    end
    return out, bad
end

-- For data/team.lua: the owned mons (no eggs), with the starter marked -
-- the first of the starter's line (starterLine = {species ids}) with the
-- player's own trainer ID.
function M.for_team(starterLine)
    local all = M.all()
    local line = {}
    for _, sp in ipairs(starterLine or {}) do line[sp] = true end
    local me = M.player_id()
    local out, starterSet = {}, false
    for _, m in ipairs(all) do
        if not m.egg then
            if not starterSet and line[m.species] and m.otId == me then m.starter = true; starterSet = true end
            out[#out + 1] = m
        end
    end
    return out
end

return M
