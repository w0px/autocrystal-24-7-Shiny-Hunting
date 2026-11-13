-- bag.lua (lives in modules/data/)
-- Uses items from the PACK outside battle, the way a player does it: START,
-- PACK, the Items pocket, the item, USE, the POKéMON. Two uses so far:
--   * curing a status after a battle (cure_party) - poison above all: out
--     of battle it takes 1 HP every 4 steps, and in Gold/Silver/Crystal a
--     POKéMON can faint from it;
--   * potions for a lead that's low on HP (heal_lead) - the walker decides
--     when (data/walker.lua: under 30%, no Pokemon Center close by).
--
-- Which cure: the one made for that status (ANTIDOTE for poison, PARLYZ
-- HEAL, BURN HEAL, ICE HEAL, AWAKENING), else the berry for it, else a FULL
-- HEAL or MIRACLEBERRY. Never a FULL RESTORE or HEAL POWDER (it costs
-- friendship). Which item cures what comes from the game's own table
-- (StatusHealingActions, in battle_data.lua).
-- Which potion: the smallest that fills the POKéMON up, else the biggest
-- there is; never ENERGYPOWDER / ENERGY ROOT (friendship); a FULL RESTORE
-- only when it's all that's left. Amounts from the game's HealingHPAmounts.
--
-- Each menu is recognised by the game's own routine for it (ROM hooks), and
-- each choice is checked before going on: the item picked (wCurItem), the
-- POKéMON's status or HP afterwards. Anything off and it backs out with B -
-- out of battle B only ever closes a menu. Nothing in the bag for it: the
-- menus stay closed.
--
-- M.choose, M.wanted, M.lead and M.heal_choice are plain functions on
-- tables, tested offline.

local M = {}

local Screen = require("data.screen")
local D, State, ButtonWait, Names
local log = print

