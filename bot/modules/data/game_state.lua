-- game_state.lua (lives in modules/data/)
-- What the game is up to right now, read from RAM: where the player is and
-- which way they face, whether they're mid-step, in a battle or a script,
-- the story so far (event flags, badges), money, the party's HP, the balls
-- in the bag, the time of day, and where the people on this map stand.
--
-- Crystal (English, 1.0 and 1.1 - same WRAM) only, from pokecrystal11.sym.
-- M.read8 reads a byte at a Game Boy address; a test can swap it for a fake.

local M = {}

-- 0xD000-0xDFFF is the Game Boy Color's switchable WRAM bank, and the game
-- switches it (battles do): read through the plain address and mid-battle
-- you get another bank's bytes (a map "128:0", the wrong DVs). The "WRAM"
-- memory domain is all the banks laid out flat - bank 1, where all of this
-- lives, at 0x1000 - so C000-DFFF are read from there, like the bot does.
local function has_domain(name)
    local ok, list = pcall(memory.getmemorydomainlist)
    if not ok then return false end
    if type(list) == "string" then
        for line in list:gmatch("[^\r\n]+") do if line == name then return true end end
    elseif type(list) == "table" then
        for _, d in pairs(list) do if d == name then return true end end
    end
    return false
end
if memory then
    local wram = has_domain("WRAM")
    local bus = has_domain("System Bus") and "System Bus" or nil
    M.read8 = function(a)
        if wram and a >= 0xC000 and a < 0xE000 then return memory.readbyte(a - 0xC000, "WRAM") end
        return memory.readbyte(a, bus)
    end
    M.write8 = function(a, v)
        if wram and a >= 0xC000 and a < 0xE000 then return memory.writebyte(a - 0xC000, v, "WRAM") end
        return memory.writebyte(a, v, bus)
    end
end

local A = {
    mapGroup = 0xDCB5, mapNumber = 0xDCB6, y = 0xDCB7, x = 0xDCB8,
    playerStruct = 0xD4D6,       -- object struct 0 (OBJECT_LENGTH 0x28 each, 13 of them)
    playerWalking = 0xD4DD,      -- 0xFF standing still; anything else mid-step
    playerDirection = 0xD4DE,    -- 0 down, 4 up, 8 left, 12 right
    playerState = 0xD95D,        -- 0 walking, 1 bike, 2 skating, 4 surfing
    mapObjects = 0xD71E,         -- 16 map objects, 16 bytes each (0 = the player)
    objectMasks = 0xD81E,        -- one per map object: 0 shown, 0xFF hidden
    eventFlags = 0xDA72,
    johtoBadges = 0xD857, kantoBadges = 0xD858,
    money = 0xD84E,              -- 3 bytes, big-endian
    partyCount = 0xDCD7, partyMon1 = 0xDCDF, partyMonLength = 0x30,
    numBalls = 0xD8D7, balls = 0xD8D8,
    timeOfDay = 0xD269,          -- 0 morning, 1 day, 2 night
    battleMode = 0xD22D,         -- 0 none, 1 wild, 2 trainer
    scriptMode = 0xD437,         -- nonzero while any script runs (a phone call too)
    scriptRunning = 0xD438,
    joypadDisable = 0xCFBE,
    hours = 0xFF94, minutes = 0xFF96, day = 0xD4CB,
}
M.ADDR = A

local OBJECT_LENGTH, NUM_OBJECT_STRUCTS = 0x28, 13
local MAPOBJECT_LENGTH, NUM_OBJECTS = 0x10, 16
local FACING = {[0] = "Down", [4] = "Up", [8] = "Left", [12] = "Right"}
M.TIMES = {[0] = "MORN", [1] = "DAY", [2] = "NITE"}

local function r(a) return M.read8(a) end
local function r16(a) return r(a) * 256 + r(a + 1) end   -- big-endian, as the game keeps HP

-- The map ("group:number", as world_data.lua keys them) and the step.
function M.where()
    return {map = r(A.mapGroup) .. ":" .. r(A.mapNumber), x = r(A.x), y = r(A.y)}
end

function M.facing() return FACING[r(A.playerDirection) & 0x0C] end
function M.moving() return r(A.playerWalking) ~= 0xFF end
-- A real step under way (not a bump, not a turn): from its first frame the
-- player's object has the tile it's going to (OBJECT_MAP_X/Y, +0x10/+0x11)
-- apart from the one it left (OBJECT_LAST_MAP_X/Y, +0x12/+0x13) - wX/YCoord
-- only change as the step ends.
function M.stepping()
    local s = A.playerStruct
    return r(s + 0x10) ~= r(s + 0x12) or r(s + 0x11) ~= r(s + 0x13)
