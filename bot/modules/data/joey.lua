-- joey.lua (lives in modules/data/)
-- Money for Poke Balls (the user's rule, 2026-11-08): Youngster Joey on
-- Route 30 is the only trainer whose number the bot takes; his rematches
-- pay (JOEY1 before the Goldenrod flypoint: a Lv 4 Rattata, 4 x 4 x 4 =
-- $64 a win). Every other trainer asking for a number gets NO
-- (data/story.lua: "number" is YES only while M.talking to Joey).
--
-- How the game does it (maps/Route30.asm, engine/phone/scripts/joey.asm):
--   * talking to Joey after he's beaten, with his number not in the phone:
--     he asks for it again, every time - YES registers it (wPhoneList);
--   * when he calls (random calls, about every half hour of play, Joey or
--     another caller) he wants a rematch 2 times in 3: that sets
--     ENGINE_JOEY_READY_FOR_REMATCH (wDailyRematchFlags bit 6 - a daily
--     flag: gone at the next day's reset);
--   * with the flag set, talking to him starts the rematch.
--
-- M.look_after(opts), from the hunt (data/hunt.lua) every few paces:
--   1. Joey's number, the first time (once a session if it didn't work):
--      his calls only come once he's in the phone - so it's got at once,
--      not when the balls are already gone;
--   2. balls under M.LOW_BALLS (99: always topping up), and the money above the floor buys the
--      Mart's minimum of balls (data/mart.lua's rules): to the nearest
--      Pokemon Center - heal, and the Mart next door buys them;
--   3. Joey ready for a rematch and the money short of that: the rematch
--      (the money builds up before the balls run out);
--   4. balls low and nothing to do about it yet: said once, hunting on.
-- Returns nil (hunt on) or why the hunt must stop.

local M = {}

local State, World, Walker, Story, Mart, log
-- (the user, 2026-11-09: "raise it to 99 just to be sure" - a shiny with
-- a hard catch rate must never meet a near-empty bag: stock up whenever the
-- money above the floor buys a lot of 10 and there's room for it, Joey's
-- rematches paying for it)
M.LOW_BALLS = 99
M.TRIES = 3            -- tries for his number a session
M.RETRY_MINUTES = 30   -- between them
local PHONE_JOEY = 15             -- PHONE_YOUNGSTER_JOEY (constants/phone_constants.asm)
local PHONE_LIST = 0xDC7C         -- wPhoneList: contact ids, 0 = empty
local PHONE_SIZE = 10             -- CONTACT_LIST_SIZE
local REMATCH = 0xDC4C            -- wDailyRematchFlags (wdc41 + 11)
local JOEY_BIT = 0x40             -- ENGINE_JOEY_READY_FOR_REMATCH: bit 6
M.talking = false                 -- story.lua's "number" answer: YES only while true
M.wins, M.earned = 0, 0           -- this session
M.on_win = nil                    -- (gained): told after each rematch's prize (the launcher keeps the total)

function M.setup(state, world, walker, story, mart, logger)
    State, World, Walker, Story, Mart = state, world, walker, story, mart
    log = logger or print
end

function M.registered()
    for i = 0, PHONE_SIZE - 1 do
        if State.read8(PHONE_LIST + i) == PHONE_JOEY then return true end
    end
    return false
end

function M.ready() return State.read8(REMATCH) & JOEY_BIT ~= 0 end