local function rom(bank, addr) return bank == 0 and addr or bank * 0x4000 + (addr - 0x4000) end
-- (pokecrystal11.sym; English Crystal 1.0 and 1.1 share them)
local HOOKS = {
    startMenu = rom(0x04, 0x6669),    -- StartMenu.GetInput: the START menu takes input
    menuClosed = rom(0x04, 0x6662),   -- StartMenu.ReturnEnd2: it's closed again
    pocket0 = rom(0x04, 0x4067),      -- Pack.ItemsPocketMenu
    pocket1 = rom(0x04, 0x4198),      -- Pack.BallsPocketMenu
    pocket2 = rom(0x04, 0x40A6),      -- Pack.KeyItemsPocketMenu
    pocket3 = rom(0x04, 0x40E8),      -- Pack.TMHMPocketMenu
    submenu = rom(0x04, 0x4235),      -- Pack.build_menu: USE / GIVE / TOSS / QUIT
    partyMenu = rom(0x14, 0x4457),    -- PartyMenuSelect: "Use on which <PKMN>?"
}
local A = {
    menuY = 0xCFA9, menuX = 0xCFAA,
    menuItems = 0xD03E,       -- wMenuItemsList: the START menu's entries (count, then ids)
    scroll = 0xD0E4,          -- wMenuScrollPosition (the pocket's list)
    curItem = 0xD106,         -- wCurItem: what A picked in the pocket
    curPocket = 0xCF65,       -- wCurPocket: 0 Items, 1 Balls, 2 Key Items, 3 TM/HM
    numItems = 0xD892,        -- wNumItems: count, then {id, quantity} pairs
    partyCount = 0xDCD7, partySpecies = 0xDCD8, party = 0xDCDF, partyLen = 0x30,
}
local STARTMENU_PACK = 2      -- STARTMENUITEM_PACK
local EGG = 0xFD
local NEVER = {FULL_RESTORE = true, HEAL_POWDER = true}     -- (as cures)
local BITTER = {ENERGYPOWDER = true, ENERGY_ROOT = true}    -- (as potions: they cost friendship)

local H = {}       -- hook name -> the frame it last ran on
M.warned = {}      -- "species:status" already said to have no cure (said once)

function M.setup(battleData, state, buttonWait, mem, names, logger)
    D, State, ButtonWait, Names = battleData, state, buttonWait, names or {}
    M._mem = mem          -- (its hook group switched on around the entry points below)
    log = logger or print
    if mem then
        for name, addr in pairs(HOOKS) do
            mem.RegisterROMHook(addr, function() H[name] = emu.framecount() end, "Bag " .. name, nil, "Bag")
        end
    end
end

-- ------------------------------------------------------------ the choices

function M.status_name(st)
    if st & 0x07 ~= 0 then return "asleep" end
    if st & 0x08 ~= 0 then return "poisoned" end
    if st & 0x10 ~= 0 then return "burned" end
    if st & 0x20 ~= 0 then return "frozen" end
    if st & 0x40 ~= 0 then return "paralyzed" end
    return "fine"
end

function M.item_name(id)
    local n = D.items[id]
    if not n then return "item #" .. tostring(id) end
    return (n:gsub("_", " "):lower():gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

-- The item to cure status st with, from bag {[id] = count}: the one made
-- for it first (the game's table lists the item before its berry), the
-- cure-alls last. nil if nothing in the bag will do.
function M.choose(st, bag)
    if st == 0 then return nil end
    local all = nil
    for _, c in ipairs(D.cures) do
        local id, mask = c[1], c[2]
        if (bag[id] or 0) > 0 and st & mask ~= 0 and not NEVER[D.items[id]] then
            if mask == 0xFF then all = all or id else return id end
        end
    end
    return all
end

-- Who needs curing: party {{species, hp, status, egg}, ...} -> the first
-- index (1-based) with a status, and its status. skip[i]: gave up on it.
function M.wanted(party, skip)
    for i, m in ipairs(party) do
        if not m.egg and m.hp > 0 and m.status ~= 0 and not (skip and skip[i]) then return i, m.status end
    end
    return nil
end

-- The party member that goes out first in the next battle: the first that
-- isn't fainted or an egg. Its index (1-based), or nil.
function M.lead(party)
    for i, m in ipairs(party) do if not m.egg and m.hp > 0 then return i end end
    return nil
end

-- The potion to give `missing` HP back with, from bag {[id] = count}: the
-- smallest that fills it up, else the biggest there is. A FULL RESTORE
-- only when nothing else is left (it's the only one that also cures).
function M.heal_choice(missing, bag)
    if missing <= 0 then return nil end
    local fill, big, restore = nil, nil, nil
    for _, h in ipairs(D.heals) do
        local id, amount = h[1], h[2]
        local n = D.items[id]
        if (bag[id] or 0) > 0 and not BITTER[n] then
            if n == "FULL_RESTORE" then restore = id
            else
                if amount >= missing and (not fill or amount < fill[2]) then fill = {id, amount} end
                if not big or amount > big[2] then big = {id, amount} end
            end
        end
    end
    return (fill and fill[1]) or (big and big[1]) or restore
end

-- ------------------------------------------------------------ reading RAM

local function r(a) return State.read8(a) end

function M.party()
    local out = {}
    for i = 0, math.min(r(A.partyCount), 6) - 1 do
        local base = A.party + i * A.partyLen
        out[#out + 1] = {species = r(base), status = r(base + 32), hp = r(base + 34) * 256 + r(base + 35),
            maxhp = r(base + 36) * 256 + r(base + 37), egg = r(A.partySpecies + i) == EGG}
    end
    return out
end

-- The Items pocket: list {id, ...} in order, and {[id] = count}.
function M.items()
    local list, bag = {}, {}
    local n = r(A.numItems)
    if n > 20 then n = 0 end
    for i = 0, n - 1 do
        local id, qty = r(A.numItems + 1 + i * 2), r(A.numItems + 2 + i * 2)
        list[#list + 1] = id
        bag[id] = (bag[id] or 0) + qty
    end
    return list, bag
end

-- Whether anything in the bag gives HP back.
function M.has_heals()
    local _, bag = M.items()
    return M.heal_choice(1, bag) ~= nil
end

-- ------------------------------------------------------------ driving it

local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 4 do joypad.set({[btn] = true}); emu.frameadvance() end
    emu.frameadvance()
end

local function cursor_to(y)
    for _ = 1, 12 do
        local cy = r(A.menuY)
        if cy == y then return true end
        press(cy < y and "Down" or "Up")
        frames(4)
    end
    return r(A.menuY) == y
end

-- In a pocket's list: the cursor to entry i (0-based), scrolling as it goes.
local function list_to(i)
    for _ = 1, 40 do
        local at = r(A.scroll) + r(A.menuY) - 1
        if at == i then return true end
        press(at < i and "Down" or "Up")
        frames(4)
    end
    return false
end

local function take(name)
    local f = H[name]; H[name] = nil
    return f ~= nil
end

local function name_of(sp) return Names[sp] or ("#" .. tostring(sp)) end
M.name_of = name_of

-- The menus, for items used on party members one at a time - driven by
-- 1.2.0's tested code (data/potions.lua: Kill mode's "Use potions", run
-- for hours in the user bot): each menu told apart by the menu block the
-- game sets up as it opens, a press repeated only while the same menu is
-- still up, and B until everything's closed at the end. (The hook-driven
-- driver before it got stuck closing the Pack in the game, 2026-11-08.)
-- next_job() -> nil (nothing more to do) or {i = party index (1-based),
-- item, ok = function(mon now) -> it worked, done = text, failed = text,
-- give_up = function(), worked = optional fn() -> the item went through
-- (cures: the status gone; default: the HP went up)}. Call it standing in
-- the overworld (no battle, no script). Returns how many items worked.
local Potions = require("data.potions")
local function ctx_for(worked)
    return {
        read8 = r, read16 = function(a) return r(a) * 256 + r(a + 1) end,
        press = function(b) press(b) end,
        -- (false once a battle has started - nothing more to press then)
        wait = function(n)
            for _ = 1, n do emu.frameadvance(); if State.in_battle() then return false end end
            return true
        end,
        back_out = function()
            for _ = 1, 8 do
                press("B")
                for _ = 1, 20 do emu.frameadvance() end
            end
        end,
        write8 = function(a, v) if State.write8 then State.write8(a, v) end end,
        idle = State.moving and function() return not State.moving() end or nil,
        log = function() end,
        menuItemsAddr = A.menuItems, cursorYAddr = A.menuY, curItemAddr = A.curItem,
        itemsAddr = A.numItems + 1, partyCountAddr = A.partyCount,
        worked = worked,
    }
end

local function use_items(next_job, say)
    local worked, tries, uses = 0, {}, 0
    while uses < 12 do
        local job = next_job()
        if not job then break end
        uses = uses + 1
        tries[job.i] = (tries[job.i] or 0) + 1
        local okUse, why = Potions.use(ctx_for(job.worked), job.item, job.i - 1)
        local m = M.party()[job.i]
        if okUse and m and job.ok(m) then
            worked = worked + 1
            tries[job.i] = 0
            say(job.done)
        else
            if not okUse then say(string.format("(Couldn't use %s: %s.)", M.item_name(job.item), tostring(why))) end
            if tries[job.i] >= 2 then say(job.failed); job.give_up() end
            if why == "a battle started" then break end
        end
    end
    return worked
end

local function said_no_cure(m, say)
    local key = m.species .. ":" .. m.status
    if not M.warned[key] then
        M.warned[key] = true
        say(string.format("%s is %s and there's nothing in the bag to cure it.", name_of(m.species), M.status_name(m.status)))
    end
end

-- Cure everyone who has a status and an item for it. opts.say(text) for
-- the log. Returns how many were cured (0 without opening a menu when
-- nobody needs it or there's nothing to cure them with).
-- opts.only = {[index] = true}: just those.
function M.cure_party(opts)
    opts = opts or {}
    local say = opts.say or log
    local skip = {}
    if opts.only then
        for i = 1, 6 do if not opts.only[i] then skip[i] = true end end
    end
    return use_items(function()
        local party = M.party()
        local _, bag = M.items()
        while true do
            local i, st = M.wanted(party, skip)
            if not i then return nil end
            local m = party[i]
            local item = M.choose(st, bag)
            if item then
                local statusAddr = A.party + (i - 1) * A.partyLen + 32
                return {i = i, item = item,
                    worked = function() return r(statusAddr) & st == 0 end,
                    ok = function(now)
                        if now.status & st ~= 0 then return false end
                        M.warned[m.species .. ":" .. st] = nil
                        return true
                    end,
                    done = string.format("Used %s on %s - no longer %s.", M.item_name(item), name_of(m.species), M.status_name(st)),
                    failed = string.format("Couldn't cure %s with %s - leaving it.", name_of(m.species), M.item_name(item)),
                    give_up = function() skip[i] = true end}
            end
            said_no_cure(m, say)
            skip[i] = true
        end
    end, say)
end

-- Potions on the lead until it has at least `share` of its HP (0.3): the
-- smallest that fills it up each time, else the biggest. Returns how many
-- were used, and whether the lead is up there now.
-- opts.slot: that party slot instead of the lead (the switch-training
-- partner - the user's log, 2026-11-09).
function M.heal_lead(share, opts)
    opts = opts or {}
    local say = opts.say or log
    local gaveUp = false
    local function who(party)
        if opts.slot then
            local m = party[opts.slot]
            if m and not m.egg and m.hp > 0 then return opts.slot end
            return nil
        end
        return M.lead(party)
    end
    local used = use_items(function()
        if gaveUp then return nil end
        local party = M.party()
        local i = who(party)
        if not i then return nil end
        local m = party[i]
        if m.hp >= share * m.maxhp then return nil end
        local _, bag = M.items()
        local item = M.heal_choice(m.maxhp - m.hp, bag)
        if not item then return nil end
        local hp0 = m.hp
        return {i = i, item = item,
            ok = function(now) return now.hp > hp0 end,
            done = string.format("Used %s on %s (HP was %d/%d).", M.item_name(item), name_of(m.species), hp0, m.maxhp),
            failed = string.format("%s gave %s no HP - stopping.", M.item_name(item), name_of(m.species)),
            give_up = function() gaveUp = true end}
    end, say)
    local party = M.party()
    local i = who(party)
    return used, i ~= nil and party[i].hp >= share * party[i].maxhp
end


-- Its ROM hooks only while it's in use (the "Bag" hook group - data/memory.lua;
-- the speed check, 2026-11-11: always-on hooks slowed BizHawk's core ~10x).
-- Wrapped here, before anything keeps its own copy of these.
for _, name in ipairs({"cure_party", "heal_lead"}) do
    local f = M[name]
    M[name] = function(...)
        local mem = M._mem
        if mem and mem.WithHookGroup then return mem.WithHookGroup("Bag", f, ...) end
        return f(...)
    end
end

return M
