-- walk_loop.lua (lives in data/)
-- Wild mode's walking route: the outer edge of the encounter tiles around
-- where the hunt started, walked as a loop - like a player pacing around a
-- patch of grass, instead of stepping Right/Left on one spot.
--
-- Which tiles can give an encounter is the game's own rule
-- (CanEncounterWildMon, pokecrystal engine/events/...; the same in
-- Gold/Silver):
--   * caves and dungeons (wEnvironment 4 / 7): every tile but ice;
--   * everywhere else: only a tile in CheckGrassCollision's list - tall
--     grass, long grass, and water (surfing).
-- A tile's collision comes from the map the way GetCoordTileCollision /
-- GetBlockLocation work it out: the block under it in wOverworldMapBlocks,
-- then the tileset's collision table in the ROM (4 bytes per block, one per
-- quarter). All of it checked against the ROMs: Crystal 1.1, Gold, Silver.
--
-- The loop only uses tiles of the same kind as the one the player stands on
-- (land or water, CollisionPermissionTable), within RADIUS steps of home,
-- inside the current map (a map connection would change maps), and nothing
-- with a side effect: no doors/stairs/warps, ledges, currents, whirlpools,
-- ice. A cave allows its plain floor (and grass) only.

local M = {}

M.RADIUS = 3 -- up to a 7x7 patch: at most a 24-step loop

-- CheckGrassCollision.blocks (Crystal 05:49EA, Gold/Silver 05:4A68).
M.GRASS = {[0x08] = true, [0x18] = true, [0x14] = true, [0x28] = true, [0x29] = true,
    [0x48] = true, [0x49] = true, [0x4A] = true, [0x4B] = true, [0x4C] = true}
-- CheckIceTile.
M.ICE = {[0x23] = true, [0x2B] = true}
M.CAVE_FLOOR = 0x00

-- CollisionPermissionTable (Crystal 13:4E1F, Gold/Silver 3E:74BE - the
-- same 256 bytes): low nibble 0 = land, 1 = water, F = wall.
-- (one row of 16 per line, as dumped from the ROM)
local ROWS = {
    "00 00 00 00 00 00 00 0f 00 00 00 00 00 00 00 0f",
    "00 00 1f 00 00 1f 00 00 00 00 1f 00 00 1f 00 00",
    "01 01 11 00 11 01 01 0f 01 01 11 00 11 01 01 0f",
    "01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "00 00 0f 00 00 00 00 00 00 00 0f 00 00 00 00 00",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "0f 0f 0f 0f 0f 00 00 00 0f 0f 0f 0f 0f 00 00 00",
    "0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f 0f",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "01 01 01 01 01 01 01 01 01 01 01 01 01 01 01 01",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0f",
}
local PERMISSION = {}
for row, line in ipairs(ROWS) do
    local col = 0
    for h in line:gmatch("%x%x") do
        PERMISSION[(row - 1) * 16 + col] = tonumber(h, 16) % 16
        col = col + 1
    end
end
M.PERMISSION = PERMISSION
local LAND, WATER = 0, 1

-- WRAM addresses (pokecrystal11.sym / pokegold.sym). scriptMode: wScriptMode,
-- set while any script runs - a phone call included (see frame_search.lua).
M.ADDR = {
    crystal = {blocks = 0xC800, mapHeight = 0xD19E, mapWidth = 0xD19F, collBank = 0xD1DF, collAddr = 0xD1E0,
        environment = 0xD19A, standingTile = 0xD4E4, tileDown = 0xC2FA, mapGroup = 0xDCB5, mapNumber = 0xDCB6,
        scriptMode = 0xD437},
    gs = {blocks = 0xC700, mapHeight = 0xD087, mapWidth = 0xD088, collBank = 0xD0C8, collAddr = 0xD0C9,
        environment = 0xD083, standingTile = 0xD20B, tileDown = 0xCEA3, mapGroup = 0xDA00, mapNumber = 0xDA01,
        scriptMode = 0xD15E},
}

local DIRS = {
    {name = "Up", dx = 0, dy = -1},
    {name = "Right", dx = 1, dy = 0},
    {name = "Down", dx = 0, dy = 1},
    {name = "Left", dx = -1, dy = 0},
}
M.DIRS = DIRS
local function key(x, y) return y * 1024 + x end