-- The bag and the money pile (the user, 2026-11-09: "piles up 99 pokeballs
-- aswell as a big chunk of money so it does not have to farm again for
-- quite some time ... it starts battleing joey once money dropped below a
-- certain treshhold, balls should always be capped"):
--   * balls first: topped up to BAG whenever the money over the floor buys
--     a lot of 10 (not waiting to afford the whole bag - "the bot runs on 10
--     balls until it can afford 89 balls after a few days? I think thats a
--     bottleneck", the user, 2026-11-10);
--   * then the money pile: Joey's rematches from under MONEY_LOW until
--     MONEY_GOAL with a full bag - then none until it drops under MONEY_LOW
--     again ("10k as a pile is too low imo, im thinking about 100k").
M.BAG = 99
M.MONEY_GOAL = 100000
-- (the user, 2026-11-10: "buys balls as soon it drops under 90, uses the
-- money, rebattle joey until over 100k again" - no gap: any dip under the
-- goal, a ball trip included, starts the rematches again)
M.MONEY_LOW = M.MONEY_GOAL

-- The money a ball trip waits for with `balls` in the bag: under the Mart's
-- lot (10), one ball's price (data/mart.lua's lowBuysAll: the floor too);
-- else a lot of 10 over the floor.
function M.trip_money(balls, price)
    local rules = Mart.RULES
    if rules.lowBuysAll and balls < (rules.minBalls or 1) then return price end
    return (rules.floor or 0) + (rules.minBalls or 1) * price
end

-- Money there for a ball trip (trip_money)? -> bool, ball price.
function M.can_buy()
    local price = Mart.ball_price and Mart.ball_price() or 200
    local _, balls = State.balls()
    return State.money() >= M.trip_money(balls, price), price
end

local function talk_to_joey(opts)
    M.talking, Story.acceptNumber = true, true
    local ok, why = Story.talk_to("Route30", "TrainerYoungsterJoey", opts)
    M.talking, Story.acceptNumber = false, false
    return ok, why
end

local SERIOUS = {shiny = true, whiteout = true, data = true, stopped = true}

-- Go buy balls: the nearest Center (heal), its town's Mart.
local function shop(opts, say)
    local w = State.where()
    local flag = State.flag_checker(World.data.flags)
    local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()}, flag)
    if not c then say("(No Pokemon Center to walk to for balls.)"); return nil end
    return Walker.heal_at(c, {}, opts, say)
end

M.state = {}   -- what's been said / tried this session

