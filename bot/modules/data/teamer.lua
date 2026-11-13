-- teamer.lua (lives in modules/data/)
-- Keeps the party set to the team data/team.lua picks: on a visit to a
-- Pokemon Center (the walker calls M.manage after healing there), it works
-- out the team from everything owned (data/collection.lua), then at that
-- Center's PC deposits who's not in it and withdraws who is (data/pc.lua),
-- changing boxes as it needs to (the user, 2026-11-10 - each change saves
-- the game, as the game does): a full box -> the first box with room;
-- someone wanted in another box -> that box; and the box left current
-- always has room for a catch. Then it puts the party in order.
--
-- M.plan_moves is a plain function on tables, tested offline.

local M = {}

local World, State, Walker, Team, C, PC
local Names = {}
local log = print
M.starterLine = {}
M.current = nil         -- the last team picked (so a new one has to be clearly better)
M.said = {}             -- notes already logged once ("X is in box 4")
-- Fingerprints to have in the party besides the team (data/evolve.lua: the
-- copy being trained to evolve, friendship ones) - never put away, and
-- fetched from the current box like a team member.
M.keep = {}
-- The fingerprint of the one being trained (story training, the hunt's
-- training, evolving): kept in front when a Center visit sets the order.
-- nil: the team's own order.
M.front = nil

function M.setup(world, state, walker, team, collection, pc, names, logger, starterLine)
    World, State, Walker, Team, C, PC = world, state, walker, team, collection, pc
    Names = names or {}
    log = logger or print
    M.starterLine = starterLine or {}
end

local function name_of(sp) return Names[sp] or ("#" .. tostring(sp)) end