-- collision(x, y) for step coordinates x, y (wXCoord / wYCoord), or nil
-- outside the loaded blocks. read8(addr) reads WRAM, rom(bank, addr) the ROM.
function M.collision_reader(read8, rom, a)
    local stride = read8(a.mapWidth) + 6
    local rows = read8(a.mapHeight) + 6
    local collBank = read8(a.collBank)
    local collAddr = read8(a.collAddr) + read8(a.collAddr + 1) * 256
    return function(x, y)
        local d, e = x + 4, y + 4
        if d < 0 or e < 0 or d >= stride * 2 or e >= rows * 2 then return nil end
        local block = read8(a.blocks + 1 + stride * (1 + e // 2) + d // 2)
        if block == nil or block == 0 then return nil end
        return rom(collBank, collAddr + block * 4 + (d % 2) + (e % 2) * 2)
    end
end

-- Whether the reader agrees with the game: the tile under the player and
-- its four neighbours (wTileDown, Up, Left, Right) as the game has them.
function M.reader_matches(coll, read8, a, x, y)
    if coll(x, y) ~= read8(a.standingTile) then return false end
    local around = {{0, 1}, {0, -1}, {-1, 0}, {1, 0}}
    for i, o in ipairs(around) do
        if coll(x + o[1], y + o[2]) ~= read8(a.tileDown + i - 1) then return false end
    end
    return true
end

-- An encounter tile of the given kind (LAND / WATER) with no side effects.
function M.loop_tile(c, environment, kind)
    if c == nil or PERMISSION[c] ~= kind then return false end
    if M.ICE[c] then return false end
    if M.GRASS[c] then return true end
    local cave = environment == 4 or environment == 7
    return cave and kind == LAND and c == M.CAVE_FLOOR
end

-- The loop tiles connected to (homeX, homeY), within the radius and the
-- map. Returns a set (key -> true) and its size; size 0 when home isn't one.
function M.region(coll, homeX, homeY, env, mapW, mapH, radius)
    radius = radius or M.RADIUS
    local kind = PERMISSION[coll(homeX, homeY) or -1]
    local set, n = {}, 0
    local function ok(x, y)
        if math.abs(x - homeX) > radius or math.abs(y - homeY) > radius then return false end
        if x < 0 or y < 0 or x >= mapW * 2 or y >= mapH * 2 then return false end
        return M.loop_tile(coll(x, y), env, kind)
    end
    if kind == nil or not ok(homeX, homeY) then return set, 0 end
    local queue, head = {{homeX, homeY}}, 1
    set[key(homeX, homeY)] = true
    n = 1
    while head <= #queue do
        local x, y = queue[head][1], queue[head][2]
        head = head + 1
        for _, d in ipairs(DIRS) do
            local nx, ny = x + d.dx, y + d.dy
            if not set[key(nx, ny)] and ok(nx, ny) then
                set[key(nx, ny)] = true
                n = n + 1
                queue[#queue + 1] = {nx, ny}
            end
        end
    end
    return set, n
end

-- The region's outer edge as a closed walk: start at its top-left tile
-- heading Right and keep the outside on the left (left-hand rule). Returns
-- {x = {...}, y = {...}, dirs = {...}} - tile i, and the step from tile i
-- to tile i + 1 (the last back to the first) - or nil for a single tile.
function M.edge_loop(set)
    local sx, sy
    for k in pairs(set) do
        local x, y = k % 1024, k // 1024
        if sy == nil or y < sy or (y == sy and x < sx) then sx, sy = x, y end
    end
    if sx == nil then return nil end
    local loop = {x = {}, y = {}, dirs = {}}
    local x, y, dir = sx, sy, 2 -- Right: the tile above is outside
    for _ = 1, 4 * 64 do
        local moved = false
        for _, turn in ipairs({-1, 0, 1, 2}) do
            local nd = (dir - 1 + turn) % 4 + 1
            local nx, ny = x + DIRS[nd].dx, y + DIRS[nd].dy
            if set[key(nx, ny)] then
                loop.x[#loop.x + 1], loop.y[#loop.y + 1], loop.dirs[#loop.dirs + 1] = x, y, DIRS[nd].name
                x, y, dir = nx, ny, nd
                moved = true
                break
            end
        end
        if not moved then return nil end -- a single tile
        -- Back on the first tile, about to make the first move again.
        if x == sx and y == sy then
            local nextDir
            for _, turn in ipairs({-1, 0, 1, 2}) do
                local nd = (dir - 1 + turn) % 4 + 1
                if set[key(x + DIRS[nd].dx, y + DIRS[nd].dy)] then nextDir = DIRS[nd].name; break end
            end
            if nextDir == loop.dirs[1] then return loop end
        end
    end
    return nil
end

-- Where (x, y) is on the loop (its first index), or nil.
function M.index_of(loop, x, y)
    for i = 1, #loop.x do
        if loop.x[i] == x and loop.y[i] == y then return i end
    end
    return nil
end

-- Shortest steps inside the region from (x, y) to any loop tile: a list of
-- direction names (empty if already on it), or nil if it can't be reached.
function M.path_to_loop(set, loop, x, y)
    local onLoop = {}
    for i = 1, #loop.x do onLoop[key(loop.x[i], loop.y[i])] = true end
    if onLoop[key(x, y)] then return {} end
    local from = {[key(x, y)] = false}
    local queue, head = {{x, y}}, 1
    while head <= #queue do
        local cx, cy = queue[head][1], queue[head][2]
        head = head + 1
        for _, d in ipairs(DIRS) do
            local nx, ny = cx + d.dx, cy + d.dy
            local k = key(nx, ny)
            if set[k] and from[k] == nil then
                from[k] = {cx, cy, d.name}
                if onLoop[k] then
                    local steps = {}
                    while from[k] do
                        table.insert(steps, 1, from[k][3])
                        k = key(from[k][1], from[k][2])
                    end
                    return steps
                end
                queue[#queue + 1] = {nx, ny}
            end
        end
    end
    return nil
end

-- The playthrough's pacing (dev, 2026-11-08 - the user: "use the walking
-- pattern from 1.2"): the same loop, from the map data (data/world.lua)
-- instead of RAM, so it works for a map before we're on it. pair: the two
-- neighbouring wild tiles the caller found ({x1, y1, x2, y2}) - the first
-- is home. Returns the tiles to walk in order, {{x, y}, ...}: the loop
-- round the edge of the encounter tiles within radius steps of home, or
-- the pair when no loop fits (a 1-tile-wide strip of grass).
function M.world_tiles(World, key, pair, radius, flag)
    local m = World.map(key)
    local env = (m.env == "CAVE" or m.env == "DUNGEON") and 4 or 0
    -- (nobody standing there: a tile someone's on isn't one to walk to)
    local blocked = World.blocked and World.blocked(key, flag) or {}
    local coll = function(x, y) if blocked[x .. "," .. y] then return nil end; return World.coll(key, x, y) end
    local set, n = M.region(coll, pair[1], pair[2], env, m.w, m.h, radius or M.RADIUS)
    local loop = n >= 3 and M.edge_loop(set) or nil
    if loop and #loop.dirs >= 3 then
        local out = {}
        for i = 1, #loop.x do out[i] = {loop.x[i], loop.y[i]} end
        return out, true
    end
    return {{pair[1], pair[2]}, {pair[3], pair[4]}}, false
end

-- The loop's tiles (world_tiles) from where we stand: the next tile round
-- if we're on it, else the nearest - not its top-left corner every re-plan,
-- across the patch (the user's log, 2026-11-09). A new list.
function M.from_here(path, x, y)
    if not x or #path < 2 then return path end
    local start, best = 1, math.huge
    for i, t in ipairs(path) do
        local d = math.abs(t[1] - x) + math.abs(t[2] - y)
        if d == 0 then start = i % #path + 1; break end
        if d < best then start, best = i, d end
    end
    local out = {}
    for i = 0, #path - 1 do out[#out + 1] = path[(start - 1 + i) % #path + 1] end
    return out
end

-- Big patches (the user, 2026-11-09: "with bigger grass tiles it just
-- picks 1 route and does that one forever"): each round a new loop -
-- round a random tile of the patch within WANDER steps of the pair, radius
-- 2 or 3, either way round. Every step is still on grass (the walk there
-- too: Walker.go's goal.pacing), so no encounters are lost. A patch the
-- one loop round the pair already covers keeps it (Route 30's 8 tiles);
-- one with more grass within WANDER wanders (Route 32: 24, the loop 12). Nothing in a
-- cutscene's trigger or an unbeaten trainer's sight (World.avoid).
-- rand(n) -> 1..n (math.random). Returns tiles, isLoop like world_tiles.
M.WANDER = 6
M.WANDER_TRIES = 8
function M.wander_tiles(World, key, pair, flag, rand)
    rand = rand or math.random
    local m = World.map(key)
    local env = (m.env == "CAVE" or m.env == "DUNGEON") and 4 or 0
    local blocked = World.blocked and World.blocked(key, flag) or {}
    local avoid = World.avoid and World.avoid(key, flag) or {}
    local coll = function(x, y)
        local k = x .. "," .. y
        if blocked[k] or avoid[k] then return nil end
        return World.coll(key, x, y)
    end
    local big, n = M.region(coll, pair[1], pair[2], env, m.w, m.h, M.WANDER)
    local _, n0 = M.region(coll, pair[1], pair[2], env, m.w, m.h, M.RADIUS)
    if n <= n0 then return M.world_tiles(World, key, pair, nil, flag) end
    local cands = {}
    for k in pairs(big) do cands[#cands + 1] = k end
    table.sort(cands)
    for _ = 1, M.WANDER_TRIES do
        local k = cands[rand(#cands)]
        local hx, hy = k % 1024, k // 1024
        local set, sn = M.region(coll, hx, hy, env, m.w, m.h, 1 + rand(2))
        local loop = sn >= 3 and M.edge_loop(set) or nil
        if loop and #loop.x >= 6 then
            local out = {}
            for i = 1, #loop.x do out[i] = {loop.x[i], loop.y[i]} end
            if rand(2) == 2 then
                local rev = {}
                for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
                out = rev
            end
            return out, true
        end
    end
    return M.world_tiles(World, key, pair, nil, flag)
end

-- The pacing walk for hunt / story / evolve: p:next(x, y) -> the next tile
-- to walk to (x, y: where we stand, nil off the map); a new loop
-- (wander_tiles) each time round. p:fallback(): just the pair from now on
-- (a loop tile out of reach). p:size(): tiles in the current round.
function M.pacer(World, key, pair, flag, rand)
    local p = {path = nil, i = 0, pairOnly = false}
    function p:next(x, y)
        if not self.path or self.i >= #self.path then
            if self.pairOnly then
                self.path = {{pair[1], pair[2]}, {pair[3], pair[4]}}
            else
                self.path = M.wander_tiles(World, key, pair, flag, rand)
            end
            self.path = M.from_here(self.path, x, y)
            self.i = 0
        end
        self.i = self.i + 1
        return self.path[self.i]
    end
    function p:fallback() self.pairOnly, self.path = true, nil end
    function p:size() return self.path and #self.path or 0 end
    return p
end

-- Everything in one go: the loop around home, or nil and why. The reader is
-- checked against the game where the player stands (playerX, playerY).
-- read8 reads WRAM, rom(bank, addr) the ROM, a = M.ADDR.crystal / .gs.
function M.plan(read8, rom, a, homeX, homeY, playerX, playerY, radius)
    local coll = M.collision_reader(read8, rom, a)
    if not M.reader_matches(coll, read8, a, playerX or homeX, playerY or homeY) then
        return nil, "reading the map didn't match the game"
    end
    local set, n = M.region(coll, homeX, homeY, read8(a.environment), read8(a.mapWidth), read8(a.mapHeight), radius)
    if n == 0 then return nil, "the start tile isn't one that gives encounters" end
    if n < 3 then return nil, "too few encounter tiles here for a loop" end
    local loop = M.edge_loop(set)
    if loop == nil or #loop.dirs < 3 then return nil, "no loop fits here" end
    loop.set, loop.size = set, n
    loop.mapGroup, loop.mapNumber = read8(a.mapGroup), read8(a.mapNumber)
    return loop
end

return M
