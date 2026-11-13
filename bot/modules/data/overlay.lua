-- overlay.lua (goes in modules/data/ once it joins the bot)
-- The stream's text box: Overlay.say("Heading to Route 30.") puts a line in
-- the Pokemon-style box that overlay_relay.ps1 serves to OBS.
--
-- Never allowed to slow the bot down: comm.httpPost holds the emulator until
-- the relay answers, and when the relay isn't running Windows takes a second
-- or two to refuse the connection. So after a failed post, nothing is sent
-- for RETRY_SECONDS - the lines meant for that time are simply dropped.

local M = {}

M.URL = "http://127.0.0.1:5012/"
M.RETRY_SECONDS = 60
M.enabled = true

local lastText = nil
local offlineUntil = 0

local function json_escape(value)
    local s = tostring(value)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    -- Other control characters can't go into JSON as they are.
    s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', c:byte()) end)
    return s
end

-- JSON for the state: numbers, booleans, strings, and tables - a table
-- with only 1..n keys is a list, any other an object (keys sorted, so the
-- same state always reads the same). Cycles aren't followed.
local function encode(v, seen)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return (math.type and math.type(v) == "integer") and tostring(v) or string.format("%.14g", v)
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "table" then
        seen = seen or {}
        if seen[v] then return "null" end
        seen[v] = true
        local n = #v
        local isList = true
        for k in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then isList = false break end
        end
        local parts = {}
        if isList and (n > 0 or next(v) == nil) then
            for i = 1, n do parts[i] = encode(v[i], seen) end
            seen[v] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, item in pairs(v) do
            parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. encode(item, seen)
        end
        table.sort(parts)
        seen[v] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    elseif v == nil then return "null"
    else return '"' .. json_escape(v) .. '"' end
end

local function encode_state(state)
    return encode(state)
end

local function post(json)
    if not M.enabled or os.time() < offlineUntil then return false end
    local ok, response = pcall(comm.httpPost, M.URL, json)
    if not ok or response ~= "ok" then
        offlineUntil = os.time() + M.RETRY_SECONDS
        return false
    end
    return true
end

-- A line for the text box. The same line twice in a row is only shown once
-- (a loop that keeps saying "Walking the loop" doesn't fill the box).
-- force: show it even if it was the last line.
function M.say(text, force)
    if text == nil or text == "" then return false end
    if text == lastText and not force then return false end
    lastText = text
    return post('{"say":"' .. json_escape(text) .. '"}')
end

-- Replaces what the page knows about the hunt. scene.html reads:
--   location, time_of_day ("MORN"/"DAY"/"NITE"), session_seconds, phase,
--   since_shiny, total, shinies, lowest_dv_sum, longest_streak,
--   current = {species, atk, def, spe, spc, item, shiny, streak},
--   recent_shinies = {{species, atk, def, spe, spc, time (os.time())}, ...},
--   targets = {species, ...}, section = {caught, total},
--   encounters = {{species, atk, def, spe, spc, item, shiny}, ...},
--   records = (the same shape: the session's best DVs).
function M.state(state)
    return post('{"state":' .. encode_state(state) .. '}')
end

-- For tests: forget the last line and any back-off.
function M.reset()
    lastText, offlineUntil = nil, 0
end

return M
