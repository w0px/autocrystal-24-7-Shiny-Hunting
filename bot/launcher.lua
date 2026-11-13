-- launcher.lua (dev) - the playthrough bot's window. The ONLY script you
-- load into BizHawk's Lua Console: Open ROM, the settings, Start, Stop.
-- The bot decides what to do by itself (modules/play.lua: the story,
-- battles, healing, shopping, catching, the team, training) - there's no
-- module to pick any more. The old hunting launcher (module select, static
-- and egg targets, savestate slot) is kept as launcher_hunting.lua.
--
-- BizHawk doesn't allow emu.frameadvance() inside a UI callback, so the
-- buttons only set flags; the bot runs from the main loop at the bottom.
-- Stop is checked between moves (a battle under way is finished first).
--
-- Settings live in modules/data/gui_settings.txt as "play_<name>" (the
-- same file as the theme), saved on Save and on Start.
--
-- The stream overlay (overlay/scene.html): its relay (overlay/
-- overlay_relay.ps1, port 5012 - this dev copy's) is started here, hidden,
-- closing itself with BizHawk; data/overlay_feed.lua is ticked every frame
-- (it posts what changed, at most every few seconds) and gets the bot's
-- checkpoint (goal), training target (next), each wild encounter, and the
-- lines that matter (a checkpoint done, a shiny, a catch, a loss, the end).

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "modules/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

-- BizHawk keeps loaded modules AND globals between the scripts of one
-- session: after the live bot's launcher ran (BizHawk starts it), require()
-- would hand this one the LIVE bot's modules - its stats (the lifetime
-- totals, which this run's encounters would then be added to), its shiny
-- history, its settings. So: every module this folder has is loaded fresh,
-- and the globals the bots share are dropped. (LAUNCHER_TEST_KEEP: the
-- offline test's stand-ins.)
do
    local keep = LAUNCHER_TEST_KEEP or {}
    local root = script_dir:gsub("\\", "/"):lower()
    for name in pairs(package.loaded) do
        if not keep[name] then
            local path = package.searchpath(name, package.path)
            if path and path:gsub("\\", "/"):lower():sub(1, #root) == root then package.loaded[name] = nil end
        end
    end
    for _, g in ipairs({"Gui", "GuiSettings", "Stats", "StatsWindow", "LiveView", "OverlayFeed", "PokemonNames", "ItemNames",
        "AutocrystalCurrentLocation"}) do
        if not keep[g] then _G[g] = nil end
    end
end

-- The speed check (2026-11-11: ~4.5x where the user bot runs ~12x): a file
-- "profile_on.txt" next to this script turns on data/profiler.lua - every
-- minute, where the frame time went, in logs/profile.txt. Started before
-- anything else loads, so every ROM hook and frame is counted.
AutocrystalProfiler = nil
do
    local f = io.open(script_dir .. "profile_on.txt", "r")
    if f then
        f:close()
        local okP, P = pcall(require, "data.profiler")
        if okP and P then AutocrystalProfiler = P; pcall(P.start, script_dir .. "logs/profile.txt") end
    elseif AutocrystalOrigFrameadvance then
        -- (off again after a profiled run in this BizHawk: the real frame
        -- advance back, the line sampler off)
        pcall(function() emu.frameadvance = AutocrystalOrigFrameadvance end)
        pcall(debug.sethook)
    end
end

Gui = require("gui_module")              -- (styling; sets the GuiSettings global)
GuiSettings.load()
Gui.apply_theme(GuiSettings.get_bool("darkmode") == true)
package.loaded["play"] = nil
local Play = require("play")
local settings = Play.load_settings(GuiSettings)

-- ------------------------------------------------------------ the stream overlay
local Paths = require("data.paths")
pcall(Paths.ensure, Paths.LOG_DIR)
OverlayFeed = require("data.overlay_feed")
-- The overlay's totals (TOTAL ENCOUNTERS, shinies, since the last one, per
-- hour): data/stats.lua, kept in modules/data/wild_stats.txt. Every wild
-- encounter of the run counts (on_encounter below).
Stats = require("data.stats")
pcall(Stats.load)
local ShinySavestate = require("data.shiny_savestate")
PokemonNames = PokemonNames or require("data.pokemon_names")
do
    -- (one os.execute, best-effort: a missing script or a failure never stops the launcher;
    -- a relay already running keeps the port and the new one just exits)
    local path = script_dir .. "overlay/overlay_relay.ps1"
    local f = io.open(path, "r")
    if f then
        f:close()
        local cmd = string.format('start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s" ' ..
            '-ExitWhenProcessGone EmuHawk -LogFile "%s" -ListenPort 5012', path, Paths.log_path("overlay_relay_log.txt"))
        pcall(os.execute, cmd)      -- (quietly: the Lua Console stays empty - the user, 2026-11-10)
    end
end
-- The Discord shiny / perfect DV channel (data/discord_shiny.lua): its
-- relay (discord_relay.ps1 - this dev copy's, port 5020, its own; the user
-- bot's is on 5000) started the same way. It reads the webhook from the
-- settings file (play_discord_shiny) for every message.
local DiscordShiny = require("data.discord_shiny")
do
    local path = script_dir .. "discord_relay.ps1"
    local f = io.open(path, "r")
    if f and not LAUNCHER_TEST_KEEP then
        f:close()
        local cmd = string.format('start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s" ' ..
            '-ExitWhenProcessGone EmuHawk -LogFile "%s" -ListenPort %d', path, Paths.log_path("discord_relay_log.txt"), DiscordShiny.PORT)
        pcall(os.execute, cmd)
    elseif f then
        f:close()
    end
end

local W = 560
local form = forms.newform(W, 700, "autocrystal - Play")
forms.setlocation(form, 100, 100)
Gui.style_window(form)

local running = false
local startRequested, stopRequested, saveRequested, goalsRequested = false, false, false, false
local discordTestRequested = false

-- ------------------------------------------------------------ top: buttons, status
local y = 12
Gui.style_header(forms.label(form, "Pokemon Crystal - the bot plays it by itself", 14, y, 400, 18))
y = y + 26

local function rom_loaded()
    local ok, system = pcall(emu.getsystemid)
    return ok and system ~= nil and system ~= "NULL"
end

local statusLabel, progressLabel
local ROM_FILTER = "Game Boy ROMs (*.gbc;*.gb)|*.gbc;*.gb|All Files (*.*)|*.*"
-- (loaded right in the click, like the old launcher: client.openrom() is
-- fine from a form callback, and BizHawk keeps this script running then)
local function on_open_rom()
    if running then return end
    local okPick, path = pcall(forms.openfile, "", GuiSettings.get_text("romdir") or "", ROM_FILTER)
    if not okPick or type(path) ~= "string" or path == "" then return end
    local ok, err = pcall(client.openrom, path)
    if ok and rom_loaded() then
        forms.settext(statusLabel, "Loaded. Check the settings, then Start.")
        local dir = path:match("^(.*)[/\\]")
        if dir then GuiSettings.set("romdir", dir); GuiSettings.save() end
    else
        forms.settext(statusLabel, "Couldn't open that ROM.")
        print("Open ROM: " .. tostring(err))
    end
end

local btnOpenRom = forms.button(form, "Open ROM", on_open_rom, 14, y, 96, 25)
local btnStart = forms.button(form, "Start", function() startRequested = true end, 114, y, 96, 25)
local btnStop = forms.button(form, "Stop", function() stopRequested = true end, 214, y, 96, 25)
local btnGoals = forms.button(form, "Show goals", function() goalsRequested = true end, 314, y, 96, 25)
for _, b in ipairs({btnOpenRom, btnStart, btnStop, btnGoals}) do Gui.style_button(b) end
forms.setproperty(btnStop, "Enabled", false)
y = y + 34
statusLabel = forms.label(form, rom_loaded() and "Ready. Check the settings, then Start." or "Open a ROM (Pokemon Crystal), then Start.", 14, y, W - 40, 18)
y = y + 20
progressLabel = forms.label(form, "", 14, y, W - 40, 18)
-- BizHawk lets Lua use HTTP only when it was started with --url_post /
-- --url_get (start_dev.bat passes them): without them nothing reaches the
-- overlay - say so right away instead of failing quietly.
do
    local okHttp, reply = pcall(comm.httpGet, "http://127.0.0.1:5012/messages?since=999999999")
    if not okHttp or reply == nil then
        forms.settext(progressLabel, "Overlay OFF: start BizHawk with start_dev.bat (it needs --url_post/--url_get).")
    end
end
y = y + 30

-- ------------------------------------------------------------ the settings
local SECTIONS = {mode = "The run", lowHp = "Healing", shop = "Shopping", catch = "Catching", trainMargin = "Training"}
local controls = {}     -- key -> {field, handle}
local LABEL_W, CTRL_X = 330, 360
for _, f in ipairs(Play.FIELDS) do
    if SECTIONS[f.key] then
        y = y + 6
        Gui.style_header(forms.label(form, SECTIONS[f.key], 14, y, 300, 18))
        y = y + 22
    end
    local v = settings[f.key]
    if f.kind == "check" then
        local h = forms.checkbox(form, f.label, 24, y)
        forms.setproperty(h, "Width", W - 60)
        pcall(forms.setproperty, h, "Checked", v == true)
        controls[f.key] = {field = f, handle = h}
        y = y + 26
    elseif f.kind == "choice" then
        forms.label(form, f.label, 24, y + 3, 110, 18)
        local items, current = {}, nil
        for _, c in ipairs(f.choices) do items[#items + 1] = c[2]; if c[1] == v then current = c[2] end end
        local h = forms.dropdown(form, items, 140, y, W - 180, 20)
        Gui.style_dropdown(h)
        -- (forms.dropdown sorts its items: pick ours by its text)
        if current then pcall(forms.settext, h, current) end
        controls[f.key] = {field = f, handle = h}
        y = y + 28
    else
        forms.label(form, f.label, 24, y + 3, LABEL_W, 18)
        local h = forms.textbox(form, tostring(v), 80, 20, "UNSIGNED", CTRL_X, y)
        Gui.style_textbox(h)
        controls[f.key] = {field = f, handle = h}
        y = y + 26
    end
end

-- Discord: the shiny / perfect DV channel's webhook (shown as stars -
-- anyone who sees it can post to the channel) and who to ping. Saved with
-- the settings, in gui_settings.txt (play_discord_shiny, play_discord_ping);
-- the relay re-reads the webhook for every message. Empty = no messages.
y = y + 6
Gui.style_header(forms.label(form, "Discord - shiny / perfect DV channel", 14, y, 300, 18))
y = y + 22
forms.label(form, "Webhook", 24, y + 3, 110, 18)
local txtDiscordHook = forms.textbox(form, GuiSettings.get_text("play_discord_shiny") or "", W - 180, 20, nil, 140, y)
Gui.style_textbox(txtDiscordHook)
pcall(forms.setproperty, txtDiscordHook, "PasswordChar", "*")
y = y + 26
forms.label(form, "Ping (user ID, or & + role ID)", 24, y + 3, 200, 18)
local txtDiscordPing = forms.textbox(form, GuiSettings.get_text("play_discord_ping") or "", 190, 20, nil, 230, y)
Gui.style_textbox(txtDiscordPing)
local btnDiscordTest = forms.button(form, "Send test", function() discordTestRequested = true end, W - 120, y - 2, 90, 24)
Gui.style_button(btnDiscordTest)
y = y + 30
-- (the same check as the user bot's Discord popup: a real Discord webhook only)
local function is_discord_webhook(url)
    local host = url:match("^https://([^/]+)/api/webhooks/%d+/[%w_%-]+$")
    host = host and host:lower()
    return host == "discord.com" or host == "discordapp.com" or host == "ptb.discord.com" or host == "canary.discord.com"
        or host == "ptb.discordapp.com" or host == "canary.discordapp.com"
end
-- Saves the two fields: nil, or what's wrong.
local function save_discord()
    local hook = (forms.gettext(txtDiscordHook) or ""):match("^%s*(.-)%s*$")
    local ping = (forms.gettext(txtDiscordPing) or ""):match("^%s*(.-)%s*$")
    if hook ~= "" and not is_discord_webhook(hook) then return "Discord: that's not a webhook URL (https://discord.com/api/webhooks/...)." end
    if ping ~= "" and not DiscordShiny.mention(ping) then return "Discord ping: a user ID (digits), or & and a role ID." end
    local changed = GuiSettings.set("play_discord_shiny", hook)
    changed = GuiSettings.set("play_discord_ping", ping) or changed
    if changed then GuiSettings.save() end
    return nil
end

y = y + 8
local saveLabel
local btnSave = forms.button(form, "Save settings", function() saveRequested = true end, 14, y, 120, 25)
Gui.style_button(btnSave)
local function set_controls(s)
    for key, c in pairs(controls) do
        local f, v = c.field, s[key]
        if f.kind == "check" then pcall(forms.setproperty, c.handle, "Checked", v == true)
        elseif f.kind == "choice" then
            for _, ch in ipairs(f.choices) do if ch[1] == v then pcall(forms.settext, c.handle, ch[2]) end end
        else forms.settext(c.handle, tostring(v)) end
    end
end
local btnDefaults = forms.button(form, "Defaults", function()
    set_controls(Play.defaults())
    forms.settext(saveLabel, "Defaults put back - Save to keep them.")
end, 140, y, 96, 25)
Gui.style_button(btnDefaults)
saveLabel = forms.label(form, "", 246, y + 5, W - 270, 18)
y = y + 40
forms.setsize(form, W, y + 40)

-- The settings as the controls have them: (table) or (nil, what's wrong).
local function read_controls()
    local s = {}
    for _, f in ipairs(Play.FIELDS) do
        local c = controls[f.key]
        local raw
        if f.kind == "check" then raw = forms.ischecked(c.handle) else raw = forms.gettext(c.handle) end
        local v, why = Play.check(f, raw)
        if v == nil then return nil, why end
        s[f.key] = v
    end
    return s
end

local function set_running(on)
    running = on
    forms.setproperty(btnStart, "Enabled", not on)
    forms.setproperty(btnOpenRom, "Enabled", not on)
    forms.setproperty(btnSave, "Enabled", not on)
    forms.setproperty(btnDefaults, "Enabled", not on)
    forms.setproperty(btnGoals, "Enabled", not on)
    forms.setproperty(btnDiscordTest, "Enabled", not on)
    pcall(forms.setproperty, txtDiscordHook, "Enabled", not on)
    pcall(forms.setproperty, txtDiscordPing, "Enabled", not on)
    forms.setproperty(btnStop, "Enabled", on)
    for _, c in pairs(controls) do pcall(forms.setproperty, c.handle, "Enabled", not on) end
end

-- Each log line: the last one in the status line; the checkpoint and the
-- training target in the progress line; the overlay's goal/next and, for
-- what matters, its chat.
local function clip(text) return #text > 90 and (text:sub(1, 87) .. "...") or text end
-- The overlay's chat narrates what the bot does - every line, except the
-- ones that come with each battle or wild encounter (they'd flood it: the
-- encounter list shows those) and the bracketed notes to myself.
local OVERLAY_SKIP = {"^%(", " uses ", "^Ran from a wild", "^Won the wild", " vs .-%(Lv %d+%)%.$", "^Switch%-training", " on alone %(about ",
    "^Sending out", "^Not fighting the wild", "^Walker build", "^Have: ", "^Training target",
    -- (where it walks and which map it's on: in the log, not on the stream -
    -- the user, 2026-11-09: "I dislike the bot posting its location all the time")
    "^Now on ", "^Walking to ", "^Rolled where to hunt",
    -- (the user, 2026-11-10: "I still dislike some of the stuff the log
    -- shows" - what the info bar shows already, or every few minutes:
    -- the hourly where-and-when reminder, Joey's battle won (his line says
    -- it), the nurse, the training runs, the catcher's sweet spot, the hunt
    -- plan's numbers)
    "^Hunting on .- for %d+ more ", "^Hunting on .- %- staying here", "^Won the trainer battle",
    "^Healed at the counter", "^Running: ", "^Catcher .- %(Lv %d+%): ", "^Hunt plan %- ",
    -- (the user, 2026-11-10: "the log should basically show anything rare
    -- that happens, and call out next steps" - the hunt's count (the run's
    -- total has its milestones), the swaps in a battle, the long to-catch
    -- lists (the info bar counts them))
    "^%d+ encounters so far", "^Switching to ", "^%d+ of %d+ forms; to catch", "^To catch shiny: ",
    -- (Joey's money bookkeeping - "$2512 is under $100000: rebattling Joey
    -- whenever he calls..." and its end; the user, 2026-11-10: "unneeded info")
    "^%$%d+ is under %$%d+: rebattling Joey", "^%$%d+ and %d+ balls %- no more Joey rematches",
    -- (the info bar's NEXT ROTATION says it - the user, 2026-11-11: more
    -- entries in the log)
    "^Next rotation, at "}
-- An encounter count worth a line (the user, 2026-11-10: "only call out
-- milestones like 5k 10k 50k 100k and then 100k steps").
local function count_milestone(n) return n == 5000 or n == 10000 or n == 50000 or (n >= 100000 and n % 100000 == 0) end
local function commas(n) local s = tostring(n); while true do local t, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2"); s = t; if k == 0 then return s end end end
local function ordinal(n) local m = n % 100; local e = (m >= 11 and m <= 13) and "th" or ({"st", "nd", "rd"})[n % 10] or "th"; return commas(n) .. e end
-- Joey's rematches over every session (on_joey keeps them, in
-- play_joey_money.txt): the money, the wins, each win of the last 24 hours.
local joey = {money = 0, wins = nil, recent = {}}
local function joey_since(seconds)
    local sum, now = 0, os.time()
    for _, r in ipairs(joey.recent) do if now - r[1] < seconds then sum = sum + r[2] end end
    return sum
end
-- ...and some shorter there (the log file keeps them whole). Returns the
-- overlay's line, or nil: none.
local lastTeam = nil
local function overlay_text(text)
    -- "Hunting on Route29 (day): 100% of encounters there are still needed -
    -- Sentret, Hoppip. (day-only: ...)" -> "Hunting on Route29 for Sentret, Hoppip."
    local place, rest = text:match("^Hunting on (.-) %(%a+%): %d+%% of encounters there are still needed %- (.*)$")
    -- (just where - the info bar's TARGET lists them; the user, 2026-11-11:
    -- shorter lines, more of them in the log)
    if place then return "Hunting on " .. place .. "." end
    -- "Beat Joey again: +$64 ($2512 now; 48 rematches, $3072 this session)."
    -- -> his win count, then one of five, taking turns (the user, 2026-11-10:
    -- "beat Joey again, xxth win, then either won $xx, or added to the $xx
    -- total from Joey, or accumulated $xx in the last 24h... or that evens
    -- at around $xx a week from Joey, or $xx in the last hour - just
    -- alternate it")
    local won = tonumber(text:match("^Beat Joey again: %+%$(%d+)"))
    if won then
        local nth = joey.wins and (ordinal(joey.wins) .. " win, ") or ""
        local say = {
            function() return string.format("won $%s.", commas(won)) end,
            function() return string.format("$%s more, $%s from Joey in total.", commas(won), commas(joey.money)) end,
            function() return string.format("$%s off Joey in the last 24 hours.", commas(joey_since(86400))) end,
            -- (a week at the pace of the wins kept - up to 24 hours of them,
            -- at least 12: fewer would guess wild; then the total instead)
            function()
                local span = joey.recent[1] and (os.time() - joey.recent[1][1]) or 0
                if span < 43200 then return string.format("$%s more, $%s from Joey in total.", commas(won), commas(joey.money)) end
                local week = math.floor(joey_since(86400) / span * 7 * 86400 / 10 + 0.5) * 10
                return string.format("that evens out at around $%s a week from Joey.", commas(week))
            end,
            function() return string.format("$%s off Joey in the last hour.", commas(joey_since(3600))) end,
        }
        return "Beat Joey again - " .. nth .. say[((joey.wins or 0) % #say) + 1]()
    end
    -- "Joey wants a rematch - off to Route 30. (20 balls, $2448)"
    if text:match("Joey") then
        local short = text:gsub(" %(%d+ balls?, %$%d+%)$", "")
        return short
    end
    -- The team: when who's in it changes, not each level (no levels, no
    -- whys in brackets): "Team: Catcher: Butterfree | Second catcher: Zubat."
    local rest = text:match("^Team: (.*)") or text:match("^Team as of now: (.*)")
    if rest then
        local short = "Team: " .. rest:gsub("%b()", ""):gsub(" at Lv %d+", ""):gsub(" Lv %d+", ""):gsub("  +", " "):gsub(" %.", ".")
        if short == lastTeam then return nil end
        lastTeam = short
        return short
    end
    return text
end
-- The run's log file (1.2.0 keeps its logs too): every line the bot says,
-- with the time, in logs/play_<date>.txt - a new file each day. What the
-- Lua Console showed is still there after a crash or a restart.
local function log_line(text)
    local path = LAUNCHER_LOG_FILE or Paths.log_path("play_" .. os.date("%Y-%m-%d") .. ".txt")
    local f = io.open(path, "a")
    if f then f:write(os.date("%H:%M:%S "), text, "\n"); f:close() end
end
-- A map's name the way people write it: "Route36" -> "Route 36",
-- "SproutTower2F" -> "Sprout Tower 2F", "Route31VioletGate" -> "Route 31
-- Violet Gate" (the user, 2026-11-08: NEXT ROTATION said ROUTE36).
local function spaced_map(name)
    return (tostring(name):gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%u%l)", "%1 %2"))
end
local function on_say(text)
    pcall(log_line, text)
    forms.settext(statusLabel, clip(text))
    if text:match("^Story %d+/%d+") or text:match("^Training target") or text:match("^Not done yet") then
        forms.settext(progressLabel, clip(text))
    end
    local step = text:match("^Story %d+/%d+: (.-)%.?$")
    if step then pcall(OverlayFeed.set_goal, step) end
    local target = text:match("^Training target: (.-)%.?$")
    if target then pcall(OverlayFeed.set_next, "Training: " .. target) end
    -- after the story: the section's hunt is the goal; where / what evolves is next
    local sect = text:match("^The story's done up to .- %- now every shiny of (.-)%.?$")
    if sect then pcall(OverlayFeed.set_goal, "Every shiny of " .. sect) end
    -- (NEXT ROTATION: the hunt's next spot, rolled one ahead - hooks.on_next;
    -- the user, 2026-11-09: "next rotation should be what happens after the
    -- current one". Before the hunt starts, the story's steps fill it.)
    local evo = text:match("^Evolving (.-) %(Lv")
    local into = text:match(" into (.-) %(")
    if evo then pcall(OverlayFeed.set_next, "Evolving " .. evo .. (into and (" into " .. into) or "")) end
    for _, p in ipairs(OVERLAY_SKIP) do
        if text:match(p) then return end
    end
    local shown = overlay_text(text)
    if shown then pcall(OverlayFeed.say, shown) end
end
-- Milestones worth a line on the stream (the user, 2026-11-09: "session
-- infos like randomly talking about something remarkable - longest
-- encounter streak, perfect DVs encountered, a Pokemon met for the
-- 10.000th, 100.000th time"): said once each, as they happen.
-- (one species: 1k, 5k, 10k, 50k, 100k, then every 100k - the user, 2026-11-10)
local function species_milestone(n) return n == 1000 or count_milestone(n) end
-- Now and then a fact about the run (the user, 2026-11-10: "sometimes a
-- random fact like Pokemon xx is the most encountered species, its overall
-- encounter rate is xx% - relative to the total encounters"): every 2-4
-- hours the bot runs, the first 1-2 hours in. (LAUNCHER_FACT_FIRST: tests.)
local FACT_MIN, FACT_MAX = 2 * 3600, 4 * 3600
local nextFact = os.time() + (LAUNCHER_FACT_FIRST or math.random(3600, 7200))
local function fact_most()
    local total = Stats.totalEncounters or 0
    if total < 1000 then return nil end                -- (too few for a fact)
    local best, n = nil, 0
    for sp, c in pairs(Stats.speciesEncounters or {}) do
        if type(c) == "number" and (c > n or (c == n and best and sp < best)) then best, n = sp, c end
    end
    if not best then return nil end
    local name = (PokemonNames and PokemonNames[best]) or ("#" .. tostring(best))
    return string.format("Fun fact: %s is the most encountered species of the run - %s of all %s encounters, %.1f%%.",
        name, commas(n), commas(total), 100 * n / total)
end
-- The run's shiny luck (the user, 2026-11-10: yes to "4 shinies in 40,000
-- encounters - the odds say 4.9"): how many runs would do this badly - or
-- this well (Poisson, 1 in 8,192 each).
local function poisson_cdf(k, mean)
    local term, sum = math.exp(-mean), 0
    for i = 0, k do
        if i > 0 then term = term * mean / i end
        sum = sum + term
    end
    return sum
end
local function fact_luck()
    local total, s = Stats.totalEncounters or 0, Stats.totalShinies or 0
    if total < 8192 then return nil end                -- (not one shiny's worth yet)
    local e = total / 8192
    local head = string.format("Fun fact: %s shin%s in %s encounters - the odds say %.1f", commas(s), s == 1 and "y" or "ies", commas(total), e)
    local p = s < e and poisson_cdf(s, e) or (1 - poisson_cdf(s - 1, e))
    if p > 0.25 then return head .. ": about on the odds." end
    local how = (p < 0.05 and "" or "a bit ") .. (s < e and "unlucky" or "lucky")
    return string.format("%s: only %d%% of runs get %s - %s so far.", head, math.max(1, math.floor(p * 100 + 0.5)),
        s < e and "this few" or "this many", how)
end
local FACTS, factTurn = {fact_most, fact_luck}, 0
local function run_fact()
    for i = 1, #FACTS do
        local f = FACTS[(factTurn + i - 1) % #FACTS + 1]()
        if f then factTurn = factTurn + i; return f end
    end
    return nil
end
-- DV records and the day's numbers, over every session
-- (modules/data/play_records.txt, key=value lines; LAUNCHER_RECORDS_FILE: tests).
local RECORDS_FILE = LAUNCHER_RECORDS_FILE or (script_dir .. "modules/data/play_records.txt")
local rec = {}
do
    local f = io.open(RECORDS_FILE, "r")
    if f then
        for line in f:lines() do local k, v = line:match("^(%w+)=(.*)$"); if k then rec[k] = v end end
        f:close()
    end
end
local function save_records()
    local f = io.open(RECORDS_FILE, "w")
    if not f then return end
    local keys = {}
    for k in pairs(rec) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(k, "=", tostring(rec[k]), "\n") end
    f:close()
end
-- (of the 65,536 DV sets, how many add up to s or more: SUM_AT_LEAST[s])
local SUM_AT_LEAST = {}
do
    local ways = {[0] = 1}
    for _ = 1, 4 do
        local nxt = {}
        for s, w in pairs(ways) do for d = 0, 15 do nxt[s + d] = (nxt[s + d] or 0) + w end end
        ways = nxt
    end
    local acc = 0
    for s = 60, 0, -1 do acc = acc + (ways[s] or 0); SUM_AT_LEAST[s] = acc end
    SUM_AT_LEAST[61] = 0
end
-- (a new record is said only this rare: 56+ or 4- of 60, about 1 in 936)
local RECORD_HIGH, RECORD_LOW = 56, 4
-- Anything rare, with its odds (the user, 2026-11-10: "call out remarkable
-- encounters like perfect DVs and perfect negative, the odds like 1 in xxx,
-- streaks of the same Pokemon with the odds - basically everything rare").
-- Gen 2: a wild one is shiny with Defense, Speed and Special DVs of 10 and
-- an Attack DV of 2, 3, 6, 7, 10, 11, 14 or 15 - 1 in 8,192.
local SHINY_ODDS = 8192
local SHINY_ATK = {[2] = true, [3] = true, [6] = true, [7] = true, [10] = true, [11] = true, [14] = true, [15] = true}
local STREAK_STEPS = {1000, 10000, 100000, 1000000}           -- a streak is said as its odds pass each
local DROUGHT_STEPS = {10, 100, 1000}                          -- no shiny for this long: 1 in 10, 100, 1000 hunts
local LUCK_ODDS = 20                                           -- a shiny this soon after the last: 1 in 20 or rarer
local SPECIES_DRY_PCT = {20, 10, 5, 1, 0.1}                    -- one species never shiny: said as its chance passes each
-- (one species' shinies: the 5th, 10th, 20th, 30th... - the user, 2026-11-10)
local function shiny_milestone(n) return n == 5 or n == 10 or (n >= 20 and n % 10 == 0) end
local PIN_SHINY, PIN_DVS = 2, 1                                -- the overlay's pinned news (a shiny outranks DVs)
local streak = {species = nil, n = 0, odds = 1, said = 0}
local function one_in(p) return commas(math.floor(1 / p + 0.5)) end
-- (no shiny in n encounters: this likely)
local function dry(n) return (1 - 1 / SHINY_ODDS) ^ n end
-- (the % of this species where the bot is now, from the overlay's encounter table)
local function odds_here(species)
    local ok, p = pcall(OverlayFeed.odds_here, species)
    return ok and p or nil
end
local function milestones(species, atk, def, spe, spc, shiny)
    local name = (PokemonNames and PokemonNames[species]) or ("#" .. tostring(species))
    local total = Stats.totalEncounters or 0
    if count_milestone(total) then on_say(string.format("%s total encounters reached!", commas(total))) end
    local okC, c = pcall(Stats.species_encounter_count, species)
    if okC and c and species_milestone(c) then on_say(string.format("The %s wild %s of the run!", ordinal(c), name)) end
    -- (a fact now and then)
    if os.time() >= nextFact then
        local okF, f = pcall(run_fact)
        if okF and f then on_say(f); nextFact = os.time() + math.random(FACT_MIN, FACT_MAX) end
    end
    -- The DVs
    local dvs = string.format("%d/%d/%d/%d", atk or 0, def or 0, spe or 0, spc or 0)
    if atk == 15 and def == 15 and spe == 15 and spc == 15 then
        local t = string.format("Perfect %s! 15/15/15/15 - 1 in 65,536!", name)
        on_say(t); pcall(OverlayFeed.pin, t, PIN_DVS, species)
    elseif atk == 0 and def == 0 and spe == 0 and spc == 0 then
        local t = string.format("The weakest %s there is! 0/0/0/0 - 1 in 65,536!", name)
        on_say(t); pcall(OverlayFeed.pin, t, PIN_DVS, species)
    elseif atk and atk == def and def == spe and spe == spc then
        -- (the other 14 of the 16 four-of-a-kinds)
        on_say(string.format("%s %s - four of a kind, 1 in %s!", name, dvs, one_in(14 / 65536)))
    elseif not shiny and def == 10 and spe == 10 and spc == 10 and atk and not SHINY_ATK[atk] then
        on_say(string.format("Almost shiny! %s %s - only its Attack was off, 1 in %s.", name, dvs, one_in(1 / SHINY_ODDS)))
    end
    -- DV records of the run, highest and lowest sum (the user, 2026-11-10):
    -- said when one this rare is beaten (perfect and 0/0/0/0 have their own line)
    if atk and def and spe and spc then
        local sum, changed = atk + def + spe + spc, false
        local hi, lo = tonumber(rec.high), tonumber(rec.low)
        if not hi or sum > hi then
            rec.high, changed = sum, true
            if hi and sum >= RECORD_HIGH and sum < 60 then
                on_say(string.format("Record high DVs: %s %s - %d of 60, 1 in %s!",
                    name, dvs, sum, one_in(SUM_AT_LEAST[sum] / 65536)))
            end
        end
        if not lo or sum < lo then
            rec.low, changed = sum, true
            if lo and sum <= RECORD_LOW and sum > 0 then
                on_say(string.format("Record low DVs: %s %s - %d of 60, 1 in %s!",
                    name, dvs, sum, one_in((65536 - SUM_AT_LEAST[sum + 1]) / 65536)))
            end
        end
        if changed then save_records() end
    end
    -- The same species in a row: said live, each time its odds pass 1 in
    -- 1,000, 10,000, ... (a 50% Pidgey: 11 in a row; a 5% one: 4)
    if species == streak.species then
        streak.n = streak.n + 1
        local p = odds_here(species)
        if p and p > 0 then streak.odds = streak.odds * math.min(1, p / 100) else streak.odds = 1 end
        local step = STREAK_STEPS[streak.said + 1]
        if step and streak.odds > 0 and 1 / streak.odds >= step then
            while STREAK_STEPS[streak.said + 1] and 1 / streak.odds >= STREAK_STEPS[streak.said + 1] do streak.said = streak.said + 1 end
            on_say(string.format("%d %s in a row - 1 in %s!", streak.n, name, one_in(streak.odds)))
        end
        -- (the day's longest, for the recap)
        if streak.n > (tonumber(rec.dayStreak) or 0) then
            rec.dayStreak, rec.dayStreakName = streak.n, name
            rec.dayStreakOdds = (streak.odds < 1 and streak.odds > 0) and one_in(streak.odds) or ""
            save_records()
        end
    else
        streak.species, streak.n, streak.odds, streak.said = species, 1, 1, 0
    end
    -- No shiny for a long time: as it passes 1 in 10, 100, 1,000 hunts
    local since = Stats.encountersSinceShiny or 0
    if not shiny then
        for _, k in ipairs(DROUGHT_STEPS) do
            if dry(since) <= 1 / k and dry(since - 1) > 1 / k then
                on_say(string.format("%s encounters without a shiny - only 1 in %s hunts go this long.", commas(since), commas(k)))
            end
        end
    elseif since > 0 and 1 - dry(since) <= 1 / LUCK_ODDS then
        -- (a shiny soon after the last: since counts this one too)
        on_say(string.format("A shiny only %s encounters after the last one - 1 in %s luck!", commas(since), one_in(1 - dry(since))))
    end
    -- One species met a long time and never shiny (the user, 2026-11-10:
    -- "16k Phanpy encounters, no shiny - this is a xx% chance"): as its
    -- chance passes 20%, 10%, 5%, 1%, 0.1%. (Only species never shiny yet:
    -- the stats don't keep each species' count since its last shiny.)
    local okS, sc = pcall(Stats.species_shiny_count, species)
    if not shiny and okS and sc == 0 and okC and c then
        for _, p in ipairs(SPECIES_DRY_PCT) do
            if dry(c) <= p / 100 and dry(c - 1) > p / 100 then
                on_say(string.format("%s %s and no shiny yet - a %s%% chance to go this long.",
                    commas(c), name, p >= 1 and string.format("%d", p) or string.format("%.1f", p)))
            end
        end
    end
end
-- The day's recap, after midnight (the user, 2026-11-10: yes to "Yesterday:
-- 3,612 encounters, 1 shiny, $768 from Joey"): the day's start kept in the
-- records file, so a restart in the day doesn't lose it.
local function day_start()
    rec.day, rec.dayTotal, rec.dayShinies = os.date("%Y-%m-%d"), Stats.totalEncounters or 0, Stats.totalShinies or 0
    rec.dayJoey, rec.dayNames = joey.money, ""
    rec.dayStreak, rec.dayStreakName, rec.dayStreakOdds = 0, "", ""
    save_records()
end
local function day_check()
    if not rec.day then day_start(); return end
    if rec.day == os.date("%Y-%m-%d") then return end
    local enc = (Stats.totalEncounters or 0) - (tonumber(rec.dayTotal) or 0)
    local sh = (Stats.totalShinies or 0) - (tonumber(rec.dayShinies) or 0)
    local money = joey.money - (tonumber(rec.dayJoey) or 0)
    local y, m, d = rec.day:match("^(%d+)-(%d+)-(%d+)$")
    local yesterday = os.date("%Y-%m-%d", os.time() - 86400) == rec.day
    local when = yesterday and "Yesterday" or (y and os.date("%A %B %d", os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})) or rec.day)
    local shinyText = sh <= 0 and "no shiny" or string.format("%d shin%s (%s)", sh, sh == 1 and "y" or "ies", (rec.dayNames or ""):gsub(",", ", "))
    -- (the day's longest streak, with its odds - the user, 2026-11-11)
    local n = tonumber(rec.dayStreak) or 0
    local streakText = ""
    if n >= 3 and (rec.dayStreakName or "") ~= "" then
        streakText = string.format(", longest streak %d %s in a row%s", n, rec.dayStreakName,
            (rec.dayStreakOdds or "") ~= "" and (" (1 in " .. rec.dayStreakOdds .. ")") or "")
    end
    if enc > 0 then
        on_say(string.format("%s%s: %s encounters, %s, $%s from Joey%s.", when, yesterday and "'s recap" or " recap", commas(enc), shinyText,
            commas(math.max(0, money)), streakText))
    end
    day_start()
end
-- Pokerus (the user, 2026-11-10: yes): the party's Pokerus byte (party
-- struct +$1C: strain, days left), read after each battle. A new case:
-- said and pinned; the game's odds - 3 in 65,536 per won battle, only
-- once the player has reached Goldenrod, only with nobody infected; it
-- then spreads 1 in 3 per won battle to a neighbour in the party.
local pkrsKnown = nil          -- (the infected ones seen: species + DVs; nil - not looked yet)
local function pokerus_check()
    local ok, GS = pcall(require, "data.game_state")
    if not (ok and GS and GS.read8 and GS.ADDR) then return end
    local A = GS.ADDR
    local n = GS.read8(A.partyCount)
    if not n or n > 6 then return end
    local now, any = {}, false
    for i = 0, n - 1 do
        local base = A.partyMon1 + i * A.partyMonLength
        local b = GS.read8(base + 0x1C) or 0
        if b % 16 > 0 then
            local sp = GS.read8(base)
            now[#now + 1] = {key = sp .. ":" .. (GS.read8(base + 0x15) or 0) .. ":" .. (GS.read8(base + 0x16) or 0), species = sp}
        end
    end
    if pkrsKnown == nil then                    -- (what the party has at the start: not news)
        pkrsKnown = {}
        for _, m in ipairs(now) do pkrsKnown[m.key] = true end
        return
    end
    local hadAny = next(pkrsKnown) ~= nil
    for _, m in ipairs(now) do
        if not pkrsKnown[m.key] then
            pkrsKnown[m.key] = true
            local nm = (PokemonNames and PokemonNames[m.species]) or ("#" .. tostring(m.species))
            if hadAny then
                on_say(string.format("The Pokerus spread to %s - 1 in 3 per won battle.", nm))
            else
                local t = string.format("Pokerus! %s caught it - 3 in 65,536 per won battle (1 in 21,845)!", nm)
                on_say(t); pcall(OverlayFeed.pin, t, PIN_DVS, m.species)
            end
            hadAny = true
        end
    end
end
-- ------------------------------------------------ Discord: the shiny / perfect DV channel
-- (data/discord_shiny.lua - the user's "Boxed" look, 2026-11-12.) A shiny:
-- its message goes out at once ("Catching it...") and is edited with the
-- result when the battle's over (on_catch_result). A perfect / 0-0-0-0
-- one: one message once its battle's over - its own catch result, else
-- the next thing that happens after it (the walk on, the next encounter):
-- the bot ran from it. Nothing without a webhook (play_discord_shiny).
local discordShiny, discordDv = nil, nil      -- {key, info} waiting for their result
local function discord_on() return (GuiSettings.get_text("play_discord_shiny") or "") ~= "" end
local function discord_totals(info)
    info.met = Stats.species_encounter_count(info.species)
    info.speciesShinies = Stats.species_shiny_count(info.species)
    info.speciesPerfect = Stats.species_perfect_count(info.species)
    info.speciesZero = Stats.species_perfect_negative_count(info.species)
    info.totalEncounters, info.totalShinies = Stats.totalEncounters, Stats.totalShinies
    local p, z = 0, 0
    for _, n in pairs(Stats.speciesPerfect or {}) do p = p + n end
    for _, n in pairs(Stats.speciesPerfectNegative or {}) do z = z + n end
    info.runPerfect, info.runZero = p, z
    local u = 0
    for _, n in pairs(Stats.speciesShinies or {}) do if n > 0 then u = u + 1 end end
    info.uniqueShinies = u
    -- (since the last shiny: a shiny's own count is set when it's met - Stats
    -- starts again from 0 then; a perfect / 0-0-0-0 one: the count now)
    if info.kind ~= "shiny" then info.since = Stats.encountersSinceShiny end
end
local function discord_info(species, level, atk, def, spe, spc, kind)
    local info = {species = species, name = (PokemonNames and PokemonNames[species]) or ("#" .. tostring(species)),
        level = level, atk = atk or 0, def = def or 0, spe = spe or 0, spc = spc or 0, kind = kind,
        place = AutocrystalCurrentLocation, mention = DiscordShiny.mention(GuiSettings.get_text("play_discord_ping"))}
    -- (perfect / 0-0-0-0 DVs ping their own role when the server setup saved
    -- one - discord-server\setup_server.py writes play_discord_ping_dv)
    local dvPing = GuiSettings.get_text("play_discord_ping_dv") or ""
    if kind ~= "shiny" and dvPing ~= "" then info.mention = DiscordShiny.mention(dvPing) end
    pcall(function() info.time = require("data.game_state").time_of_day() end)
    pcall(discord_totals, info)
    return info
end
local function discord_send(action, key, info)
    local reply = DiscordShiny.send(action, key, info)
    pcall(log_line, string.format("(Discord: %s %s - %s.)", action, key, tostring(reply or "the relay didn't answer")))
    return reply
end
-- The perfect / 0-0-0-0 one's message, now its battle's over.
local function discord_dv_done(outcome, balls)
    if not discordDv then return end
    local d = discordDv
    discordDv = nil
    d.info.result = {outcome = outcome, balls = balls}
    discord_send("send", d.key, d.info)
end
local function on_catch_result(res)
    if type(res) ~= "table" then return end
    if res.shiny and discordShiny and discordShiny.info.species == res.species then
        local d = discordShiny
        discordShiny = nil
        d.info.result = {outcome = res.outcome, balls = res.balls}
        pcall(discord_totals, d.info)
        discord_send("edit", d.key, d.info)
    elseif not res.shiny and discordDv and discordDv.info.species == res.species then
        discord_dv_done(res.outcome, res.balls)
    end
end
-- (after the encounter's own numbers are in: Stats has counted it)
local function discord_encounter(species, level, atk, def, spe, spc, shiny, phase, prevShinyTime)
    if not discord_on() then return end
    local kind = shiny and "shiny"
        or (atk == 15 and def == 15 and spe == 15 and spc == 15) and "perfect"
        or (atk == 0 and def == 0 and spe == 0 and spc == 0) and "zero" or nil
    if not kind then return end
    local info = discord_info(species, level, atk, def, spe, spc, kind)
    local key = string.format("%s%d_%d", kind, os.time(), species)
    if kind == "shiny" then
        info.phase, info.since = phase, phase
        info.phaseSecs = prevShinyTime and (os.time() - prevShinyTime) or nil
        info.result = {outcome = "pending"}
        discordShiny = {key = key, info = info}
        discord_send("send", key, info)
    else
        discordDv = {key = key, info = info}
    end
end

local function on_encounter(species, level, atk, def, spe, spc, shiny)
    pcall(day_check)
    pcall(pokerus_check)                        -- (the last battle's end: Pokerus is rolled then)
    pcall(discord_dv_done, "ran")               -- (the last one's battle is over: ran from it)
    pcall(OverlayFeed.note_encounter, species, atk, def, spe, spc, shiny, nil)
    -- (the real shininess: the testing switch doesn't count regular ones as shinies here)
    pcall(Stats.record_encounter, species, (atk or 0) * 16 + (def or 0), (spe or 0) * 16 + (spc or 0))
    pcall(milestones, species, atk, def, spe, spc, shiny)
    -- (for the Discord message: the encounters this shiny took, and when the last one was)
    local phase, prevShinyTime = Stats.encountersSinceShiny, nil
    pcall(function()
        local H = require("data.shiny_history")
        if not H.loaded then H.load() end
        prevShinyTime = H.entries[1] and H.entries[1].time
    end)
    if shiny then
        -- (the big news: pinned at the top of the overlay's log for 8 hours (OverlayFeed.PIN_HOURS))
        local sname = (PokemonNames and PokemonNames[species]) or ("#" .. tostring(species))
        pcall(OverlayFeed.pin, string.format("A shiny %s! DVs %d/%d/%d/%d.", sname, atk or 0, def or 0, spe or 0, spc or 0), PIN_SHINY, species)
        local before = Stats.lastShinySpeciesId
        pcall(Stats.record_shiny, species)
        local okN, nShiny = pcall(Stats.species_shiny_count, species)
        if okN and type(nShiny) == "number" and shiny_milestone(nShiny) then
            on_say(string.format("That's the %s shiny %s of the run!", ordinal(nShiny), sname))
        end
        -- (the same species twice running - the user, 2026-11-10: yes)
        if before == species then on_say(string.format("Two shiny %s in a row!", sname)) end
        -- (the day's recap names them)
        if rec.day then
            rec.dayNames = (rec.dayNames ~= nil and rec.dayNames ~= "") and (rec.dayNames .. "," .. sname) or sname
            pcall(save_records)
        end
        -- A savestate the moment a (real) shiny is on screen - insurance
        -- against a crash or the emulator, never for retries: in
        -- autosaves/shiny_<NAME>_<date>.State (1.2.0's shiny savestate).
        local name = (PokemonNames and PokemonNames[species]) or ("#" .. tostring(species))
        local okSave, path = pcall(ShinySavestate.save, name)
        on_say(okSave and path and ("(Shiny savestate: " .. path:match("[^/\\]+$") .. ".)") or "(Couldn't save the shiny savestate.)")
    end
    pcall(discord_encounter, species, level, atk, def, spe, spc, shiny, phase, prevShinyTime)
end

-- Autosaves (1.2.0's Kill mode keeps them too): every AUTOSAVE_MINUTES of
-- running, between moves on the map (data/walker.lua's on_walk), a
-- savestate in autosaves/ - two taking turns (play_autosave_1/_2.State),
-- so a bad one never leaves you without the one before. For a crash or an
-- emulator problem - not for retries.
local AUTOSAVE_MINUTES = LAUNCHER_AUTOSAVE_MINUTES or 30
local lastAutosave, autosaveSlot = os.time(), 1
local function on_walk()
    pcall(discord_dv_done, "ran")               -- (a perfect / 0-0-0-0 one's battle is over)
    if os.time() - lastAutosave < AUTOSAVE_MINUTES * 60 then return end
    lastAutosave = os.time()
    local file = "play_autosave_" .. autosaveSlot .. ".State"
    local path = LAUNCHER_AUTOSAVE_DIR and (LAUNCHER_AUTOSAVE_DIR .. file) or Paths.autosave_path(file)
    local ok = false
    pcall(function() ok = savestate.save(path, true) end)
    if not ok then local f = io.open(path, "rb"); if f then f:close(); ok = true end end
    on_say(ok and string.format("(Autosaved: %s.)", file) or "(Couldn't autosave.)")
    autosaveSlot = 3 - autosaveSlot
end
-- The overlay's numbers and clock, every frame (cheap: it posts only what
-- changed, at most every few seconds) - also while the bot runs, which
-- blocks the main loop below.
-- The clock, what lives here and the place: the Game Assistant's readers
-- (live_view.lua, its window stays shut) and the map's name.
LiveView = require("live_view")
local LocationNames = require("data.location_names")
local placeTick = 0
local function update_place()
    placeTick = placeTick + 1
    if placeTick % 30 ~= 0 then return end
    if emu.getsystemid() == "NULL" or memory.readbyte(0x141) ~= 0x54 then AutocrystalCurrentLocation = nil; return end
    local wram = require("data.frame_search").wram
    AutocrystalCurrentLocation = LocationNames[wram(0xDCB5) .. ":" .. wram(0xDCB6)]
end
-- RUNTIME on the overlay: how long the bot has run (Start to Stop), over
-- every session, kept in modules/data/play_runtime.txt (seconds). Delete
-- that file to start it from 0 again.
local RUNTIME_FILE = LAUNCHER_RUNTIME_FILE or (script_dir .. "modules/data/play_runtime.txt")
local runtime, runtimeAt, runtimeSaved, runtimeWritten = 0, nil, os.time(), nil
do
    local f = io.open(RUNTIME_FILE, "r")
    if f then runtime = math.max(0, math.floor(tonumber(f:read("l") or "") or 0)); f:close() end
    runtimeWritten = runtime
end
local function save_runtime()
    if runtime == runtimeWritten then return end
    local f = io.open(RUNTIME_FILE, "w")
    if f then f:write(tostring(runtime), "\n"); f:close(); runtimeWritten = runtime end
end
local function update_runtime()
    local now = os.time()
    if running then
        if runtimeAt then runtime = runtime + (now - runtimeAt) end
        runtimeAt = now
    elseif runtimeAt then
        runtimeAt = nil
        save_runtime()                    -- (stopped: saved straight away)
    end
    if now - runtimeSaved >= 30 then runtimeSaved = now; save_runtime() end
    OverlayFeed.runtime = runtime
end
-- MONEY FROM JOEY on the overlay: what his rematches paid, over every
-- session, kept in modules/data/play_joey_money.txt: the money, then the
-- wins, then each win of the last 24 hours ("time amount"). Delete that
-- file to start it from 0 again.
local JOEY_FILE = LAUNCHER_JOEY_FILE or (script_dir .. "modules/data/play_joey_money.txt")
do
    local f = io.open(JOEY_FILE, "r")
    if f then
        joey.money = math.max(0, math.floor(tonumber(f:read("l") or "") or 0))
        joey.wins = tonumber(f:read("l") or "")
        for line in f:lines() do
            local t, a = line:match("^(%d+) (%d+)$")
            if t then joey.recent[#joey.recent + 1] = {tonumber(t), tonumber(a)} end
        end
        f:close()
    end
    OverlayFeed.joey = joey.money
end
local function on_joey(gained)
    if type(gained) ~= "number" or gained <= 0 then return end
    pcall(pokerus_check)                        -- (a won battle: Pokerus may come with it)
    gained = math.floor(gained)
    -- (a file from before the wins were kept: as many as its money at this pay)
    joey.wins = (joey.wins or math.floor(joey.money / gained + 0.5)) + 1
    joey.money = joey.money + gained
    local now, keep = os.time(), {}
    for _, r in ipairs(joey.recent) do if now - r[1] < 86400 then keep[#keep + 1] = r end end
    keep[#keep + 1] = {now, gained}
    joey.recent = keep
    OverlayFeed.joey = joey.money      -- (the feed's next post, within 5 s, shows it)
    local f = io.open(JOEY_FILE, "w")
    if f then
        f:write(tostring(joey.money), "\n", tostring(joey.wins), "\n")
        for _, r in ipairs(keep) do f:write(r[1], " ", r[2], "\n") end
        f:close()
    end
end
-- (each part timed when the profiler's on - profile_on.txt)
local function timed(name, fn) return AutocrystalProfiler and AutocrystalProfiler.timed(name, fn) or fn end
local fe_runtime = timed("frame end: runtime", function() return update_runtime() end)
local fe_live = timed("frame end: live view", function(...) return LiveView.tick(...) end)
local fe_place = timed("frame end: place", function() return update_place() end)
local fe_feed = timed("frame end: overlay feed", function(...) return OverlayFeed.tick(...) end)
pcall(event.onframeend, function()
    pcall(fe_runtime)
    pcall(fe_live, emu.getsystemid() ~= "NULL", running)
    pcall(fe_place)
    -- (always - not only while the bot runs: the page shows this run's
    -- numbers, the clock and the place as soon as the launcher's open,
    -- never what the relay still holds from an earlier session)
    pcall(fe_feed, true)
end, "Play overlay feed")

-- ------------------------------------------------------------ main loop
while true do
    emu.frameadvance()

    if saveRequested then
        saveRequested = false
        local s, why = read_controls()
        if s then
            Play.save_settings(GuiSettings, s)
            settings = s
            forms.settext(saveLabel, save_discord() or "Saved.")
        else
            forms.settext(saveLabel, why)
        end
    end

    if discordTestRequested then
        -- A test message to the shiny channel: a shiny Gastly with this run's
        -- numbers, "Catching it..." - then 3 seconds later the edit with the
        -- result, as after a real catch. Marked TEST in its footer.
        discordTestRequested = false
        local why = save_discord()
        if why then
            forms.settext(saveLabel, why)
        elseif not discord_on() then
            forms.settext(saveLabel, "Discord: paste the channel's webhook first.")
        else
            local info = discord_info(92, 4, 14, 10, 10, 10, "shiny")
            info.met = math.max(1, info.met or 0)
            info.speciesShinies = math.max(1, info.speciesShinies or 0)
            info.phase = Stats.encountersSinceShiny
            info.since = info.phase
            pcall(function()
                local H = require("data.shiny_history")
                if not H.loaded then H.load() end
                info.phaseSecs = H.entries[1] and (os.time() - H.entries[1].time) or nil
            end)
            info.place = info.place or "Sprout Tower 2F"
            info.time = info.time or "NITE"
            info.footer = "autocrystal · TEST message (Send test)"
            info.result = {outcome = "pending"}
            local key = "test" .. os.time()
            forms.settext(saveLabel, "Discord test: sending...")
            local r1 = discord_send("send", key, info)
            if r1 == "sent" then
                forms.settext(saveLabel, "Discord test: sent - the result follows in 3 s...")
                for _ = 1, 180 do emu.frameadvance() end
                info.result = {outcome = "caught", balls = {[5] = 3}}
                local r2 = discord_send("edit", key, info)
                forms.settext(saveLabel, "Discord test: sent, then " .. tostring(r2 or "no answer") .. ".")
            else
                forms.settext(saveLabel, "Discord test: " .. tostring(r1 or "the relay (port 5020) didn't answer") .. ".")
            end
        end
    end

    if goalsRequested then
        -- Read only: the section's goals into the Lua Console (and the last line here).
        goalsRequested = false
        if not rom_loaded() then
            forms.settext(statusLabel, "Open a ROM first (Open ROM).")
        else
            local s = read_controls() or settings
            local okG, err = pcall(Play.show_goals, script_dir .. "modules/", s, function(t) print(t); forms.settext(statusLabel, clip(t)) end)
            if not okG then print("Show goals: " .. tostring(err)); forms.settext(statusLabel, "Couldn't read the goals - see the Lua Console.") end
        end
    end

    if startRequested then
        startRequested = false
        local s, why = read_controls()
        if not s then
            forms.settext(statusLabel, "Settings: " .. why)
        elseif not rom_loaded() then
            forms.settext(statusLabel, "Open a ROM first (Open ROM).")
        else
            Play.save_settings(GuiSettings, s)
            settings = s
            local dwhy = save_discord()
            if dwhy then forms.settext(saveLabel, dwhy) end
            stopRequested = false
            set_running(true)
            forms.settext(statusLabel, "Starting...")
            forms.settext(progressLabel, "")
            local okRun, ok, reason, summary = pcall(Play.run, script_dir .. "modules/", s,
                {say = on_say, log = function(t) pcall(log_line, tostring(t)) end,
                 should_stop = function() return stopRequested end, on_encounter = on_encounter, on_walk = on_walk,
                 on_targets = function(ids) pcall(OverlayFeed.set_targets, ids) end, on_joey = on_joey,
                 on_catch_result = on_catch_result,
                 on_done = function(ids) pcall(OverlayFeed.set_done, ids) end,
                 on_phase = function(have, total) pcall(OverlayFeed.set_phase, have, total) end,
                 on_next = function(text) pcall(OverlayFeed.set_next, spaced_map(text)) end})
            pcall(OverlayFeed.set_targets, {})   -- (the run's over: back to "ANY SHINY")
            set_running(false)
            stopRequested = false
            if not okRun then
                forms.settext(statusLabel, "The bot hit an error - see the Lua Console.")
                print("Play: " .. tostring(ok))      -- (errors: still the Lua Console - and the log file)
                pcall(log_line, "Error: " .. tostring(ok))
            else
                forms.settext(statusLabel, clip(summary or tostring(reason)))
            end
        end
    end
end