function M.look_after(opts)
    opts = opts or {}
    local say = opts.say or log
    local _, balls = State.balls()
    local function plural(n) return n == 1 and "" or "s" end
    -- (the game's own record - wPhoneList - said once a session, so the log
    -- shows where things stand)
    if not M.state.statusSaid then
        M.state.statusSaid = true
        say(M.registered() and "Joey's number is in the phone (checked in the game's phone list)."
            or "Joey's number isn't in the phone yet (checked in the game's phone list).")
    end
    -- 1. his number: now, and again every M.RETRY_MINUTES if it didn't work
    -- (at most M.TRIES a session - not a walk to Route 30 every few paces)
    local tries = M.state.joeyTries or 0
    local due = tries == 0 or (tries < M.TRIES and os.time() - (M.state.joeyTriedAt or 0) >= M.RETRY_MINUTES * 60)
    if not M.registered() and due then
        M.state.askedJoey = true
        M.state.joeyTries, M.state.joeyTriedAt = tries + 1, os.time()
        say("Getting Youngster Joey's number on Route 30 - his rematches will pay for Poke Balls.")
        local ok, why = talk_to_joey(opts)
        if not ok and SERIOUS[why] then return why end
        -- (not beaten yet: that talk was his first battle - he only asks for
        -- the number when talked to again; seen in the game, 2026-11-08)
        if not M.registered() then
            ok, why = talk_to_joey(opts)
            if not ok and SERIOUS[why] then return why end
        end
        if M.registered() then say("Joey's number is in the phone - he'll call when he wants a rematch.")
        elseif M.state.joeyTries < M.TRIES then
            say(string.format("(Couldn't get Joey's number: %s - trying again in %d minutes.)", tostring(why or "he didn't ask"), M.RETRY_MINUTES))
        else
            say("(Couldn't get Joey's number after " .. M.TRIES .. " tries: " .. tostring(why or "he didn't ask") .. " - not again this session.)")
        end
    end
    local enough, price = M.can_buy()
    local money = State.money()
    local minB = Mart.RULES.minBalls or 1
    local room = M.BAG - balls
    -- The money pile (see MONEY_GOAL): farming from under MONEY_LOW until
    -- MONEY_GOAL with a full bag.
    if money < M.MONEY_LOW and not M.state.farming then
        M.state.farming = true
        say(string.format("$%d is under $%d: rebattling Joey whenever he calls, until $%d and %d balls.", money, M.MONEY_LOW, M.MONEY_GOAL, M.BAG))
    elseif money >= M.MONEY_GOAL and room < minB and M.state.farming ~= false then
        if M.state.farming then
            say(string.format("$%d and %d balls - no more Joey rematches while it stays at $%d or more.", money, balls, M.MONEY_LOW))
        end
        M.state.farming = false
    end
    -- (a trip that bought nothing isn't made again until the money changes)
    local canShop = enough and M.state.shopFailedAt ~= money
    -- 2. room for a lot of balls, and the money for the trip (M.trip_money):
    -- the Mart (not for fewer than minBalls when the bag's near 99 - no
    -- trip that buys nothing)
    local empty = Mart.RULES.lowBuysAll and balls < minB
    -- (under 90 = room for a lot of 10; the trip then buys as many as the
    -- money does, up to 99)
    if balls < M.LOW_BALLS and canShop and (empty or room >= minB) then
        local n = math.min(room, (money - (empty and 0 or (Mart.RULES.floor or 0))) // price)
        if balls < minB then
            say(string.format("Down to %d ball%s - $%d buys %d%s: off to a Mart.", balls, plural(balls), State.money(),
                n, empty and " (the floor too)" or ""))
        else
            say(string.format("Stocking up: %d balls, and $%d buys %d more - off to a Mart.", balls, State.money(), n))
        end
        local stop = shop(opts, say)
        if stop then return stop end
        local _, after = State.balls()
        if after > balls then M.state.waiting, M.state.shopFailedAt = nil, nil
        else M.state.shopFailedAt = State.money() end
        return nil
    end
    -- 3. Joey's rematch: building the money pile, or short of the balls
    if M.registered() and M.ready() and (M.state.farming or (room >= minB and not enough)) then
        local before = State.money()
        -- (said a few different ways - the user, 2026-11-09)
        local lines = {"Walking to rebattle Joey on Route 30.", "Joey wants a rematch - off to Route 30.",
            "Joey called - heading back to Route 30 for another battle.", "Time for a rematch with Joey on Route 30."}
        say(lines[math.random(#lines)] .. string.format(" (%d ball%s, $%d)", balls, plural(balls), before))
        local ok, why = talk_to_joey(opts)
        if not ok and SERIOUS[why] then return why end
        local gained = State.money() - before
        if gained > 0 then
            M.wins, M.earned = M.wins + 1, M.earned + gained
            if M.on_win then pcall(M.on_win, gained) end
            say(string.format("Beat Joey again: +$%d ($%d now; %d rematch%s, $%d this session).", gained, State.money(),
                M.wins, M.wins == 1 and "" or "es", M.earned))
        elseif M.ready() then
            say("(Joey's rematch didn't happen: " .. tostring(why) .. ".)")
        end
        M.state.waiting = nil
        return nil
    end
    -- 4. low (under the Mart's lot of 10 - not just under LOW_BALLS), nothing to do yet
    if balls >= M.LOW_BALLS or balls >= minB then M.state.waiting = nil; return nil end
    if not M.state.waiting then
        M.state.waiting = true
        if Mart.RULES.lowBuysAll and balls < (Mart.RULES.minBalls or 1) then
            say(string.format("Down to %d ball%s and $%d (a ball is $%d) - hunting on until Joey calls for a rematch.",
                balls, plural(balls), State.money(), price))
        else
            say(string.format("Down to %d ball%s and $%d (a trip waits for $%d) - hunting on until Joey calls for a rematch.",
                balls, plural(balls), State.money(), M.trip_money(balls, price)))
        end
    end
    return nil
end

return M
