-- world.lua (lives in modules/data/)
-- The map of Crystal's world and how to get around it - the route planner
-- under the walker (walker.lua). No emulator calls here: it plans from
-- world_data.lua (every map, built from the pokecrystal disassembly by
-- tools/build_world.py) plus whatever the caller knows right now (which
-- event flags are set, where the people on the current map stand).
--
-- Positions are steps (16x16 pixels), as wXCoord/wYCoord count them; a map
-- is its "group:number" key (wMapGroup:wMapNumber).
--
-- Moving follows the game's own rules (engine/overworld/player_movement.asm,
-- home/map.asm GetMovementPermissions, engine/overworld/tile_events.asm):
--   * a step onto LAND (CollisionPermissionTable) - unless a side wall is in
--     the way: on the tile you stand on (it blocks leaving across that side)
--     or on the next one (blocks entering across its side);
--   * if the step can't be made, a LEDGE you stand on that points this way
--     jumps you two tiles;
--   * a door, staircase, cave or ladder tile with a warp warps you as you
--     step on it; a warp carpet ($70/$76/$78/$7E) as you push on into the
--     edge it points to;
--   * stepping off the map's edge takes you into the map connected there
--     (the connection's offset shifts the other coordinate by 2 x offset).
-- People and things block their tile. Tall grass, scene triggers and the
-- sight lines of trainers not yet beaten cost extra, so routes go round
-- them when that's not far.

local M = {}

M.DIRS = {
    Up = {dx = 0, dy = -1}, Down = {dx = 0, dy = 1},
    Left = {dx = -1, dy = 0}, Right = {dx = 1, dy = 0},
}
local DIR_NAMES = {"Up", "Down", "Left", "Right"}
M.DIR_NAMES = DIR_NAMES

-- What each step costs (steps are 1). A warp takes about a second of fading.
M.COST = {
    step = 1, jump = 2, warp = 8,
    turn = 0.15,        -- a change of direction: straight lines over staircases
    grass = 4,          -- tall/long grass: a wild battle every so often
    scene = 25,         -- a coord_event: may start a cutscene
    trainer = 200,      -- in sight of a trainer not yet beaten
    wanderer = 6,       -- where someone who walks about started out
    -- Pacing for wild ones (opts.pacing - the hunt's loop round a grass
    -- patch): the other way round - grass costs nothing extra, and a step
    -- or a jump onto a tile that gives no encounters costs this. (the user,
    -- 2026-11-09: on Route 31 the bot left the grass and hopped back in
    -- over a ledge - the +4 a grass step made that look shorter)
    off_grass = 4,
}

-- CollisionPermissionTable (low nibble: 0 land, 1 water, F wall), as in
-- walk_loop.lua.
local PERM_ROWS = {
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
local PERM = {}
for row, line in ipairs(PERM_ROWS) do
    local col = 0
    for h in line:gmatch("%x%x") do
        PERM[(row - 1) * 16 + col] = tonumber(h, 16) % 16
        col = col + 1
    end
end
M.PERM = PERM
local LAND, WATER = 0, 1

-- Tall and long grass (CheckGrassCollision's land ones).
local GRASS = {[0x08] = true, [0x18] = true, [0x14] = true, [0x48] = true, [0x49] = true,
    [0x4A] = true, [0x4B] = true, [0x4C] = true}
M.GRASS = GRASS
-- Warp carpets and the way you push to use one (.EdgeWarps).
local CARPET = {[0x70] = "Down", [0x78] = "Up", [0x76] = "Left", [0x7E] = "Right"}
M.CARPET = CARPET
-- Side walls: on the tile you stand on, low 3 bits -> the sides you can't
-- leave across; on the next tile, the low 3 bits that stop you entering.
local WALL_HERE = {
    [0] = {Right = true}, [1] = {Left = true}, [2] = {Up = true}, [3] = {Down = true},
    [4] = {Right = true, Down = true}, [5] = {Left = true, Down = true},
    [6] = {Right = true, Up = true}, [7] = {Left = true, Up = true},
}
local WALL_NEXT = {
    Down = {[2] = true, [6] = true, [7] = true}, Up = {[3] = true, [4] = true, [5] = true},
    Right = {[1] = true, [5] = true, [7] = true}, Left = {[0] = true, [4] = true, [6] = true},
}
-- Ledges: low 3 bits -> the ways they jump you (.ledge_table).
local LEDGE = {
    [0] = {Right = true}, [1] = {Left = true}, [2] = {Up = true}, [3] = {Down = true},
    [4] = {Right = true, Down = true}, [5] = {Down = true, Left = true},
    [6] = {Up = true, Right = true}, [7] = {Up = true, Left = true},
}
-- Tiles that move you on their own (player_movement.asm .CheckTile): a door,
-- staircase or cave you arrive on walks you a step down (out of the door);
-- conveyor tiles and currents push you their way.
local FORCED = {
    [0x71] = "Down", [0x79] = "Down", [0x7A] = "Down", [0x7B] = "Down",
    [0x41] = "Right", [0x42] = "Left", [0x43] = "Up", [0x44] = "Down",
    [0x50] = "Right", [0x51] = "Left", [0x52] = "Up", [0x53] = "Down",
    [0x30] = "Right", [0x31] = "Left", [0x32] = "Up", [0x33] = "Down",
    [0x38] = "Right", [0x39] = "Left", [0x3A] = "Up", [0x3B] = "Down",
}
M.FORCED = FORCED
-- Where you end up after arriving at (key, x, y): pushed on by forced tiles
-- until one that isn't.
function M.settle(key, x, y)
    for _ = 1, 16 do
        local d = FORCED[M.coll(key, x, y) or -1]
        if not d then break end
        local k2, x2, y2 = M.across(key, x + M.DIRS[d].dx, y + M.DIRS[d].dy)
        if not k2 then break end
        key, x, y = k2, x2, y2
    end
    return key, x, y
end
-- Sprite movements that stay on their tile (everything else walks about).
local function stays(move, rx, ry)
    if rx > 0 or ry > 0 then return false end
    return not (move:find("WALK") or move:find("WANDER"))
end
-- Which way a standing trainer looks (spinning ones look everywhere).
local LOOKS = {STANDING_DOWN = "Down", STANDING_UP = "Up", STANDING_LEFT = "Left", STANDING_RIGHT = "Right"}

M.data = nil
local cache = {}   -- map key -> decoded collision {[y * W + x + 1] = byte}

function M.load(data)
    M.data = data
    cache = {}
    -- Warps by tile, per map.
    for _, m in pairs(data.maps) do
        m.warpAt = {}
        for i, w in ipairs(m.warps) do m.warpAt[w[1] .. "," .. w[2]] = i end
    end
end

function M.map(key) return M.data.maps[key] end

local function grid(key)
    local g = cache[key]
    if g then return g end
    local m = M.data.maps[key]
    g = {}
    local hex = m.coll
    for i = 1, #hex, 2 do g[#g + 1] = tonumber(hex:sub(i, i + 1), 16) end
    cache[key] = g
    return g
end

-- The collision byte at a step on a map, or nil off it.
function M.coll(key, x, y)
    local m = M.data.maps[key]
    if not m then return nil end
    local W, H = m.w * 2, m.h * 2
    if x < 0 or y < 0 or x >= W or y >= H then return nil end
    return grid(key)[y * W + x + 1]
end

-- Where a step off the map's edge lands: the connected map and the step
-- there - or nil (no connection that way, or past its end).
function M.across(key, x, y)
    local m = M.data.maps[key]
    local W, H = m.w * 2, m.h * 2
    local dir, c
    if y < 0 then dir = "north" elseif y >= H then dir = "south"
    elseif x < 0 then dir = "west" elseif x >= W then dir = "east" else return key, x, y end
    c = m.conn[dir]
    if not c then return nil end
    local to, off = c[1], c[2]
    local t = M.data.maps[to]
    if not t then return nil end
    local nx, ny
    if dir == "north" then nx, ny = x - 2 * off, t.h * 2 - 1
    elseif dir == "south" then nx, ny = x - 2 * off, 0
    elseif dir == "west" then nx, ny = t.w * 2 - 1, y - 2 * off
    else nx, ny = 0, y - 2 * off end
    if nx < 0 or ny < 0 or nx >= t.w * 2 or ny >= t.h * 2 then return nil end
    return to, nx, ny
end

-- The collision byte of a step, following a connection if it's off the map.
function M.tile(key, x, y)
    local k2, x2, y2 = M.across(key, x, y)
    if not k2 then return nil end
    return M.coll(k2, x2, y2), k2, x2, y2
end

-- Where warp i of a map takes you: map key, x, y - or nil (an unknown map,
-- or "back where you came from").
function M.warp_dest(key, i)
    local w = M.data.maps[key].warps[i]
    local to, n = w[3], w[4]
    local t = M.data.maps[to]
    if not t or n < 1 or not t.warps[n] then return nil end
    return to, t.warps[n][1], t.warps[n][2]
end

-- Extra cost and blocked steps on a map, for this plan: people and things
-- (shown ones - flag(name) says whether an event flag is set), trainers'
-- sight lines, scene triggers. live = {["x,y"] = true} replaces the
-- objects with where they really stand (the current map, read from RAM).
local function costs_for(key, opts)
    local m = M.data.maps[key]
    local block, extra = {}, {}
    local flag = opts.flag or function() return false end
    local function add(x, y, c) local k = x .. "," .. y; extra[k] = (extra[k] or 0) + c end
    local live = opts.live and opts.live[key]
    if live then
        for k in pairs(live) do block[k] = true end
    end
    for _, o in ipairs(m.objs) do
        local x, y, sprite, move, rx, ry, otype, sight, _, hide, beat =
            o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11]
        local shown = hide == "-1" or not flag(hide)
        if shown then
            if not live then
                if stays(move, rx, ry) then block[x .. "," .. y] = true
                else add(x, y, M.COST.wanderer) end
            end
            if otype == "TRAINER" and sight > 0 and beat ~= "" and not flag(beat) and not opts.trainers then
                local dirs = LOOKS[move] and {LOOKS[move]} or DIR_NAMES
                for _, d in ipairs(dirs) do
                    local v = M.DIRS[d]
                    for s = 1, sight do
                        local c = M.coll(key, x + v.dx * s, y + v.dy * s)
                        if c == nil or PERM[c] ~= LAND then break end
                        add(x + v.dx * s, y + v.dy * s, M.COST.trainer)
                    end
                end
            end
        end
    end
    for _, c in ipairs(m.coords) do add(c[1], c[2], M.COST.scene) end
    return block, extra
end

-- Tiles on a map someone stands on for good (people, things that don't
-- walk about): {["x,y"] = true}. flag(name): event flags (who's shown).
function M.blocked(key, flag)
    local block = costs_for(key, {flag = flag})
    return block
end

-- Tiles to keep off when pacing about: a cutscene's trigger, or in sight
-- of a trainer not yet beaten. {["x,y"] = true}.
function M.avoid(key, flag)
    local _, extra = costs_for(key, {flag = flag})
    local out = {}
    for k, c in pairs(extra) do if c >= M.COST.scene then out[k] = true end end
    return out
end

-- Where to pace for wild Pokemon on a map: two neighbouring tiles that give
-- encounters (tall grass; any plain floor in a cave or tower), nobody
-- standing on either, both reachable from `here` ({map, x, y, face}). The
-- nearest to `near` ({x, y}) if given, else to where we are (on that map),
-- else to the map's entrances - never the first in reading order (in the
-- game: a cave's outer edge, outside its walls; a sage standing on the
-- pair in Sprout Tower - the bot paced into him, 2026-11-08).
-- {x1, y1, x2, y2} or nil.
function M.pace_pair(key, here, flag, near)
    local m = M.data.maps[key]
    local cave = m.env == "CAVE" or m.env == "DUNGEON"
    local block = M.blocked(key, flag)
    local function wild(x, y)
        if block[x .. "," .. y] then return false end
        local c = M.coll(key, x, y)
        return c ~= nil and (M.GRASS[c] or (cave and c == 0x00))
    end
    local spots = {}
    for y = 0, m.h * 2 - 1 do
        for x = 0, m.w * 2 - 1 do
            if wild(x, y) then
                if wild(x + 1, y) then spots[#spots + 1] = {x, y, x + 1, y} end
                if wild(x, y + 1) then spots[#spots + 1] = {x, y, x, y + 1} end
            end
        end
    end
    local anchors = {}
    if near then anchors = {near}
    elseif here and here.map == key then anchors = {{here.x, here.y}}
    else for _, w in ipairs(m.warps or {}) do anchors[#anchors + 1] = {w[1], w[2]} end end
    if #anchors == 0 then anchors = {{0, 0}} end
    local function dist(s)
        local b = 1e9
        for _, a in ipairs(anchors) do b = math.min(b, math.abs(s[1] - a[1]) + math.abs(s[2] - a[2])) end
        return b
    end
    table.sort(spots, function(a, b) local da, db = dist(a), dist(b); if da ~= db then return da < db end; return a[2] * 1000 + a[1] < b[2] * 1000 + b[1] end)
    for i = 1, math.min(#spots, 25) do
        local s = spots[i]
        local ok = not here or M.route(here, {map = key, x = s[1], y = s[2]}, {flag = flag})
        if ok and M.route({map = key, x = s[1], y = s[2], face = "Down"}, {map = key, x = s[3], y = s[4]}, {flag = flag}) then return s end
    end
    return nil
end

-- Every move from (key, x, y): {dir, kind, map, x, y, cost}. kind: "step",
-- "jump", "warp" (stepped on a door - or a pit), "carpet" (pushed a warp
-- mat - a step onto the next map across a connection is just a "step"),
-- "pushed" (onto a conveyor). Where a move ends is where you stand once any
-- forced steps are done (M.settle). costsOf(key) -> block, extra.
-- Warps that only work once an event flag is set: the Ruins of Alph
-- chambers' trap doors (3,3 and 4,3) open when the puzzle is solved - till
-- then they're floor, and the Kabuto puzzle's slab is read standing on 3,3
-- (the bot couldn't plan a way there: the user's log, 2026-11-08).
M.WARP_IF = {
    RuinsOfAlphKabutoChamber = {["3,3"] = "EVENT_SOLVED_KABUTO_PUZZLE", ["4,3"] = "EVENT_SOLVED_KABUTO_PUZZLE"},
    RuinsOfAlphOmanyteChamber = {["3,3"] = "EVENT_SOLVED_OMANYTE_PUZZLE", ["4,3"] = "EVENT_SOLVED_OMANYTE_PUZZLE"},
    RuinsOfAlphAerodactylChamber = {["3,3"] = "EVENT_SOLVED_AERODACTYL_PUZZLE", ["4,3"] = "EVENT_SOLVED_AERODACTYL_PUZZLE"},
    RuinsOfAlphHoOhChamber = {["3,3"] = "EVENT_SOLVED_HO_OH_PUZZLE", ["4,3"] = "EVENT_SOLVED_HO_OH_PUZZLE"},
}
function M.moves(key, x, y, costsOf, opts)
    local out = {}
    local S = M.coll(key, x, y)
    if S == nil then return out end
    local hi = S & 0xF0
    local env = M.data.maps[key].env
    for _, d in ipairs(DIR_NAMES) do
        local v = M.DIRS[d]
        -- Side walls.
        local walled = (hi == 0xB0 or hi == 0xC0) and WALL_HERE[S & 7][d]
        local T, k2, x2, y2 = M.tile(key, x + v.dx, y + v.dy)
        if T and not walled and (T & 0xF0 == 0xB0 or T & 0xF0 == 0xC0) and WALL_NEXT[d][T & 7] then walled = true end
        local stepped = false
        if T and not walled and (PERM[T] == LAND or (opts.surf and PERM[T] == WATER)) then
            local block, extra = costsOf(k2)
            local tk = x2 .. "," .. y2
            if not block[tk] then
                stepped = true
                local cost = M.COST.step + (extra[tk] or 0)
                local tenv = M.data.maps[k2].env
                if GRASS[T] or ((tenv == "CAVE" or tenv == "DUNGEON") and PERM[T] == LAND) then
                    if not opts.pacing then cost = cost + M.COST.grass end
                elseif opts.pacing then
                    cost = cost + M.COST.off_grass
                end
                local wi = M.data.maps[k2].warpAt[tk]
                local warps = wi and ((T & 0xF0) == 0x70 and not CARPET[T] or T == 0x60 or T == 0x68)
                local gate = warps and M.WARP_IF[M.data.maps[k2].name]
                gate = gate and gate[tk]
                if gate and not (opts and opts.flag and opts.flag(gate)) then warps = false end
                if warps then
                    local wk, wx, wy = M.warp_dest(k2, wi)
                    if wk then
                        wk, wx, wy = M.settle(wk, wx, wy)   -- out of the door
                        out[#out + 1] = {dir = d, kind = "warp", map = wk, x = wx, y = wy, cost = cost + M.COST.warp, via = {k2, x2, y2}}
                    end
                elseif FORCED[T] then
                    local fk, fx, fy = M.settle(k2, x2, y2)
                    out[#out + 1] = {dir = d, kind = "pushed", map = fk, x = fx, y = fy, cost = cost + 2}
                else
                    out[#out + 1] = {dir = d, kind = "step", map = k2, x = x2, y = y2, cost = cost}
                end
            end
        end
        if not stepped then
            -- A ledge under you that points this way.
            if hi == 0xA0 and LEDGE[S & 7][d] then
                local L, lk, lx, ly = M.tile(key, x + 2 * v.dx, y + 2 * v.dy)
                if L and PERM[L] == LAND then
                    local block, extra = costsOf(lk)
                    local lt = lx .. "," .. ly
                    if not block[lt] then
                        out[#out + 1] = {dir = d, kind = "jump", map = lk, x = lx, y = ly,
                            cost = M.COST.jump + (extra[lt] or 0) + (opts.pacing and M.COST.off_grass or 0)}
                    end
                end
            -- A carpet under you that points this way, with a warp on it.
            elseif CARPET[S] == d then
                local wi = M.data.maps[key].warpAt[x .. "," .. y]
                if wi then
                    local wk, wx, wy = M.warp_dest(key, wi)
                    if wk then
                        wk, wx, wy = M.settle(wk, wx, wy)
                        out[#out + 1] = {dir = d, kind = "carpet", map = wk, x = wx, y = wy, cost = M.COST.step + M.COST.warp}
                    end
                end
            end
        end
    end
    return out
end

-- Which maps lead to which (warps we can follow, connections), for pruning.
local function map_graph()
    if M.graph then return M.graph end
    local fwd, rev = {}, {}
    local function link(a, b)
        fwd[a] = fwd[a] or {}; fwd[a][b] = true
        rev[b] = rev[b] or {}; rev[b][a] = true
    end
    for key, m in pairs(M.data.maps) do
        for i in ipairs(m.warps) do
            local to = M.warp_dest(key, i)
            if to then link(key, to) end
        end
        for _, c in pairs(m.conn) do if M.data.maps[c[1]] then link(key, c[1]) end end
    end
    M.graph = {fwd = fwd, rev = rev}
    return M.graph
end

local function bfs(edges, from)
    local dist, queue, head = {[from] = 0}, {from}, 1
    while head <= #queue do
        local a = queue[head]; head = head + 1
        for b in pairs(edges[a] or {}) do
            if not dist[b] then dist[b] = dist[a] + 1; queue[#queue + 1] = b end
        end
    end
    return dist
end

-- A small binary heap of {cost, ...}.
local function heap_push(h, item)
    h[#h + 1] = item
    local i = #h
    while i > 1 do
        local p = i // 2
        if h[p][1] <= h[i][1] then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end
local function heap_pop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, s = 2 * i, 2 * i + 1, i
            if l <= #h and h[l][1] < h[s][1] then s = l end
            if r <= #h and h[r][1] < h[s][1] then s = r end
            if s == i then break end
            h[s], h[i] = h[i], h[s]
            i = s
        end
    end
    return top
end

-- The cheapest way from start {map, x, y} to goal: {map, x, y} (that step)
-- or {map, tiles = {{x, y}, ...}} (any of them). opts:
--   flag(name)  -> whether event flag `name` is set (people shown/hidden,
--                  trainers beaten); without it, all unset
--   live        {[mapKey] = {["x,y"] = true}} where people really stand
--   surf        true to cross water too
--   trainers    true to ignore trainers' sight lines (e.g. to battle them)
--   slack       how many maps out of the way it may look (default 2)
-- Returns a list of moves (see M.moves) and the total cost - or nil and why.
function M.route(start, goal, opts)
    opts = opts or {}
    local goalTiles = {}
    for _, t in ipairs(goal.tiles or {{goal.x, goal.y}}) do goalTiles[t[1] .. "," .. t[2]] = true end
    if not M.data.maps[start.map] then return nil, "unknown map " .. tostring(start.map) end
    if not M.data.maps[goal.map] then return nil, "unknown map " .. tostring(goal.map) end
    -- Only maps on (or near) a shortest chain of maps between the two.
    local g = map_graph()
    local fromStart, toGoal = bfs(g.fwd, start.map), bfs(g.rev, goal.map)
    local best = fromStart[goal.map]
    if not best then return nil, "no way from " .. start.map .. " to " .. goal.map end
    local slack = opts.slack or 2
    local function allowed(k)
        return fromStart[k] and toGoal[k] and fromStart[k] + toGoal[k] <= best + slack
    end
    local costCache = {}
    local function costsOf(k)
        local c = costCache[k]
        if not c then local b, e = costs_for(k, opts); c = {b, e}; costCache[k] = c end
        return c[1], c[2]
    end
    local gx, gy = goal.x, goal.y
    if not gx and goal.tiles then gx, gy = goal.tiles[1][1], goal.tiles[1][2] end
    local function h(k, x, y)
        if k == goal.map then return math.abs(x - gx) + math.abs(y - gy) end
        return 0
    end
    -- (The way you're heading is part of where you are: a turn costs a
    -- little, so of the equally short ways it takes the straightest -
    -- not a staircase of left-down-left-down.)
    local turn = M.COST.turn
    local function id(k, x, y, dir) return k .. "|" .. x .. "," .. y .. "|" .. (dir or "") end
    local startId = id(start.map, start.x, start.y, start.face)
    local dist, prev = {[startId] = 0}, {}
    local open = {}
    heap_push(open, {h(start.map, start.x, start.y), start.map, start.x, start.y, start.face, 0})
    local expanded = 0
    while #open > 0 do
        local cur = heap_pop(open)
        local k, x, y, dir = cur[2], cur[3], cur[4], cur[5]
        local cid = id(k, x, y, dir)
        local d = dist[cid]
        if cur[6] <= d then   -- (not superseded by a cheaper way here; g kept as is - no float drift)
            expanded = expanded + 1
            if k == goal.map and goalTiles[x .. "," .. y] then
                local path, at = {}, cid
                while prev[at] do
                    table.insert(path, 1, prev[at].move)
                    at = prev[at].from
                end
                return path, d
            end
            if expanded > (opts.limit or 200000) then return nil, "gave up (searched too far)" end
            for _, mv in ipairs(M.moves(k, x, y, costsOf, opts)) do
                if allowed(mv.map) then
                    local nid = id(mv.map, mv.x, mv.y, mv.dir)
                    local nd = d + mv.cost + ((dir and dir ~= mv.dir) and turn or 0)
                    if dist[nid] == nil or nd < dist[nid] then
                        dist[nid] = nd
                        prev[nid] = {from = cid, move = mv}
                        heap_push(open, {nd + h(mv.map, mv.x, mv.y), mv.map, mv.x, mv.y, mv.dir, nd})
                    end
                end
            end
        end
    end
    return nil, "no way there"
end

-- The tiles you can stand on to talk to the person at (x, y) on a map,
-- with the way to face: next to them - or across a counter (two away).
function M.talk_spots(key, x, y)
    local out = {}
    for _, d in ipairs(DIR_NAMES) do
        local v = M.DIRS[d]
        -- Standing at (x - v.dx * n, y - v.dy * n), facing d.
        local nx, ny = x - v.dx, y - v.dy
        local c = M.coll(key, nx, ny)
        if c and PERM[c] == LAND then out[#out + 1] = {nx, ny, d}
        elseif c and (c == 0x90 or c == 0x98) then   -- a counter in between
            local fx, fy = x - 2 * v.dx, y - 2 * v.dy
            local f = M.coll(key, fx, fy)
            if f and PERM[f] == LAND then out[#out + 1] = {fx, fy, d} end
        end
    end
    return out
end

-- How many map changes each map is from `from` (by warps and connections,
-- ignoring ledges and people) - for picking the nearest of several places.
function M.map_distances(from) return bfs(map_graph().fwd, from) end

-- A map's key by its name ("CherrygrovePokecenter1F"), or nil.
function M.key_of(name)
    for k, m in pairs(M.data.maps) do if m.name == name then return k end end
    return nil
end

-- A short description of a route, for the log: the maps it goes through.
function M.describe(path, from)
    local names, last = {}, from
    for _, mv in ipairs(path) do
        if mv.map ~= last then names[#names + 1] = M.data.maps[mv.map].name; last = mv.map end
    end
    return table.concat(names, " > ")
end

return M
