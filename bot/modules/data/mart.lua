-- mart.lua (lives in modules/data/)
-- Shops at a Poke Mart the way a player does it: talk to the clerk, BUY,
-- the item, how many, YES - then QUIT. Called by the walker after healing
-- at a Pokemon Center in a town with a Mart (data/walker.lua).
--
-- What it buys (the user's rules, M.RULES): POTIONs up to 5 in the bag
-- (any potion counts), ANTIDOTEs up to 3, then POKe BALLs with whatever is
-- left - never going under ₽500. Balls alone (stock full) only when it can
-- get at least 10. Prices are the game's (ItemAttributes in
-- battle_data.lua); what the Mart sells is read from it (wCurMartItems)
-- once the list is open, so a Mart without balls just doesn't sell any.
--
-- Each menu is recognised by the game's own routine for it (ROM hooks); the
-- total the game asks for (hMoneyTemp) is checked against ours before YES,
-- and the bag and money are compared before and after for the log.
--
-- M.plan is a plain function on tables, tested offline.

local M = {}

local Screen = require("data.screen")
local D, State, ButtonWait
local log = print

M.RULES = {
    stock = {{"POTION", 5, potions = true}, {"ANTIDOTE", 3}},   -- buy up to this many
    ball = "POKE_BALL",                                        -- then these with the rest
    minBalls = 10,                                             -- ...only balls to buy: at least this many, or none
    floor = 500,                                               -- never under this much money
    -- Under minBalls balls: the balls may go under the floor, and any
    -- number is worth it (the user, 2026-11-08: a shiny with no ball is
    -- lost; with 0 balls and $584 it waited for ~30 of Joey's $64 rematches
    -- to afford 10 over the floor - and later "when we sub 10 balls it's
    -- okay to buy less than 10 at once, also to use the floor": with 2
    -- balls and $1316 it waited for Joey). Potions and Antidotes keep the floor.
    lowBuysAll = true,
}
-- What counts as a potion in the bag (not berries - they're held items).
local POTIONS = {POTION = true, SUPER_POTION = true, HYPER_POTION = true, MAX_POTION = true, FULL_RESTORE = true,
    FRESH_WATER = true, SODA_POP = true, LEMONADE = true, MOOMOO_MILK = true}

local function rom(bank, addr) return bank == 0 and addr or bank * 0x4000 + (addr - 0x4000) end
-- (pokecrystal11.sym; English Crystal 1.0 and 1.1 share them)
local HOOKS = {
    topMenu = rom(0x05, 0x5B6E),      -- StandardMart.TopMenu: BUY / SELL / QUIT
    list = rom(0x05, 0x5CEF),         -- BuyMenuLoop: the list of what's for sale
    qty = rom(0x09, 0x4FF9),          -- Toss_Sell_Loop: "How many?"
    qtyLoop = rom(0x09, 0x4FFE),      -- Toss_Sell_Loop.loop: once per redraw while it's up
    confirm = rom(0x05, 0x5D97),      -- MartConfirmPurchase: "That will be ₽N. OK?"
    quit = rom(0x05, 0x5BA3),         -- StandardMart.Quit: "Please come again!"
}
local A = {
    menuY = 0xCFA9, scroll = 0xD0E4,
    martCount = 0xD0F0, martItems = 0xD0F1,   -- wCurMartCount, wCurMartItems (ids, then 0xFF)
    qty = 0xD10C,                              -- wItemQuantityChange
    total = 0xFFC3,                            -- hMoneyTemp: the price asked, 3 bytes
}

local H = {}

function M.setup(battleData, state, buttonWait, mem, logger)
    D, State, ButtonWait = battleData, state, buttonWait
    M._mem = mem          -- (its hook group switched on around the entry points below)
    log = logger or print
    if mem then
        for name, addr in pairs(HOOKS) do
            mem.RegisterROMHook(addr, function() H[name] = emu.framecount() end, "Mart " .. name, nil, "Mart")
        end
    end
end

local IDS = nil
local function id_of(name)
    if not IDS then IDS = {}; for id, n in pairs(D.items) do IDS[n] = id end end
    return IDS[name]
end

function M.item_name(id, n)
    local s = (D.items[id] or ("item #" .. id)):gsub("_", " "):lower():gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
    if n and n ~= 1 then s = s .. "s" end
    return s
end

-- How many of each the bag has: {[id] = count}, with potions = all potions.
function M.counts(items, balls)
    local have = {potions = 0}
    for id, q in pairs(items) do
        have[id] = (have[id] or 0) + q
        if POTIONS[D.items[id]] then have.potions = have.potions + q end
    end
    have.balls = 0
    for id, q in pairs(balls or {}) do have[id] = (have[id] or 0) + q; have.balls = have.balls + q end
    return have
end

-- Few enough balls that any number is worth a trip, and the floor goes too?
function M.short_of_balls(balls, rules)
    rules = rules or M.RULES
    return rules.lowBuysAll and balls < (rules.minBalls or 1) or false
end

-- What to buy: have (M.counts), money, sells {[id] = price} -> {{id, qty,
-- price}, ...} in the order bought. Stock first, then balls with the rest.
function M.plan(have, money, sells, rules)
    rules = rules or M.RULES
    local budget = money - rules.floor
    local out = {}
    for _, r in ipairs(rules.stock) do
        local id = id_of(r[1])
        local got = r.potions and have.potions or (have[id] or 0)
        local price = sells[id]
        if price and price > 0 and got < r[2] and budget >= price then
            local q = math.min(r[2] - got, budget // price)
            out[#out + 1] = {id, q, price}
            budget = budget - q * price
        end
    end
    -- Balls with the rest - any number when we're buying stock anyway, else
    -- only when it's at least rules.minBalls (no trips for 2 balls).
    local ball = id_of(rules.ball)
    local price = sells[ball]
    local empty = M.short_of_balls(have.balls or 0, rules)
    if empty then budget = budget + (rules.floor or 0) end   -- (under minBalls: the floor too)
    if price and price > 0 and budget >= price then
        local q = math.min(99 - (have[ball] or 0), budget // price)
        if q > 0 and (#out > 0 or empty or q >= (rules.minBalls or 1)) then out[#out + 1] = {ball, q, price} end
    end
    return out
end

function M.describe(list)
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = string.format("%d %s", e[2], M.item_name(e[1], e[2])) end
    return table.concat(t, ", ")
end

-- ------------------------------------------------------------ reading RAM

local function r(a) return State.read8(a) end

local function bag_now()
    local items, balls = {}, {}
    local n = r(0xD892)
    if n > 20 then n = 0 end
    for i = 0, n - 1 do
        local id, q = r(0xD893 + i * 2), r(0xD894 + i * 2)
        items[id] = (items[id] or 0) + q
    end
    balls = State.balls()
    return M.counts(items, balls)
end

-- What the ball the rules buy costs (list price).
function M.ball_price()
    local id = id_of(M.RULES.ball)
    return D.prices[id] and D.prices[id][1] or 200
end

-- Worth a visit? The plan at the game's list prices, as if the Mart sells
-- everything we buy. nil, or the plan.
function M.wants()
    local sells = {}
    for _, r0 in ipairs(M.RULES.stock) do local id = id_of(r0[1]); sells[id] = D.prices[id][1] end
    local ball = id_of(M.RULES.ball)
    sells[ball] = D.prices[ball][1]
    local p = M.plan(bag_now(), State.money(), sells)
    return #p > 0 and p or nil
end

-- What this Mart sells: {[id] = price}, and the list order {id, ...}.
local function for_sale()
    local sells, order = {}, {}
    for i = 0, math.min(r(A.martCount), 20) - 1 do
        local id = r(A.martItems + i)
        if id == 0xFF then break end
        order[#order + 1] = id
        sells[id] = D.prices[id] and D.prices[id][1] or 0
    end
    return sells, order
end

-- ------------------------------------------------------------ driving it

local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end
local function take(name) local f = H[name]; H[name] = nil; return f ~= nil end

local function cursor_to(y)
    for _ = 1, 12 do
        local cy = r(A.menuY)
        if cy == y then return true end
        press(cy < y and "Down" or "Up")
        frames(4)
    end
    return r(A.menuY) == y
end

local function list_to(i)
    for _ = 1, 40 do
        local at = r(A.scroll) + r(A.menuY) - 1
        if at == i then return true end
        press(at < i and "Down" or "Up")
        frames(4)
    end
    return false
end

-- The "How many?" box reads the pad once per redraw (it reprints the price
-- each time, several frames), so a short tap can fall between two reads and
-- never count. Each press: wait until the number really changed.
local function qty_to(q)
    for _ = 1, 60 do
        local now = r(A.qty)
        if now == q then return true end
        local d = q - now
        press(d >= 10 and "Right" or d <= -10 and "Left" or d > 0 and "Up" or "Down")
        for _ = 1, 20 do
            if r(A.qty) ~= now then break end
            emu.frameadvance()
        end
    end
    return r(A.qty) == q
end

-- The "How many?" box has gone (its loop hasn't run for 20 frames).
local function qty_gone()
    return H.qtyLoop == nil or emu.framecount() - H.qtyLoop > 20 or emu.framecount() < H.qtyLoop
end

-- Hold btn until done() (or n frames): for screens that read the pad
-- less than every frame. Then let go.
local function hold_until(btn, done, n)
    for _ = 1, n or 40 do
        if done() then break end
        joypad.set({[btn] = true}); emu.frameadvance()
    end
    emu.frameadvance()
    return done()
end

-- Let frames pass until a menu is waiting for a button (up to n).
local function wait_menu(n)
    for _ = 1, n or 180 do
        if Screen.menu_waiting() then return true end
        emu.frameadvance()
    end
    return false
end

-- Standing at the counter facing the clerk: talk, buy what the plan says,
-- QUIT. opts.say for the log. Returns the list bought ({{id, qty}, ...}).
-- Every menu is answered once it's waiting (Screen.menu_waiting), and a
-- watchdog answers a YES/NO nobody did within 2 seconds, and backs out of
-- any other menu left waiting 6 seconds - logging the screen either way.
function M.buy(opts)
    opts = opts or {}
    local say = opts.say or log
    for k in pairs(H) do H[k] = nil end
    local before, money0 = bag_now(), State.money()
    local todo, current, planned, quitting = nil, nil, false, false
    press("A")
    local n, ended = 0, 0
    local yesNoFor, menuFor = Screen.watch(), Screen.watch()
    local function confirm()
        -- "N ITEM(S) will be $X." then YES/NO: answer once the box is up
        -- (the text prints first - a press during it only hurries the text)
        Screen.wait_yes_no(300)
        local asked = r(A.total) * 65536 + r(A.total + 1) * 256 + r(A.total + 2)
        if current and asked == current[2] * current[3] then
            Screen.answer(true, press)
        else
            say(string.format("(The Mart asks $%d, I worked out $%d - saying no.)", asked, current and current[2] * current[3] or 0))
            Screen.answer(false, press)
        end
        current = nil
    end
    while n < 60 * 120 do
        if take("quit") then
            quitting = true
        elseif take("topMenu") then
            wait_menu()
            if planned and #todo == 0 then
                quitting = true
                cursor_to(3); press("A")          -- QUIT
            elseif n > 60 * 90 then
                cursor_to(3); press("A")
            else
                cursor_to(1); press("A")          -- BUY
            end
            n = n + 30
        elseif take("list") then
            wait_menu()
            local sells, order = for_sale()
            if not planned then
                todo = M.plan(bag_now(), State.money(), sells)
                planned = true
                if #todo == 0 then say("(Nothing here I need, or the money's at the floor.)") end
            end
            current = table.remove(todo, 1)
            local at = nil
            if current then for k, id in ipairs(order) do if id == current[1] and not at then at = k - 1 end end end
            if current and at and list_to(at) then
                press("A")
            else
                current = nil; todo = {}
                press("B")                        -- out of the list ("Anything else?")
            end
            n = n + 40
        elseif take("qty") then
            frames(6)
            if current and qty_to(current[2]) then
                -- A, held until the game takes it: the box goes and "That
                -- will be $X." starts (an A then only hurries that text)
                local ok = false
                for _ = 1, 3 do
                    if hold_until("A", function() return H.confirm ~= nil or qty_gone() end, 40) then ok = true; break end
                    frames(10)
                end
                if not ok then say("(The quantity box didn't take A.)") end
            else
                hold_until("B", function() return false end, 10)
            end
            n = n + 30
        elseif take("confirm") then
            confirm()
            n = n + 30
        elseif ButtonWait.waiting() then
            n = n + ButtonWait.advance(press, "A")
        elseif yesNoFor(Screen.yes_no_waiting()) > 120 then
            -- (watchdog: a YES/NO up 2 seconds and nobody answered it)
            say("(A YES/NO was left waiting - " .. Screen.text() .. " - answering it.)")
            if current then confirm() else Screen.answer(false, press) end
            n = n + 30
        elseif menuFor(Screen.menu_waiting() and not Screen.yes_no()) > 360 then
            -- (watchdog: some menu waiting 6 seconds with nothing done: back out)
            say("(A menu was left waiting - " .. Screen.text() .. " - pressing B.)")
            press("B")
            n = n + 30
        else
            emu.frameadvance()
            n = n + 1
            -- (the clerk's script over: done)
            if not State.script_running() then
                ended = ended + 1
                if ended > 30 and (quitting or n > 300) then break end
            else
                ended = 0
            end
        end
    end
    frames(10)
    -- What changed, for the log.
    local after, money1 = bag_now(), State.money()
    local got = {}
    local ids = {}
    for id in pairs(after) do if type(id) == "number" then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local d = (after[id] or 0) - (before[id] or 0)
        if d > 0 then got[#got + 1] = {id, d} end
    end
    if #got > 0 then
        say(string.format("Bought %s for $%d - $%d left.", M.describe(got), money0 - money1, money1))
    end
    return got
end


-- Its ROM hooks only while it's in use (the "Mart" hook group - data/memory.lua;
-- the speed check, 2026-11-11: always-on hooks slowed BizHawk's core ~10x).
-- Wrapped here, before anything keeps its own copy of these.
for _, name in ipairs({"buy"}) do
    local f = M[name]
    M[name] = function(...)
        local mem = M._mem
        if mem and mem.WithHookGroup then return mem.WithHookGroup("Mart", f, ...) end
        return f(...)
    end
end

return M
