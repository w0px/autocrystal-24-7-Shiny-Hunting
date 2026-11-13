-- screen.lua (lives in modules/data/)
-- What's on the Game Boy screen and whether the game is waiting for us -
-- so the bot reacts to what's there instead of pressing after a fixed
-- number of frames (which goes wrong when text prints slower than expected:
-- a press lands on the text and the YES/NO after it waits forever).
--
--   M.menu_waiting()    a menu (YES/NO, BUY/SELL, party, START...) is waiting
--                       for a button right now: the game runs its menu loop
--                       (Do2DMenuRTCJoypad, 09:4249) every frame until one;
--   M.yes_no()          a YES/NO box is on screen (YES with NO two rows
--                       below it, in the tile map);
--   M.yes_no_waiting()  both: the box is up and taking input;
--   M.wait_yes_no(n)    let frames pass until it is (up to n);
--   M.text()            the screen's text, for the log and for questions.
-- The other modules use these, and each driving loop has a watchdog on
-- them: a YES/NO (or any menu) that nobody answered for a few seconds gets
-- answered/backed out of and logged, rather than the bot standing there.

local M = {}

local State
local charmap = {}
local menuFrame = nil

local MENU_LOOP = 0x09 * 0x4000 + (0x4249 - 0x4000)   -- Do2DMenuRTCJoypad.loopRTC (pokecrystal11.sym)
local TILEMAP = 0xC4A0
local MENU_Y = 0xCFA9

-- ------------------------------------------------------------ the cursor
-- Where the menu cursor is, read off the screen (the user, 2026-11-08: "I
-- always wanna know where the cursor is at"): the game draws it as a tile
-- in the tile map - ▶ ($ED) for the menu taking input, ▷ ($EC) left beside
-- the item a submenu is open for (constants/charmap.asm).
M.CURSOR, M.CURSOR_HOLLOW = 0xED, 0xEC

local function tile(x, y) return State.read8(TILEMAP + y * 20 + x) end
-- The word right of column x on row y (up to two spaces or the edge).
local function word_at(x, y)
    local t = {}
    for k = x, 19 do t[#t + 1] = charmap[tile(k, y)] or " " end
    local s = table.concat(t):gsub("^%s+", "")
    return (s:match("^(.-)%s%s") or s):gsub("%s+$", "")
end

-- The ▶ on screen: {x, y, word} - word: the option it points at - or nil.
function M.cursor()
    if not State then return nil end
    for y = 0, 17 do
        for x = 0, 19 do
            if tile(x, y) == M.CURSOR then return {x = x, y = y, word = word_at(x + 1, y)} end
        end
    end
    return nil
end

-- The row of option `word` in the ▶'s column (the options of the menu it's
-- in), or nil.
local function row_of(cur, word)
    for y = 0, 17 do
        if word_at(cur.x + 1, y):upper() == word:upper() then return y end
    end
    return nil
end

-- Pick option `word` in the menu the ▶ is in: Up/Down until the ▶ is on
-- it (read after every press), A, then check it went through - the ▶ gone
-- from there, or pointing at something else - and A again if not (a press
-- while the menu was still drawing is lost). press(btn): one press.
-- true once picked; false, why.
function M.choose(word, press, tries)
    for _ = 1, 60 do if M.cursor() then break end; emu.frameadvance() end
    local cur = M.cursor()
    if not cur then return false, "no cursor on screen" end
    local target = row_of(cur, word)
    if not target then return false, "no " .. word .. " here (" .. M.text() .. ")" end
    for _ = 1, 12 do
        cur = M.cursor()
        if not cur then return false, "the cursor went away" end
        if cur.y == target then break end
        press(cur.y < target and "Down" or "Up")
        for _ = 1, 20 do local c = M.cursor(); if not c or c.y ~= cur.y then break end; emu.frameadvance() end
    end
    cur = M.cursor()
    if not cur or cur.y ~= target then return false, "couldn't get the cursor onto " .. word end
    for _ = 1, tries or 4 do
        press("A")
        for _ = 1, 40 do
            local c = M.cursor()
            if not c or c.x ~= cur.x or c.y ~= cur.y or c.word:upper() ~= word:upper() then return true end
            emu.frameadvance()
        end
    end
    return false, word .. " didn't take A"
end

function M.setup(state, mem, map)
    State = state
    charmap = map or {}
    if mem then
        mem.RegisterROMHook(MENU_LOOP, function() menuFrame = emu.framecount() end, "Screen menu loop")
    end
end

-- (a hook time ahead of now - a savestate was loaded since - doesn't count)
function M.menu_waiting()
    if menuFrame == nil then return false end
    local d = emu.framecount() - menuFrame
    return d >= 0 and d <= 2
end

local function ch(x, y) return charmap[State.read8(TILEMAP + y * 20 + x)] end

-- A YES/NO box: "YES" with "NO" two rows below, same column. Returns its
-- column and row, or nil.
function M.yes_no()
    if not State then return nil end
    for y = 0, 15 do
        for x = 0, 17 do
            if ch(x, y) == "Y" and ch(x + 1, y) == "E" and ch(x + 2, y) == "S"
                and ch(x, y + 2) == "N" and ch(x + 1, y + 2) == "O" then
                return x, y
            end
        end
    end
    return nil
end

function M.yes_no_waiting() return M.menu_waiting() and M.yes_no() ~= nil end

-- Let frames pass until a YES/NO is up and waiting (the text before it has
-- finished printing). True if it is, false after n frames.
function M.wait_yes_no(n)
    for _ = 1, n or 300 do
        if M.yes_no_waiting() then return true end
        emu.frameadvance()
    end
    return M.yes_no_waiting()
end

-- Answer the YES/NO that's waiting: YES = the cursor on YES, then A; NO = B
-- (B always means NO).
-- Then waits (up to half a second) for the box to go, so it isn't answered
-- twice.
function M.answer(yes, press)
    if yes then
        for _ = 1, State and 4 or 0 do
            if State.read8(MENU_Y) == 1 then break end
            press("Up")
            for _ = 1, 4 do emu.frameadvance() end
        end
        press("A")
    else
        press("B")
    end
    for _ = 1, 30 do
        if not M.yes_no_waiting() then break end
        emu.frameadvance()
    end
end

-- The screen's text (all 18 rows), rows joined with " / ".
function M.text()
    local rows = {}
    for y = 0, 17 do
        local t = {}
        for x = 0, 19 do t[#t + 1] = charmap[State.read8(TILEMAP + y * 20 + x)] or " " end
        local line = table.concat(t):gsub("%s+$", "")
        if line:match("%S") then rows[#rows + 1] = line:gsub("^%s+", "") end
    end
    return table.concat(rows, " / ")
end

-- Counts frames a condition has held, for the watchdogs: w = M.watch();
-- w(cond) -> how many frames in a row cond has been true (0 when false).
function M.watch()
    local since = nil
    return function(cond)
        if not cond then since = nil; return 0 end
        local now = emu.framecount()
        if since == nil or now < since then since = now end
        return now - since
    end
end

return M
