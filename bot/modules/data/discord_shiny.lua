-- discord_shiny.lua (lives in data/)
-- The shiny / perfect DV channel's messages (the user, 2026-11-12: the
-- "Boxed" look, mockups in autocrystal-dev/mockups/discord_shiny_mockup_v2.html):
--
--   card 1  the name line (✨ Shiny Gastly! · No.092 · LV 4) over the big
--           animated sprite, centred (data/sprites/animated_discord_big -
--           tools/scale_sprites.ps1)
--   card 2  ONE box as the card's text (the user, 2026-11-12: "card gets
--           kinda long", "all 3 in 1 ... a heading inside", then the result
--           "in that font"): the result first (CAUGHT WITH 3 POKé BALLS /
--           FLED AFTER 6 POKé BALLS / ...), an empty row between sections,
--           INFO (Hidden Power, place, time,
--           level, this species' count, the odds), DVS, and STATS (total
--           encounters, total shinies, unique shinies, since the last
--           shiny), each heading drawn into its divider line, in Discord's
--           ansi colours.
--
-- The stripe: green = caught by autocatch, red = fled / fainted / not
-- caught; gold while it's still being caught.
--
-- A shiny's message goes out the moment it's on screen ("⏳ Catching
-- it...", gold - the ping comes then) and is EDITED when the battle's over
-- (the user, 2026-11-12: "it only sends the notification after the
-- encounter I guess there is no other way" - there is: send now, edit
-- later). Perfect (15/15/15/15) and 0/0/0/0 ones: one message, after the
-- battle.
--
-- Sent through discord_relay.ps1 (the launcher starts it on M.PORT):
-- POST /send?ch=shiny&key=<id>, then /edit with the same key. The webhook
-- is the launcher's "play_discord_shiny" setting; the relay reads it.
--
-- M.build(info) is plain (tested offline); M.send does the HTTP.

local M = {}

M.PORT = 5020
M.CHANNEL = "shiny"
M.http = nil            -- (tests: a stand-in for comm.httpPost)

M.GOLD, M.GREEN, M.RED = 0xF1C40F, 0x3BA55D, 0xED4245
-- data/sprites/spacer_360.png: see-through, 360 x 1 (tools/scale_sprites.ps1
-- makes it) - card 2's picture, so it's as wide as the sprite's card. If
-- it's missing the relay sends the message without it.
M.SPACER = "spacer_360.png"

local ESC = "\27"
-- Discord's ansi colours (```ansi code blocks): on PC; phones show them grey.
local A = {grey = "30", red = "31", green = "32", yellow = "33", blue = "34", pink = "35", cyan = "36", white = "37", bold = "1;37"}
local function c(col, s) return ESC .. "[" .. A[col] .. "m" .. s .. ESC .. "[0m" end

local HP_TYPES = {"FIGHTING", "FLYING", "POISON", "GROUND", "ROCK", "BUG", "GHOST", "STEEL",
    "FIRE", "WATER", "GRASS", "ELECTRIC", "PSYCHIC", "ICE", "DRAGON", "DARK"}
local HP_COLOUR = {FIGHTING = "red", FLYING = "cyan", POISON = "pink", GROUND = "yellow", ROCK = "yellow", BUG = "green",
    GHOST = "pink", STEEL = "white", FIRE = "red", WATER = "blue", GRASS = "green", ELECTRIC = "yellow",
    PSYCHIC = "pink", ICE = "cyan", DRAGON = "blue", DARK = "pink"}

-- Gen 2's Hidden Power: type, power.
function M.hidden_power(atk, def, spe, spc)
    local t = HP_TYPES[4 * (atk % 4) + (def % 4) + 1]
    local v, w, x, y = spc >= 8 and 1 or 0, spe >= 8 and 1 or 0, def >= 8 and 1 or 0, atk >= 8 and 1 or 0
    return t, math.floor((5 * (v + 2 * w + 4 * x + 8 * y) + spc % 4) / 2) + 31
end

-- The HP DV: the low bit of each of the other four.
function M.hp_dv(atk, def, spe, spc) return (atk % 2) * 8 + (def % 2) * 4 + (spe % 2) * 2 + spc % 2 end

function M.commas(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

function M.ordinal(n)
    local t = n % 100
    local suf = (t >= 11 and t <= 13) and "th" or ({"st", "nd", "rd"})[n % 10] or "th"
    return tostring(n) .. suf
end

-- 31 h 05 m / 45 m / 2 d 03 h
function M.duration(secs)
    if not secs or secs < 0 then return nil end
    local m = math.floor(secs / 60)
    if m < 60 then return string.format("%d m", m) end
    local h = math.floor(m / 60)
    if h < 48 then return string.format("%d h %02d m", h, m % 60) end
    return string.format("%d d %02d h", math.floor(h / 24), h % 24)
end

-- A ball's name from its item id: "Poké Ball", "Great Ball", "Level Ball"...
local BALL_NAMES = {[1] = "Master Ball", [2] = "Ultra Ball", [4] = "Great Ball", [5] = "Poké Ball"}
function M.ball_name(id)
    if BALL_NAMES[id] then return BALL_NAMES[id] end
    local ok, D = pcall(require, "data.battle_data")
    local raw = ok and D and D.items and D.items[id]
    if not raw then return "Ball" end
    return (raw:lower():gsub("_", " "):gsub("(%a)(%a*)", function(a, b) return a:upper() .. b end))
end

-- "3 Poké Balls" / "2 Great Balls and 1 Poké Ball" (balls: {[id] = n}).
function M.balls_text(balls)
    local list = {}
    for id, n in pairs(balls or {}) do if n > 0 then list[#list + 1] = {id = id, n = n} end end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end; return a.id < b.id end)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = string.format("%d %s%s", e.n, M.ball_name(e.id), e.n == 1 and "" or "s") end
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1] end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

-- The result line (card 2's title) and the stripe colour.
-- r: {outcome = "pending" | "caught" | "fainted" | "fled" | "lost" | "noballs"
--     | "stopped" | "stuck" | "ran" | "notneeded", balls = {[id] = n}}
function M.result_line(info)
    local r = info.result or {outcome = "pending"}
    local balls = M.balls_text(r.balls)
    local o = r.outcome
    if o == "pending" then return "⏳ Catching it...", M.GOLD end
    if o == "caught" then return "✅ Caught with " .. (balls or "a ball"), M.GREEN end
    local line
    if o == "fainted" then line = balls and ("Fainted after " .. balls) or "Fainted - not caught"
    elseif o == "fled" then line = balls and ("Fled after " .. balls) or "Got away - not caught"
    elseif o == "lost" then line = "Not caught - lost the battle" .. (balls and (" after " .. balls) or "")
    elseif o == "noballs" then line = "Out of balls" .. (balls and (" after " .. balls) or "") .. " - the bot stopped, it's yours"
    elseif o == "stopped" then line = "Not caught - catching is off, the bot stopped"
    elseif o == "stuck" then line = "The battle got stuck - check the game"
    elseif o == "notneeded" then line = string.format("Not caught - %s isn't needed anymore", info.name or "it")
    else line = "Not caught - shinies only" end   -- (fits one line of the box)
    return "❌ " .. line, M.RED
end

-- (the visible width of a line with ansi codes in it)
local function width(s)
    local plain = s:gsub(ESC .. "%[[%d;]*m", "")
    return utf8 and utf8.len(plain) or #plain
end
-- The box: 41 letters wide (BOX inside + its two sides) - what fills a 360px
-- card on Discord (PC: ~8.2px a letter + the code block's 24px; measured on
-- the user's screenshot, 2026-11-12: "make the text boxes 20% bigger and the
-- sprite a little smaller so it's all in line" - 34 letters before, on 400px).
-- Then 37 (2026-11-13): the user's next screenshot measured ~8.4px a letter,
-- and 41 wrapped EVERY row (the right edge on a line of its own - "the card
-- is still giga long"). 37 x 8.4 + 24 = 335px leaves ~3 letters to spare.
local BOX = 35
-- One box of sections, {{title, lines}, ...}: each section's heading drawn
-- into the line above it, in the box's own font (the user, 2026-11-12: "all
-- 3 elements in 1 card ... a heading inside the boxes"):
--   ┌─ INFO ───────┐   ...   ├─ DVS ───────┤   ...   └─────────────┘
local function rule(left, title, right)
    if not title then return c("grey", left .. string.rep("─", BOX) .. right) end
    return c("grey", left .. "─ ") .. c("white", title) .. c("grey", " " .. string.rep("─", BOX - width(title) - 3) .. right)
end
-- (a section's title nil: no heading - the result at the top. An empty row
-- before each next section: room between them, the user, 2026-11-12)
local function boxed(sections)
    local out = {}
    local function row(l) out[#out + 1] = c("grey", "│") .. " " .. l .. string.rep(" ", math.max(0, BOX - 1 - width(l))) .. c("grey", "│") end
    for i, sec in ipairs(sections) do
        if i > 1 then row("") end
        out[#out + 1] = rule(i == 1 and "┌" or "├", sec[1], i == 1 and "┐" or "┤")
        for _, l in ipairs(sec[2]) do row(l) end
    end
    out[#out + 1] = rule("└", nil, "┘")
    return "```ansi\n" .. table.concat(out, "\n") .. "\n```"
end

local TIME_WORD = {MORN = "MORNING", DAY = "DAY", NITE = "NIGHT"}

-- The three sections' lines: INFO, DVS, STATS (M.panel puts them in one box).
-- INFO, in this order (the user, 2026-11-12): place · time · level, TOTAL
-- <SPECIES> MET, Hidden Power at the bottom (the odds row was cut 11-13).
function M.info_lines(info)
    local lines = {}
    local place = (info.place or "?"):upper()
    local tail = {}
    if info.time and TIME_WORD[info.time] then tail[#tail + 1] = TIME_WORD[info.time] end
    if info.level then tail[#tail + 1] = "LV " .. info.level end
    local rest = table.concat(tail, " · ")
    if width(place) + 3 + width(rest) <= BOX - 2 then
        lines[#lines + 1] = c("white", place) .. (rest ~= "" and (" · " .. rest) or "")
    else
        lines[#lines + 1] = c("white", place:sub(1, BOX - 3))
        if rest ~= "" then lines[#lines + 1] = rest end
    end
    local name = (info.name or "?"):upper()
    local count
    if info.kind == "perfect" then count = (info.speciesPerfect or 1) .. " PERFECT"
    elseif info.kind == "zero" then count = (info.speciesZero or 1) .. " AT 0/0/0/0"
    else count = (info.speciesShinies or 1) .. " SHINY" end
    local met = "TOTAL " .. name .. " MET " .. M.commas(info.met or 0)
    if width(met) + 3 + width(count) <= BOX - 2 then
        lines[#lines + 1] = met .. " · " .. c("yellow", count)
    else
        -- (a long name with big numbers: the count on a line of its own)
        lines[#lines + 1] = met
        lines[#lines + 1] = c("yellow", count)
    end
    -- (no ODDS row - cut 2026-11-13 to make the card shorter, the user)
    local t, p = M.hidden_power(info.atk, info.def, info.spe, info.spc)
    lines[#lines + 1] = "HIDDEN POWER  " .. c(HP_COLOUR[t] or "white", t .. " " .. p)
    return lines
end

-- (no HP row: Gen 2 works it out from the other four - the user, 2026-11-12: cut it)
function M.dvs_lines(info)
    local col = info.kind == "shiny" and "yellow" or info.kind == "perfect" and "green" or "grey"
    local rows = {{"ATK", info.atk}, {"DEF", info.def}, {"SPE", info.spe}, {"SPC", info.spc}}
    local lines = {}
    for _, row in ipairs(rows) do
        local v = row[2]
        -- (▇, seven eighths high, not █: the four bars touched and read as one
        -- block - the gap on top of each separates them, the user 2026-11-13)
        lines[#lines + 1] = string.format("%s %s%s %2d", row[1], v > 0 and c(col, string.rep("▇", v)) or "",
            -- (the empty part ▇ too, grey: ░ is a different width from ▇ in
            -- some fonts and the numbers went out of line)
            v < 15 and c("grey", string.rep("▇", 15 - v)) or "", v)
    end
    return lines
end

-- The run's numbers: label left, number right. Since the last shiny: on a
-- shiny's message the encounters this one took (yellow), else the count now.
local function lr(label, value, col)
    return label .. string.rep(" ", math.max(1, BOX - 2 - #label - #value)) .. (col and c(col, value) or value)
end
function M.stats_lines(info)
    return {
        lr("TOTAL ENCOUNTERS", M.commas(info.totalEncounters or 0)),
        lr("TOTAL SHINIES", M.commas(info.totalShinies or 0)),
        lr("UNIQUE SHINIES", M.commas(info.uniqueShinies or 0)),
        lr("SINCE LAST SHINY", M.commas(info.since or 0), info.kind == "shiny" and "yellow" or nil),
    }
end

-- The result, in the box's font (the user, 2026-11-12): upper case the way
-- the game writes it (POKé BALL - string.upper leaves the é), green caught,
-- red not, yellow while catching; no emoji (two letters wide in the box's
-- font: the right edge would be off). Wrapped to the box.
local RESULT_COLOUR = {[M.GREEN] = "green", [M.RED] = "red", [M.GOLD] = "yellow"}
function M.result_lines(info)
    local line, colour = M.result_line(info)
    local text = line:gsub("^[^ ]+ ", ""):upper()
    local col, lines, cur = RESULT_COLOUR[colour] or "white", {}, ""
    for word in text:gmatch("%S+") do
        if cur ~= "" and width(cur) + 1 + width(word) > BOX - 2 then lines[#lines + 1] = cur; cur = word
        else cur = cur == "" and word or (cur .. " " .. word) end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    for i, l in ipairs(lines) do lines[i] = c(col, l) end
    return lines
end

-- The card's text: the three sections in one box. The result sits at the
-- end of INFO, under Hidden Power, an empty row above it (the section break
-- gives the one below) - a shorter card than a section of its own on top
-- (the user, 2026-11-12).
function M.panel(info)
    local infoRows = M.info_lines(info)
    infoRows[#infoRows + 1] = ""
    for _, l in ipairs(M.result_lines(info)) do infoRows[#infoRows + 1] = l end
    return boxed({{"INFO", infoRows}, {"DVS", M.dvs_lines(info)}, {"STATS", M.stats_lines(info)}})
end
-- (one section on its own - the tests)
function M.info_box(info) return boxed({{"INFO", M.info_lines(info)}}) end
function M.dvs_box(info) return boxed({{"DVS", M.dvs_lines(info)}}) end
function M.stats_box(info) return boxed({{"STATS", M.stats_lines(info)}}) end

-- The name line over the sprite.
function M.head_line(info)
    local name = info.name or "?"
    local s
    if info.kind == "perfect" then s = string.format("💯 Perfect %s! 15/15/15/15", name)
    elseif info.kind == "zero" then s = string.format("📉 Zero %s! 0/0/0/0", name)
    else s = string.format("✨ Shiny %s!", name) end
    return string.format("%s · No.%03d · LV %d", s, info.species or 0, info.level or 0)
end

-- JSON
local function esc(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(ch)
        if ch == '"' then return '\\"' elseif ch == "\\" then return "\\\\" elseif ch == "\n" then return "\\n"
        elseif ch == "\r" then return "\\r" elseif ch == "\t" then return "\\t" end
        return string.format("\\u%04x", ch:byte())
    end)
    return s
end
local function str(s) return '"' .. esc(s) .. '"' end

-- The sprite's attachment name (the relay finds the file by it).
function M.sprite_name(info)
    return string.format("big%s_%d.gif", info.kind == "shiny" and "shiny" or "normal", info.species or 0)
end

-- The whole message, as JSON. info: species, name, level, atk, def, spe,
-- spc, kind ("shiny" | "perfect" | "zero"), place, time ("MORN"/"DAY"/
-- "NITE"), met (this species, this one counted), speciesShinies /
-- speciesPerfect / speciesZero, totalEncounters, totalShinies,
-- uniqueShinies (species with one or more), since (a shiny: the encounters
-- it took; else the count since the last shiny now), result, mention
-- ("<@id>"), footer, timestamp (ISO; default now).
function M.build(info)
    local line, colour = M.result_line(info)
    -- (the box is the card's text, not fields: a field always has a title
    -- line - "kinda long", the user, 2026-11-12. Up to 4096 there.)
    local text = M.panel(info)
    local stamp = info.timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ")
    local card1 = string.format('{"color":%d,"author":{"name":%s},"image":{"url":%s}}',
        colour, str(M.head_line(info)), str("attachment://" .. M.sprite_name(info)))
    -- (card 2's picture: M.SPACER, a see-through 360 x 1 strip - Discord makes
    -- a card as wide as its picture, so both cards line up, the user, 2026-11-12;
    -- the text alone made card 2 narrower than the sprite's card)
    -- (no title: the result is the box's first line now)
    local card2 = string.format('{"color":%d,"description":%s,"image":{"url":%s},"footer":{"text":%s},"timestamp":%s}',
        colour, str(text), str("attachment://" .. M.SPACER), str(info.footer or "autocrystal · 24/7 Shiny Hunting"), str(stamp))
    local parts = {}
    if info.mention and info.mention ~= "" then parts[#parts + 1] = '"content":' .. str(info.mention) end
    parts[#parts + 1] = '"embeds":[' .. card1 .. "," .. card2 .. "]"
    -- (a mention pings only who it names - never @everyone by accident)
    parts[#parts + 1] = '"allowed_mentions":{"parse":["users","roles"]}'
    return "{" .. table.concat(parts, ",") .. "}"
end

-- "<@id>" for a user ID, "<@&id>" for "&id" (a role) - the user bot's way.
function M.mention(raw)
    local t = raw and raw:match("^%s*(.-)%s*$") or ""
    if t:match("^&%d+$") then return "<@&" .. t:sub(2) .. ">" end
    if t:match("^%d+$") then return "<@" .. t .. ">" end
    return nil
end

-- Sends (action "send") or edits ("edit") the message with this key.
-- Returns the relay's answer ("sent", "edited", "off: ...", "failed") or nil.
function M.send(action, key, info)
    local post = M.http or (comm and comm.httpPost)
    if not post then return nil end
    local url = string.format("http://127.0.0.1:%d/%s?ch=%s&key=%s", M.PORT, action, M.CHANNEL, key)
    local ok, reply = pcall(post, url, M.build(info))
    return ok and reply or nil
end

return M
