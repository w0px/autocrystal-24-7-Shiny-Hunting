-- pc.lua (lives in modules/data/)
-- Moves Pokemon between the party and the PC box, and reorders the party -
-- the way a player does: at a Pokemon Center's PC, BILL's PC, WITHDRAW /
-- DEPOSIT, the Pokemon, then WITHDRAW / DEPOSIT in its submenu; and in the
-- START menu's POKeMON list, the Pokemon, SWITCH, where to.
--
-- Deposits and withdrawals work on the CURRENT box. A {op = "box", box = n}
-- job changes it (the user, 2026-11-10: the bot changes boxes itself):
-- BILL's PC > CHANGE BOX > box n > SWITCH > "data will be saved. OK?" YES
-- (and "already a save file - overwrite?" YES when it's this game's own
-- save) - the game saves, as it always does on a box change
-- (engine/pokemon/bills_pc.asm _ChangeBox, engine/menus/save.asm
-- ChangeBoxSaveGame). NAME / PRINT never: SWITCH is row 1, checked in RAM.
--
-- SAFETY - a shiny must never be released:
--   * in the WITHDRAW/STATS/RELEASE/CANCEL (and DEPOSIT/...) submenu, A is
--     pressed only with the cursor on the first row - checked in RAM
--     (wMenuCursorY) right before; anything else: B;
--   * any YES/NO that shows up while at the PC is answered NO (B) - the
--     "release it?" one above all - except the box change's save question
--     (and its "overwrite your save?"), and only when the game's routine
--     for exactly that question ran (ROM hook) during a box job and the
--     screen says "save";
--   * before picking a Pokemon in a list, the species under the cursor
--     (wBillsPCPokemonList) must be the one wanted, else B.
-- Pokemon are recognised by species + DVs + trainer ID ("fingerprint"),
-- so the box shifting as they come out doesn't matter.
--
-- Each screen is recognised by the game's routine for it (ROM hooks), each
-- press waits until the game has taken it (Screen.menu_waiting, positions
-- in RAM), and a watchdog backs out of anything left waiting.

local M = {}

local Screen = require("data.screen")
local C = require("data.collection")
local State, ButtonWait, Names
local log = print

