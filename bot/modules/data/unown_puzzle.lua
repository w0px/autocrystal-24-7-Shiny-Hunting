-- unown_puzzle.lua (lives in modules/data/)
-- The Ruins of Alph's sliding-stone puzzles (engine/games/unown_puzzle.asm):
-- the user, 2026-11-08 - the Kabuto puzzle can be solved before Falkner,
-- and that's what lets Unown appear (letters A-K: the shiny one is an I).
--
-- The board is wPuzzlePieces: 6 x 6 bytes, a cell = row * 6 + column, a
-- piece's number (1-16) or 0. The 16 pieces start scattered on the border;
-- solved, piece n sits at row 1 + (n-1)//4, column 1 + (n-1)%4 (the middle
-- 4 x 4). A on a piece picks it up, A on an empty cell puts it down - no
-- swapping. The cursor moves as UnownPuzzleJumptable says (M.move): the
-- START/CANCEL box under the middle is no cell (31-34), and Left/Right
-- along the bottom row jump across it.
--
-- M.plan(board) and M.path(from, to) are plain functions (tested offline);
-- M.solve() presses the buttons, reading the board and cursor as it goes.

local M = {}

local State
local log = print

M.A = {
    pieces = 0xC6D0,        -- wPuzzlePieces (36 bytes)
    jump = 0xCF63,          -- wJumptableIndex (bit 7: the puzzle is quitting)
    holding = 0xCF64,       -- wHoldingUnownPuzzlePiece
    cursor = 0xCF65,        -- wUnownPuzzleCursorPosition
    held = 0xCF66,          -- wUnownPuzzleHeldPiece
    solved = 0xD0EC,        -- wSolvedUnownPuzzle
    inMenu = 0xFFAA,        -- hInMenu (1 on the puzzle screen)
}

function M.setup(state, logger)
    State = state
    log = logger or print
end

local function is_cell(p) return p >= 0 and p <= 35 and not (p >= 31 and p <= 34) end
local function is_border(p)
    local r, c = p // 6, p % 6
    return is_cell(p) and (r == 0 or r == 5 or c == 0 or c == 5)
end