end
function M.surfing() local s = r(A.playerState); return s == 4 or s == 8 end
function M.in_battle() return r(A.battleMode) ~= 0 end
function M.script_running() return r(A.scriptMode) ~= 0 or r(A.scriptRunning) ~= 0 end

-- Whether event flag n (world_data.lua's flags table has them by name) is set.
function M.flag(n)
    return (r(A.eventFlags + n // 8) >> (n % 8)) & 1 == 1
end

-- A flag-by-name checker for world.route: flags = world_data.flags.
function M.flag_checker(flags)
    return function(name)
        local n = flags[name]
        return n ~= nil and M.flag(n)
    end
end

function M.badges()
    local b, n = r(A.johtoBadges), 0
    for i = 0, 7 do if (b >> i) & 1 == 1 then n = n + 1 end end
    return n, b
end

function M.money()
    return r(A.money) * 65536 + r(A.money + 1) * 256 + r(A.money + 2)
end

-- The party: {species, level, hp, maxHp} each.
function M.party()
    local out = {}
    local n = r(A.partyCount)
    if n > 6 then n = 0 end
    for i = 0, n - 1 do
        local base = A.partyMon1 + i * A.partyMonLength
        out[#out + 1] = {species = r(base), level = r(base + 0x1F),
            hp = r16(base + 0x22), maxHp = r16(base + 0x24)}
    end
    return out
end

-- Fraction of the party's total HP left, 0 - 1 (nil with no party).
function M.party_hp()
    local hp, max = 0, 0
    for _, p in ipairs(M.party()) do hp = hp + p.hp; max = max + p.maxHp end
    if max == 0 then return nil end
    return hp / max
end

-- Balls in the bag: {[item id] = count}, and the total.
function M.balls()
    local out, total = {}, 0
    local n = r(A.numBalls)
    if n > 12 then n = 0 end
    for i = 0, n - 1 do
        local id, qty = r(A.balls + i * 2), r(A.balls + i * 2 + 1)
        out[id] = (out[id] or 0) + qty
        total = total + qty
    end
    return out, total
end

function M.time_of_day() return M.TIMES[r(A.timeOfDay)] or "NITE" end
function M.clock() return r(A.day), r(A.hours), r(A.minutes) end

-- Where the people and things on this map are right now - the tiles they
-- stand on and the ones they're stepping from - as {["x,y"] = true}, for
-- world.route's `live`. Hidden ones (event flag, time of day) left out.
function M.people()
    local tiles = {}
    local function add(mx, my) tiles[(mx - 4) .. "," .. (my - 4)] = true end
    for i = 1, NUM_OBJECTS - 1 do
        local base = A.mapObjects + i * MAPOBJECT_LENGTH
        local sprite = r(base + 1)
        if sprite ~= 0 and r(A.objectMasks + i) == 0 then
            local struct = r(base)
            if struct ~= 0xFF and struct > 0 and struct < NUM_OBJECT_STRUCTS then
                -- On screen: where its object struct has it, and where it's coming from.
                local s = A.playerStruct + struct * OBJECT_LENGTH
                if r(s) ~= 0 then
                    add(r(s + 0x10), r(s + 0x11))
                    add(r(s + 0x12), r(s + 0x13))
                else
                    add(r(base + 3), r(base + 2))
                end
            else
                add(r(base + 3), r(base + 2))   -- off screen: where the map has it
            end
        end
    end
    return tiles
end

-- Where map object n (1-based, in the map's object_event order - world_data's
-- objs order) is now: x, y, and whether it's shown. On screen, from its
-- object struct (it may have walked); off screen, where the map has it.
function M.object_pos(n)
    local base = A.mapObjects + n * MAPOBJECT_LENGTH
    if r(base + 1) == 0 then return nil end
    local shown = r(A.objectMasks + n) == 0
    local struct = r(base)
    if struct ~= 0xFF and struct > 0 and struct < NUM_OBJECT_STRUCTS then
        local s = A.playerStruct + struct * OBJECT_LENGTH
        if r(s) ~= 0 then return r(s + 0x10) - 4, r(s + 0x11) - 4, shown end
    end
    return r(base + 3) - 4, r(base + 2) - 4, shown
end

-- The party's levels, in order.
function M.levels()
    local out = {}
    for _, p in ipairs(M.party()) do out[#out + 1] = p.level end
    return out
end

-- Everything above in one table, for the log and the overlay.
function M.snapshot()
    local w = M.where()
    local _, balls = M.balls()
    return {map = w.map, x = w.x, y = w.y, facing = M.facing(), money = M.money(), badges = M.badges(),
        balls = balls, hp = M.party_hp(), time = M.time_of_day(), battle = M.in_battle(), script = M.script_running()}
end

return M