local function rom(bank, addr) return bank == 0 and addr or bank * 0x4000 + (addr - 0x4000) end
-- (pokecrystal11.sym)
local HOOKS = {
    pcTop = rom(0x05, 0x55B3),        -- PokemonCenterPC.loop: "Whose PC?" (BILL's PC is always row 1)
    bills = rom(0x03, 0x644B),        -- _BillsPC.loop: WITHDRAW / DEPOSIT / CHANGE BOX / MOVE / SEE YA!
    wInit = rom(0x38, 0x65DC),        -- _WithdrawPKMN.Init: the box list is (re)drawn
    dInit = rom(0x38, 0x63E9),        -- _DepositPKMN.Init: the party list is (re)drawn
    wList = rom(0x38, 0x6612),        -- _WithdrawPKMN.Joypad: every frame the list waits
    dList = rom(0x38, 0x641A),        -- _DepositPKMN.HandleJoypad
    wSub = rom(0x38, 0x6675),         -- BillsPC_Withdraw: WITHDRAW / STATS / RELEASE / CANCEL
    dSub = rom(0x38, 0x647D),         -- _DepositPKMN.Submenu: DEPOSIT / STATS / RELEASE / CANCEL
    startMenu = rom(0x04, 0x6669),    -- StartMenu.GetInput
    menuClosed = rom(0x04, 0x6662),   -- StartMenu.ReturnEnd2
    partyMenu = rom(0x14, 0x4457),    -- PartyMenuSelect
    monSub = rom(0x09, 0x4D19),       -- MonSubmenu: (field moves) STATS / SWITCH / ITEM / CANCEL
    cbLoop = rom(0x38, 0x75B0),       -- _ChangeBox.loop: the box list is (re)drawn
    cbSub = rom(0x38, 0x76F9),        -- BillsPC_ChangeBoxSubmenu: SWITCH / NAME / PRINT / QUIT
    cbSave = rom(0x05, 0x4A83),       -- ChangeBoxSaveGame: "When you change a #MON BOX, data will be saved. OK?"
    cbMine = rom(0x05, 0x4B9E),       -- AskOverwriteSaveFile.yoursavefile: "already a save file - overwrite?" (this game's)
}
local A = {
    menuY = 0xCFA9,
    list = 0xC800,                    -- wBillsPCPokemonList: 3 bytes each, species first
    scroll = 0xCB2A, cursor = 0xCB2B, -- wBillsPC_ScrollPosition / _CursorPosition
    partyCount = 0xDCD7, partySpecies = 0xDCD8,
    menuItems = 0xD03E,               -- wMenuItemsList (START menu)
    monSubCount = 0xD1EA, monSubItems = 0xD1EB,
    menuSel = 0xCF74,                 -- wMenuSelection: the box picked (1-14)
    menuScroll = 0xD0E4,              -- wMenuScrollPosition: the box list's scroll
}
local STARTMENU_POKEMON = 1
local MONMENU_SWITCH = 16
M.PC_TILE = 0x93                      -- COLL_PC: face it and press A

local H = {}

function M.setup(state, buttonWait, mem, names, logger)
    State, ButtonWait, Names = state, buttonWait, names or {}
    M._mem = mem          -- (its hook group switched on around the entry points below)
    log = logger or print
    if mem then
        for name, addr in pairs(HOOKS) do
            mem.RegisterROMHook(addr, function() H[name] = emu.framecount() end, "PC " .. name, nil, "PC")
        end
    end
end

local function r(a) return State.read8(a) end
local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end
local function take(name) local f = H[name]; H[name] = nil; return f ~= nil end
local function recent(name, within)
    if H[name] == nil then return false end
    local d = emu.framecount() - H[name]
    return d >= 0 and d <= (within or 3)
end
local function name_of(sp) return Names[sp] or ("#" .. tostring(sp)) end

-- (not Exp - it changes every battle; nor the species - evolving changes
-- it: its family's first form, DVs and trainer ID stay - data/family.lua)
function M.fingerprint(m)
    return require("data.family").fp(m.species, m.dvs[1], m.dvs[2], m.otId)
end
-- Which one exactly, for a PC job (nothing changes in the PC): the
-- fingerprint and everything else that can tell twins apart - Gen 2 has
-- no ID number. Two shinies of a species share every DV 1 time in 8 (the
-- user's two Spinaraks, 2026-11-10); with this the same only if they're
-- the same in every way, and then either one will do.
function M.ident(m)
    return table.concat({M.fingerprint(m), m.species, m.level or "", m.exp or "", m.statExp or "", m.caught or "",
        table.concat(m.moves or {}, ",")}, "|")
end

local function wait_menu(n)
    for _ = 1, n or 180 do
        if Screen.menu_waiting() then return true end
        emu.frameadvance()
    end
    return false
end

-- A standard menu's cursor to row y: press, then wait for it to move.
local function cursor_to(y)
    for _ = 1, 15 do
        local cy = r(A.menuY)
        if cy == y then return true end
        press(cy < y and "Down" or "Up")
        for _ = 1, 15 do if r(A.menuY) ~= cy then break end; emu.frameadvance() end
    end
    return r(A.menuY) == y
end

-- Bill's PC list: the entry at index i (0-based) under the cursor.
local function list_at() return r(A.scroll) + r(A.cursor) end
local function list_species(i) return r(A.list + i * 3) end
local function list_to(i)
    for _ = 1, 40 do
        local at = list_at()
        if at == i then return true end
        press(at < i and "Down" or "Up")
        for _ = 1, 20 do if list_at() ~= at then break end; emu.frameadvance() end
    end
    return list_at() == i
end

-- CHANGE BOX's list (14 boxes, 4 rows shown, CANCEL after): the box under
-- the cursor is scroll + row (scrolling_menu.asm: ScrollingMenu_GetCursorPosition).
local function box_at() return r(A.menuScroll) + r(A.menuY) end
local function box_to(b)
    for _ = 1, 30 do
        local at = box_at()
        if at == b then return true end
        if at < 1 or at > 15 then return false end
        press(at < b and "Down" or "Up")
        for _ = 1, 20 do if box_at() ~= at then break end; emu.frameadvance() end
    end
    return box_at() == b
end

-- Where a job's Pokemon is now: index (0-based) in the party / current
-- box, and how many there match (its ident if the job has one, else its
-- fingerprint) - a job is done when that count went down by one, not when
-- none is left: twins were all moved, 2026-11-10 (both Spinaraks out of
-- the box for one "take out", both put away for one "put away").
local function find_in(list, j)
    local n, at, mon = 0, nil, nil
    for i, m in ipairs(list) do
        local same = j.id and M.ident(m) == j.id or (not j.id and M.fingerprint(m) == j.fp)
        if same then
            n = n + 1
            if not at then at, mon = i - 1, m end
        end
    end
    return at, mon, n
end
M._find_in = find_in

-- At the PC (standing facing it): do the jobs - {{op = "deposit" | "withdraw",
-- fp = fingerprint}, ...} - deposits first; with any {op = "box", box = n}
-- among them, in the order given (data/teamer.lua plans it). Returns how
-- many were done.
function M.use_pc(jobs, opts)
    opts = opts or {}
    local say = opts.say or log
    local deposits, withdraws = {}, {}
    for _, j in ipairs(jobs) do
        if j.op == "deposit" then deposits[#deposits + 1] = j else withdraws[#withdraws + 1] = j end
    end
    local queue = {}
    local ordered = false
    for _, j in ipairs(jobs) do if j.op == "box" then ordered = true end end
    if ordered then
        for _, j in ipairs(jobs) do queue[#queue + 1] = j end
    else
        for _, j in ipairs(deposits) do queue[#queue + 1] = j end
        for _, j in ipairs(withdraws) do queue[#queue + 1] = j end
    end
    for k in pairs(H) do H[k] = nil end

    local done, tries = 0, {}
    local job = nil          -- the one being done
    local mode = nil         -- "withdraw" / "deposit": which list we're in
    local leaving = false
    local menuFor = Screen.watch()
    local function next_job()
        while queue[1] do
            local j = queue[1]
            if j.op == "box" then
                if C.current_box() == j.box then
                    if j.started then done = done + 1; say(string.format("Changed to box %d (the game saved).", j.box)) end
                    table.remove(queue, 1)
                elseif (tries[j] or 0) >= 3 then
                    -- (the rest was planned for that box: none of it)
                    say(string.format("(Couldn't change to box %d after 3 tries - leaving the PC.)", j.box))
                    for k = #queue, 1, -1 do queue[k] = nil end
                else
                    return j
                end
                goto continue
            end
            local where = j.op == "deposit" and C.party() or C.box(C.current_box())
            local i, m, n = nil, nil, 0
            if where then i, m, n = find_in(where, j) end
            -- (how many it leaves behind: one fewer than when it began)
            if where and j.left == nil and n > 0 then j.left = n - 1 end
            if i and j.left ~= nil and n <= j.left then i = nil end
            if not i then
                -- (done already - or not there to begin with)
                if j.started then done = done + 1; say(string.format("%s %s.", j.op == "deposit" and "Deposited" or "Withdrew", j.name or "it"))
                else say(string.format("(Couldn't find %s in the %s - skipping it.)", j.name or "it", j.op == "deposit" and "party" or "current box")) end
                table.remove(queue, 1)
            elseif (tries[j] or 0) >= 3 then
                say(string.format("(Gave up on %s %s after 3 tries.)", j.op == "deposit" and "depositing" or "withdrawing", j.name or "it"))
                table.remove(queue, 1)
            else
                return j, i, m
            end
            ::continue::
        end
        return nil
    end

    press("A")           -- (facing the PC)
    local n, ended, seen = 0, 0, false
    while n < 60 * 180 do
        for k in pairs(H) do seen = true end
        if Screen.yes_no_waiting() then
            -- (the box change's save questions: YES - only in a box job,
            -- right after the game's routine for them, the screen saying
            -- "save"; anything else - "release it?" - NO)
            local text = Screen.text()
            local saveQ = job and job.op == "box" and (H.cbSave or H.cbMine) and text:lower():match("sav") ~= nil
            if saveQ then
                H.cbSave, H.cbMine = nil, nil
                Screen.answer(true, press)
            else
                say("(A YES/NO at the PC - " .. text .. " - answering NO.)")
                Screen.answer(false, press)
            end
            n = n + 20
        elseif take("pcTop") then
            wait_menu()
            if not leaving and next_job() then
                cursor_to(1); press("A")           -- BILL's PC
            else
                leaving = true; press("B")         -- (turn it off)
            end
            n = n + 30
        elseif take("bills") then
            wait_menu()
            local j = (not leaving) and next_job()
            if j then
                mode = j.op
                cursor_to(j.op == "withdraw" and 1 or j.op == "deposit" and 2 or 3); press("A")   -- (3: CHANGE BOX)
            else
                leaving = true
                cursor_to(5); press("A")           -- SEE YA!
            end
            n = n + 30
        elseif take("wInit") or take("dInit") then
            -- (a list is up: wait till it takes input, then go to the one wanted)
            for _ = 1, 120 do if recent("wList") or recent("dList") then break end; emu.frameadvance() end
            local j, i, m = next_job()
            if j and j.op == mode and not leaving then
                job = j
                tries[j] = (tries[j] or 0) + 1
                j.started = true
                -- (the species under the cursor must be the one wanted)
                if list_to(i) and list_species(i) == m.species then
                    -- A only once the list reads buttons again (moving the
                    -- cursor loads the Pokemon's picture - a press then is
                    -- lost: seen in the game, 2026-11-08), and again until its
                    -- WITHDRAW/DEPOSIT menu really opens.
                    local opened = false
                    for _ = 1, 4 do
                        H.wList, H.dList = nil, nil
                        for _ = 1, 120 do if H.wList or H.dList then break end; emu.frameadvance() end
                        if list_at() ~= i then break end
                        H.wSub, H.dSub = nil, nil
                        press("A")
                        for _ = 1, 60 do if H.wSub or H.dSub then opened = true; break end; emu.frameadvance() end
                        if opened then break end
                    end
                    if not opened then
                        say("(The PC list didn't take A - backing out.)")
                        job = nil
                        press("B")
                    end
                else
                    say("(The list didn't line up with what I expected - backing out.)")
                    job = nil
                    press("B")
                end
            else
                job = nil
                press("B")                         -- (back to BILL's PC's menu)
            end
            n = n + 40
        elseif take("cbLoop") then
            -- The box list: the box wanted, A until its menu opens.
            wait_menu()
            local j = (not leaving) and next_job()
            if j and j.op == "box" then
                job = j
                tries[j] = (tries[j] or 0) + 1
                j.started = true
                local opened = false
                if box_to(j.box) then
                    say(string.format("Changing to box %d (%s) - the game saves.", j.box, j.why or "room for more"))
                    for _ = 1, 4 do
                        wait_menu()
                        if box_at() ~= j.box then break end
                        H.cbSub = nil
                        press("A")
                        for _ = 1, 60 do if H.cbSub then opened = true; break end; emu.frameadvance() end
                        if opened then break end
                    end
                end
                if not opened then
                    say("(The box list didn't line up or take A - backing out.)")
                    job = nil
                    press("B")
                end
            else
                job = nil
                press("B")                         -- (out of the box list: BILL's PC's menu)
            end
            n = n + 40
        elseif take("cbSub") then
            -- SWITCH / NAME / PRINT / QUIT: SWITCH (row 1) only, for the box wanted.
            wait_menu()
            if job and job.op == "box" and r(A.menuSel) == job.box and cursor_to(1) and r(A.menuY) == 1 then
                H.cbSave, H.cbMine = nil, nil
                press("A")
            else
                press("B")
            end
            n = n + 30
        elseif take("wSub") or take("dSub") then
            -- WITHDRAW|DEPOSIT / STATS / RELEASE / CANCEL: only ever row 1.
            wait_menu()
            if job and cursor_to(1) and r(A.menuY) == 1 then
                press("A")
            else
                press("B")
            end
            job = nil
            n = n + 30
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "A")
        elseif menuFor(Screen.menu_waiting()) > 360 then
            say("(A menu was left waiting at the PC - " .. Screen.text() .. " - pressing B.)")
            press("B")
            n = n + 20
        else
            emu.frameadvance()
            n = n + 1
            if not State.script_running() then
                ended = ended + 1
                if ended > 40 and (leaving or (not seen and n > 300)) then break end
            else
                ended = 0
            end
        end
    end
    -- (any still listed: count what's actually done)
    next_job()
    -- (never walk off with the PC still open: B while its menus are on screen
    -- - a ▶ cursor in the tile map, text waiting - or its script still runs;
    -- the screen is the truth, the user's rule, 2026-11-08)
    local function pc_open()
        return Screen.cursor() ~= nil or ButtonWait.waiting() or Screen.menu_waiting() or State.script_running()
    end
    frames(20)
    if pc_open() then
        say("(The PC is still open - " .. Screen.text() .. " - backing out with B.)")
        for _ = 1, 12 do
            if not pc_open() then break end
            if Screen.yes_no_waiting() then Screen.answer(false, press) else press("B") end
            frames(25)
        end
    end
    frames(10)
    return done
end

-- ------------------------------------------------------------ party order

-- Reorder the party so the fingerprints in `want` come first, in that
-- order (the rest after, as they were). Through START > POKeMON > the
-- Pokemon > SWITCH > where. Returns true when the party is in that order.
function M.order_party(want, opts)
    opts = opts or {}
    local say = opts.say or log
    local function order_ok()
        local party = C.party()
        for i, fp in ipairs(want) do
            if not party[i] or M.fingerprint(party[i]) ~= fp then return false end
        end
        return true
    end
    if order_ok() then return true end
    -- The next swap: the first slot that's wrong, and where its mon is.
    local function next_swap()
        local party = C.party()
        for i, fp in ipairs(want) do
            if not party[i] or M.fingerprint(party[i]) ~= fp then
                for j = i + 1, #party do
                    if M.fingerprint(party[j]) == fp then return i, j end
                end
                return nil
            end
        end
        return nil
    end
    for k in pairs(H) do H[k] = nil end
    local phase, swap, closing, closed = "first", nil, false, false
    local menuFor = Screen.watch()
    local swaps = 0
    press("Start")
    local n = 0
    while n < 60 * 90 do
        if take("menuClosed") then closed = true; break
        elseif take("startMenu") then
            wait_menu()
            local row = nil
            for k = 1, math.min(r(A.menuItems), 10) do if r(A.menuItems + k) == STARTMENU_POKEMON then row = k end end
            if closing or not row then closing = true; press("B")
            else cursor_to(row); press("A") end
            n = n + 30
        elseif take("partyMenu") then
            -- (the list says it's waiting a few frames before it reads
            -- buttons - an A then is lost: seen in the game, 2026-11-08;
            -- data/bag.lua's 15 frames, which worked, first)
            frames(15)
            wait_menu()
            if phase == "first" then
                local i, j = next_swap()
                if i and swaps < 8 then
                    swap = {i, j}
                    -- the one to move - again until its menu really opens
                    local opened = false
                    for _ = 1, 4 do
                        cursor_to(i)
                        H.monSub = nil
                        press("A")
                        for _ = 1, 60 do if H.monSub then opened = true; break end; emu.frameadvance() end
                        if opened then break end
                        wait_menu()
                    end
                    if opened then phase = "sub"
                    else say("(The party list didn't take A - closing it.)"); closing = true; press("B") end
                else
                    closing = true; press("B")     -- (done: out of the party menu)
                end
            elseif phase == "where" then
                cursor_to(swap[2]); press("A")     -- where it goes
                phase = "first"
                swaps = swaps + 1
                frames(30)
            else
                press("B")
            end
            n = n + 30
        elseif take("monSub") then
            wait_menu()
            local row = nil
            for k = 1, math.min(r(A.monSubCount), 8) do if r(A.monSubItems + k - 1) == MONMENU_SWITCH then row = k end end
            if phase == "sub" and row then
                cursor_to(row); press("A")         -- SWITCH
                phase = "where"
            else
                press("B"); phase = "first"
            end
            n = n + 30
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "A")
        elseif menuFor(Screen.menu_waiting()) > 360 then
            say("(A menu was left waiting in the party - " .. Screen.text() .. " - pressing B.)")
            press("B")
            n = n + 20
        else
            emu.frameadvance()
            n = n + 1
        end
    end
    if not closed then for _ = 1, 4 do press("B"); frames(20) end end
    local ok = order_ok()
    if not ok then say("(The party isn't in the order I wanted after switching.)") end
    return ok
end

-- ------------------------------------------------------------ field healing

-- Softboiled / Milk Drink outside battle (the user, 2026-11-08: the healer
-- slot, Miltank): the healer gives a fifth of ITS max HP to another one -
-- the game's rules (engine/items/item_effects.asm Softboiled_MilkDrinkFunction,
-- mon_menu.asm): the healer needs more than a fifth of its max HP left,
-- and the one healed can't be the healer, fainted or at full HP. No PP.
-- It doesn't cure a status or revive - that's still the Center's.
M.SOFTBOILED, M.MILK_DRINK = 0x87, 0xD0
local MONMENU_SOFTBOILED, MONMENU_MILKDRINK = 10, 13

-- The party's healer: index (1-based) of one that knows either move, or nil.
function M.healer_index(party)
    for i, m in ipairs(party) do
        if not m.egg then
            for _, mv in ipairs(m.moves or {}) do
                if mv == M.SOFTBOILED or mv == M.MILK_DRINK then return i end
            end
        end
    end
    return nil
end
-- Whether the healer at h can give now.
function M.can_give(party, h)
    local u = party[h]
    return u ~= nil and not u.egg and u.maxhp > 0 and u.hp > u.maxhp // 5
end
-- Who to heal next: the one lowest (by share) under `share` of its HP that
-- the game lets it heal - index, or nil.
function M.field_target(party, h, share)
    if not h or not M.can_give(party, h) then return nil end
    local best, bestShare = nil, nil
    for i, m in ipairs(party) do
        if i ~= h and not m.egg and m.hp > 0 and m.maxhp > 0 and m.hp < m.maxhp and m.hp < share * m.maxhp then
            local s = m.hp / m.maxhp
            if not bestShare or s < bestShare then best, bestShare = i, s end
        end
    end
    return best
end

-- Heal the party with the healer while it has the HP: START > POKeMON >
-- the healer > MILK DRINK (SOFTBOILED) > who - again for the next one.
-- share: heal those under this share of their HP (1: top everyone up).
-- Returns how many times it healed.
function M.field_heal(share, opts)
    opts = opts or {}
    local say = opts.say or log
    local party = C.party()
    local h = M.healer_index(party)
    if not M.field_target(party, h, share or 1) then return 0 end
    for k in pairs(H) do H[k] = nil end
    local phase, closing, closed, healed, target = "user", false, false, 0, nil
    local menuFor = Screen.watch()
    local healerName = name_of(party[h].species)
    local moveName = "MILK DRINK"
    for _, mv in ipairs(party[h].moves or {}) do if mv == M.SOFTBOILED then moveName = "SOFTBOILED" end end
    press("Start")
    local n = 0
    while n < 60 * 90 do
        if take("menuClosed") then closed = true; break
        elseif take("startMenu") then
            wait_menu()
            local row = nil
            for k = 1, math.min(r(A.menuItems), 10) do if r(A.menuItems + k) == STARTMENU_POKEMON then row = k end end
            if closing or not row then closing = true; press("B")
            else H.partyMenu = nil; cursor_to(row); press("A") end   -- (a stale party-list mark from before the B)
            n = n + 30
        elseif take("partyMenu") then
            frames(15)       -- (the list's deaf first frames - order_party's lesson)
            wait_menu()
            party = C.party()
            h = M.healer_index(party)
            if phase == "target" and target and party[target] then
                -- "Use on which #MON?": the one picked; its HP goes up, then
                -- "...recovered N HP" waits for A or B - B (an extra A
                -- would open someone's menu here)
                local before = party[target].hp
                cursor_to(target); press("A")
                local after = before
                for _ = 1, 300 do
                    local p = C.party()[target]
                    if p and p.hp > before then after = p.hp; break end
                    emu.frameadvance()
                end
                if after > before then
                    healed = healed + 1
                    local p = C.party()[target]
                    say(string.format("(%s's %s: %s +%d HP, now %d/%d.)", healerName, moveName, name_of(p.species), after - before, p.hp, p.maxhp))
                    -- (the HP bars animate, then the text waits: B until the
                    -- party list - or, a B too many, the START menu - is back;
                    -- the hooks are left for the loop above)
                    H.partyMenu, H.startMenu = nil, nil
                    for _ = 1, 40 do
                        if H.partyMenu or H.startMenu then break end
                        press("B")
                        frames(10)
                    end
                else
                    say("(" .. moveName .. " didn't take - " .. Screen.text() .. " - stopping.)")
                    closing = true; press("B")
                end
                phase = "user"
                n = n + 120
            elseif not closing then
                target = M.field_target(party, h, share or 1)
                if target and healed < 12 then
                    local opened = false
                    for _ = 1, 4 do
                        cursor_to(h)
                        H.monSub = nil
                        press("A")
                        for _ = 1, 60 do if H.monSub then opened = true; break end; emu.frameadvance() end
                        if opened then break end
                        wait_menu()
                    end
                    if opened then phase = "sub"
                    else say("(The party list didn't take A - closing it.)"); closing = true; press("B") end
                else
                    closing = true; press("B")     -- (done: out of the party menu)
                end
                n = n + 30
            else
                press("B"); n = n + 30
            end
        elseif take("monSub") then
            wait_menu()
            local row = nil
            for k = 1, math.min(r(A.monSubCount), 8) do
                local it = r(A.monSubItems + k - 1)
                if it == MONMENU_MILKDRINK or it == MONMENU_SOFTBOILED then row = k end
            end
            if phase == "sub" and row then
                cursor_to(row); press("A")
                phase = "target"
            else
                if phase == "sub" then say("(No " .. moveName .. " in " .. healerName .. "'s menu - closing.)"); closing = true end
                press("B"); phase = "user"
            end
            n = n + 30
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "B")
        elseif menuFor(Screen.menu_waiting()) > 360 then
            say("(A menu was left waiting in the party - " .. Screen.text() .. " - pressing B.)")
            press("B")
            n = n + 20
        else
            emu.frameadvance()
            n = n + 1
        end
    end
    if not closed then for _ = 1, 4 do press("B"); frames(20) end end
    return healed
end


-- Its ROM hooks only while it's in use (the "PC" hook group - data/memory.lua;
-- the speed check, 2026-11-11: always-on hooks slowed BizHawk's core ~10x).
-- Wrapped here, before anything keeps its own copy of these.
for _, name in ipairs({"use_pc", "order_party", "field_heal"}) do
    local f = M[name]
    M[name] = function(...)
        local mem = M._mem
        if mem and mem.WithHookGroup then return mem.WithHookGroup("PC", f, ...) end
        return f(...)
    end
end

return M