-- Where piece n belongs.
function M.target(n)
    return (1 + (n - 1) // 4) * 6 + 1 + (n - 1) % 4
end

-- The cursor after pressing dir at p - exactly as the game's d-pad code.
function M.move(p, dir)
    local c = p % 6
    if dir == "Up" then
        if p < 6 then return p end
        return p - 6
    elseif dir == "Down" then
        if p == 25 or p == 26 or p == 27 or p == 28 or p >= 30 then return p end
        return p + 6
    elseif dir == "Left" then
        if c == 0 then return p end
        if p == 35 then return 30 end
        return p - 1
    elseif dir == "Right" then
        if c == 5 then return p end
        if p == 30 then return 35 end
        return p + 1
    end
    return p
end

-- The fewest presses from one cell to another: a list of directions.
local DIRS = {"Up", "Down", "Left", "Right"}
function M.path(from, to)
    if from == to then return {} end
    local prev, queue, head = {[from] = false}, {from}, 1
    while queue[head] do
        local p = queue[head]; head = head + 1
        for _, d in ipairs(DIRS) do
            local q = M.move(p, d)
            if prev[q] == nil then
                prev[q] = {p, d}
                if q == to then
                    local out, k = {}, q
                    while prev[k] do table.insert(out, 1, prev[k][2]); k = prev[k][1] end
                    return out
                end
                queue[#queue + 1] = q
            end
        end
    end
    return nil
end

-- A board that's the puzzle's: pieces 1-16 once each, the rest 0. (Read
-- before the puzzle opens, the same RAM holds other things.)
function M.valid(board, held)
    local seen, n = {}, 0
    for p = 0, 35 do
        local v = board[p]
        if v ~= 0 then
            if v < 1 or v > 16 or seen[v] or not is_cell(p) then return false end
            seen[v] = true; n = n + 1
        end
    end
    if held and held >= 1 and held <= 16 and not seen[held] then n = n + 1 end
    return n == 16
end

function M.is_solved(board)
    for n = 1, 16 do if board[M.target(n)] ~= n then return false end end
    return true
end

-- The moves that solve it: {{from, to}, ...} - each piece n in turn to its
-- place; a wrong piece already there goes out to a free border cell first.
function M.plan(board)
    local b = {}
    for p = 0, 35 do b[p] = board[p] or 0 end
    local moves = {}
    local function free_border()
        for p = 0, 35 do if is_border(p) and b[p] == 0 then return p end end
        return nil
    end
    for n = 1, 16 do
        local t = M.target(n)
        if b[t] ~= n then
            if b[t] ~= 0 then
                local f = free_border()
                if not f then return nil, "no free cell to move a piece out of the way" end
                moves[#moves + 1] = {t, f}
                b[f], b[t] = b[t], 0
            end
            local from
            for p = 0, 35 do if b[p] == n then from = p end end
            if not from then return nil, "piece " .. n .. " isn't on the board" end
            moves[#moves + 1] = {from, t}
            b[t], b[from] = n, 0
        end
    end
    return moves
end

-- ------------------------------------------------------------ in the game

local function r(a) return State.read8(a) end
local function frames(n) for _ = 1, n do emu.frameadvance() end end
local function press(btn, hold)
    for _ = 1, hold or 2 do joypad.set({[btn] = true}); emu.frameadvance() end
    frames(2)
end

function M.board()
    local b = {}
    for p = 0, 35 do b[p] = r(M.A.pieces + p) end
    return b
end

-- The puzzle screen is up (and not quitting).
function M.on_screen()
    if r(M.A.inMenu) ~= 1 or r(M.A.jump) & 0x80 ~= 0 then return false end
    local c = r(M.A.cursor)
    return is_cell(c) and M.valid(M.board(), r(M.A.holding) ~= 0 and r(M.A.held) or nil)
end

-- The cursor to cell p: a press at a time, each checked.
local function cursor_to(p)
    for _ = 1, 30 do
        local cur = r(M.A.cursor)
        if cur == p then return true end
        local path = M.path(cur, p)
        if not path or #path == 0 then return false end
        local want = M.move(cur, path[1])
        press(path[1])
        for _ = 1, 30 do
            if r(M.A.cursor) == want then break end
            emu.frameadvance()
        end
    end
    return r(M.A.cursor) == p
end

-- A, then wait for the piece to be picked up (holding 1) or put down (0).
local function press_a(holding)
    for _ = 1, 3 do
        press("A")
        for _ = 1, 240 do
            if r(M.A.holding) == holding then return true end
            emu.frameadvance()
        end
    end
    return false
end

-- Solve the puzzle on screen. true, or false and why (the caller quits it).
function M.solve(say)
    say = say or log
    -- (a piece in hand from before: put it down on a free border cell)
    if r(M.A.holding) ~= 0 then
        local b = M.board()
        for p = 0, 35 do
            if is_border(p) and b[p] == 0 then
                if not cursor_to(p) or not press_a(0) then return false, "couldn't put down the piece in hand" end
                break
            end
        end
    end
    local moves, why = M.plan(M.board())
    if not moves then return false, why end
    for i, mv in ipairs(moves) do
        local piece = r(M.A.pieces + mv[1])
        if piece == 0 then return false, string.format("move %d: no piece at cell %d", i, mv[1]) end
        if not cursor_to(mv[1]) then return false, "the cursor didn't get to cell " .. mv[1] end
        if not press_a(1) then return false, "couldn't pick up piece " .. piece end
        if not cursor_to(mv[2]) then return false, "the cursor didn't get to cell " .. mv[2] end
        if not press_a(0) then return false, "couldn't put down piece " .. piece end
        if r(M.A.pieces + mv[2]) ~= piece then return false, string.format("piece %d isn't at cell %d", piece, mv[2]) end
    end
    if not M.is_solved(M.board()) then return false, "every piece moved, but it isn't solved" end
    -- (solved: a fanfare, then the game waits for A or B - and quits)
    for _ = 1, 40 do
        if r(M.A.solved) == 1 or r(M.A.inMenu) ~= 1 then return true end
        press("A")
        frames(15)
    end
    return r(M.A.solved) == 1
end

-- Leave the puzzle without solving it (START).
function M.quit()
    for _ = 1, 5 do
        if not M.on_screen() then return end
        press("Start")
        frames(20)
    end
end

return M