-- What to do: owned (collection, with keys), team (team.pick), party (C.party()),
-- the current box's number and how many are in it. Returns jobs for PC.use_pc,
-- the party order (fingerprints) and notes for the log.
-- counts ({[1..14] = how many in that box; nil: it doesn't read right}):
-- with it, boxes are changed as needed ({op = "box"} jobs, in order);
-- without, the current box only (as before).
M.BOX_SIZE = 20
function M.plan_moves(team, party, curBox, boxCount, hunting, counts)
    local wantKeys, wantList = {}, {}
    local function want(m) if m and not wantKeys[m.key] then wantKeys[m.key] = m; wantList[#wantList + 1] = m end end
    want(team.starter); want(team.catcher)
    for _, m in ipairs(team.specialists or {}) do want(m) end
    want(team.weak); want(team.healer)
    want(team.prospect and team.prospect.mon)     -- (the future catcher, in training: before the HM slave)
    want(team.hm)
    -- (and the ones to keep in the party: wherever they are now - one per
    -- fingerprint, the one in the party if there is: not every twin)
    if M.allOwned then
        local kept = {}
        for _, pass in ipairs({"party", "box"}) do
            for _, m in ipairs(M.allOwned) do
                local fp = PC.fingerprint(m)
                if M.keep[fp] and not kept[fp] and m.where == pass then kept[fp] = true; want(m) end
            end
        end
    end
    -- Twins (all DVs the same - Gen 2 has no ID number): one wanted from
    -- the box while one the same in every way that counts (species, level,
    -- moves) is in the party unwanted - that one does the job, no PC moves
    -- (the user's two Spinaraks, 2026-11-10, swapped at every Center).
    local function same(a, b)
        return PC.fingerprint(a) == PC.fingerprint(b) and a.species == b.species and a.level == b.level
            and table.concat(a.moves or {}, ",") == table.concat(b.moves or {}, ",")
    end
    for i, m in ipairs(wantList) do
        if m.where == "box" then
            for _, p in ipairs(party) do
                if not wantKeys[p.key] and not p.egg and same(m, p) then
                    wantList[i] = p
                    wantKeys[p.key] = p
                    wantKeys[m.key] = p       -- (the team's key for it - the party order finds it)
                    break
                end
            end
        end
    end
    local jobs, notes = {}, {}
    if counts then return M.plan_with_boxes(wantKeys, wantList, team, party, curBox, boxCount, hunting, counts) end
    local partyCount, room = #party, 20 - boxCount
    -- Deposits: in the party, not in the team (never the last one).
    for _, m in ipairs(party) do
        if not wantKeys[m.key] and not m.egg then
            if partyCount <= 1 then break end
            if room <= 0 then notes[#notes + 1] = "box " .. curBox .. " is full - can't put " .. name_of(m.species) .. " away"; break end
            jobs[#jobs + 1] = {op = "deposit", fp = PC.fingerprint(m), id = PC.ident and PC.ident(m), name = name_of(m.species)}
            partyCount, room = partyCount - 1, room - 1
        end
    end
    -- Withdrawals: in the team, not in the party - from the current box only.
    for _, m in ipairs(wantList) do
        if m.where == "box" then
            if m.box ~= curBox then
                notes[#notes + 1] = string.format("%s is in box %d, not the current box %d - move it there to have it in the team (changing boxes saves the game, so I leave that to you)",
                    name_of(m.species), m.box, curBox)
            elseif partyCount >= 6 then
                notes[#notes + 1] = "the party's full - " .. name_of(m.species) .. " stays in the box"
            else
                jobs[#jobs + 1] = {op = "withdraw", fp = PC.fingerprint(m), id = PC.ident and PC.ident(m), name = name_of(m.species)}
                partyCount = partyCount + 1
            end
        end
    end
    return jobs, M.party_order(team, wantKeys, hunting), notes
end

-- The order: the team's, by fingerprint - with the one being trained
-- (M.front) in front, so a Center visit doesn't undo the training
-- order (the user saw it swap to Totodile and back, 2026-11-08).
function M.party_order(team, wantKeys, hunting)
    local order = {}
    if M.front then order[1] = M.front end
    for _, key in ipairs(Team.party_order(team, hunting)) do
        local m = wantKeys[key]
        if m and PC.fingerprint(m) ~= M.front then order[#order + 1] = PC.fingerprint(m) end
    end
    return order
end

-- plan_moves with every box. Each box change saves the game, so as few as
-- it takes:
--   1. deposits into the current box while it has room;
--   2. withdrawals from the current box, while it's still current;
--   3. the rest of the deposits: the first box with room;
--   4. withdrawals from other boxes, box by box;
--   5. the box left current has room for a catch (the party full: the
--      catches go there).
function M.plan_with_boxes(wantKeys, wantList, team, party, curBox, boxCount, hunting, counts)
    local jobs, notes = {}, {}
    local cnt = {}
    for b = 1, 14 do cnt[b] = counts[b] end
    cnt[curBox] = boxCount
    local cur = curBox
    local function room_box()
        for b = 1, 14 do if b ~= cur and cnt[b] and cnt[b] < M.BOX_SIZE then return b end end
        return nil
    end
    local function go(b, why)
        jobs[#jobs + 1] = {op = "box", box = b, name = "box " .. b, why = why}
        cur = b
    end
    local partyCount = #party
    -- (in the party, not in the team - never the last one)
    local deps = {}
    for _, m in ipairs(party) do if not wantKeys[m.key] and not m.egg then deps[#deps + 1] = m end end
    local function deposit(m)
        jobs[#jobs + 1] = {op = "deposit", fp = PC.fingerprint(m), id = PC.ident and PC.ident(m), name = name_of(m.species)}
        partyCount, cnt[cur] = partyCount - 1, cnt[cur] + 1
    end
    local byBox, boxes, taken = {}, {}, {}
    for _, m in ipairs(wantList) do
        if m.where == "box" and m.box then
            if not byBox[m.box] then byBox[m.box] = {}; boxes[#boxes + 1] = m.box end
            table.insert(byBox[m.box], m)
        end
    end
    local function withdraw_from(b)
        for _, m in ipairs(byBox[b] or {}) do
            if not taken[m] and partyCount < 6 and cnt[b] then
                if cur ~= b then go(b, "to take out " .. name_of(m.species)) end
                jobs[#jobs + 1] = {op = "withdraw", fp = PC.fingerprint(m), id = PC.ident and PC.ident(m), name = name_of(m.species)}
                partyCount, cnt[b] = partyCount + 1, cnt[b] - 1
                taken[m] = true
            end
        end
    end
    -- 1.
    local i = 1
    while deps[i] and partyCount > 1 and cnt[cur] < M.BOX_SIZE do deposit(deps[i]); i = i + 1 end
    -- 2.
    withdraw_from(cur)
    -- 3.
    while deps[i] and partyCount > 1 do
        if cnt[cur] >= M.BOX_SIZE then
            local b = room_box()
            if not b then notes[#notes + 1] = "every PC box is full - can't put " .. name_of(deps[i].species) .. " away"; break end
            go(b, "box " .. cur .. " is full")
        end
        deposit(deps[i]); i = i + 1
    end
    -- 4. (the one current now first, then by number)
    table.sort(boxes, function(a, b)
        if a == b then return false end
        if a == cur then return true end
        if b == cur then return false end
        return a < b
    end)
    for _, b in ipairs(boxes) do withdraw_from(b) end
    for _, b in ipairs(boxes) do
        for _, m in ipairs(byBox[b]) do
            if not taken[m] then notes[#notes + 1] = "the party's full - " .. name_of(m.species) .. " stays in box " .. b end
        end
    end
    -- 5.
    if cnt[cur] >= M.BOX_SIZE then
        local b = room_box()
        if b then go(b, "box " .. cur .. " is full - room for the next catches")
        else notes[#notes + 1] = "every PC box is full" end
    end
    return jobs, M.party_order(team, wantKeys, hunting), notes
end

-- At a Pokemon Center (map key): set the party to the team. opts: the
-- walker's (say...). nil, or why the walk must stop.
function M.manage(centerKey, opts)
    opts = opts or {}
    local say = opts.say or log
    if not C.readSram then return nil end
    local owned = C.for_team(M.starterLine)
    M.allOwned = owned
    local team = Team.pick(owned, M.current)
    if team.changed or not M.current then
        say("Team: " .. table.concat(team.why, " | ") .. ".")
    end
    M.current = team
    local party = C.party()
    local box, why = C.box(C.current_box())
    if not box then return nil end       -- (a new game's box before the first save)
    local jobs, order, notes = M.plan_moves(team, party, C.current_box(), #box, opts.hunting, M.box_counts())
    for _, n in ipairs(notes) do
        if not M.said[n] then M.said[n] = true; say("(" .. n .. ".)") end
    end
    -- Already right?
    local inOrder = true
    for i, fp in ipairs(order) do
        if not party[i] or PC.fingerprint(party[i]) ~= fp then inOrder = false end
    end
    if #jobs == 0 and inOrder then return nil end
    if #jobs > 0 then
        -- To the PC (the tile the game runs the PC from), then the jobs.
        local m = World.map(centerKey)
        local spots = {}
        for y = 0, m.h * 2 - 1 do for x = 0, m.w * 2 - 1 do
            if World.coll(centerKey, x, y) == PC.PC_TILE then
                for _, s in ipairs(World.talk_spots(centerKey, x, y)) do spots[#spots + 1] = s end
            end
        end end
        if #spots == 0 then return nil end
        local list = {}
        for _, j in ipairs(jobs) do
            list[#list + 1] = (j.op == "deposit" and "put away " or j.op == "box" and "change to " or "take out ") .. j.name
        end
        say("To the PC: " .. table.concat(list, ", ") .. ".")
        local ok, stop = Walker.go({map = centerKey, tiles = spots}, opts)
        if not ok then return stop end
        PC.use_pc(jobs, {say = say})
    end
    PC.order_party(order, {say = say})
    return nil
end

-- How many are in each box, 1-14 (nil: it doesn't read right). Before the
-- game's first save the boxes in the cartridge aren't set up yet - the
-- first save (a box change is one) clears them: counted as empty.
local SAVED_ONCE = 0xD4B4             -- wSavedAtLeastOnce
function M.box_counts()
    local saved = State.read8(SAVED_ONCE) ~= 0
    local counts = {}
    for b = 1, 14 do
        local list = C.box(b)
        if list then counts[b] = #list elseif not saved then counts[b] = 0 end
    end
    return counts
end

-- The hunt's order check (data/hunt.lua, every few minutes): whether the
-- one that should lead (order[1]) is in the party but not in front. Not
-- there at all - in another box - nothing a party switch can do (the code
-- review, 2026-11-11: it opened the party menu every 10 minutes for nothing).
function M.lead_out_of_place(order, party)
    local want = order and order[1]
    if not want or not party or not party[1] then return false end
    if PC.fingerprint(party[1]) == want then return false end
    for _, m in ipairs(party) do if PC.fingerprint(m) == want then return true end end
    return false
end

-- The team's fighters (starter + specialists) in the party: {fingerprint, species, level}.
function M.fighters()
    if not M.current then return {} end
    local out = {}
    local party = C.party()
    local function add(t)
        if not t then return end
        for _, m in ipairs(party) do
            if PC.fingerprint(m) == PC.fingerprint(t) then out[#out + 1] = {fp = PC.fingerprint(m), species = m.species, level = m.level} end
        end
    end
    add(M.current.starter)
    for _, s in ipairs(M.current.specialists or {}) do add(s) end
    return out
end

return M
