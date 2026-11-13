-- goals.lua (lives in modules/data/)
-- What a section still needs, as a LIVING DEX (the user's rules, 2026-11-08):
-- one shiny of every form - every species met in the section, and every
-- form it evolves into. A form not met in the section is made by evolving
-- an extra shiny (3 shiny Zubat: one stays, one becomes Golbat, one Crobat).
-- Trade evolutions (Gengar, Golem, Politoed...) are left out, and anything
-- after one. Level and friendship evolutions are done before the gym
-- (blocking); stone evolutions when the stone's there (not blocking).
--
-- M.plan(section, owned, opts) -> the forms with what each has / needs,
-- the catch list ({species, need, blocking}), the evolve list, done.
-- opts.allShiny: treat every owned Pokemon as shiny (the testing switch).
-- Plain functions on tables (battle_data.lua, sections.lua, owned from
-- data/collection.lua), tested offline.

local M = {}

local D
local Names = {}
local SLOTS = {30, 30, 20, 10, 5, 4, 1}
local WATER = {60, 30, 10}

function M.setup(battleData, names)
    D = battleData
    Names = names or {}
end

local function name(sp) return Names[sp] or ("#" .. tostring(sp)) end
M.name = name
-- The lines whose first shiny goes to the last form (a team job): the
-- catcher's (data/team.lua's STYLE_CATCHERS) and the HM slave's (its
-- STYLE_HM - the user, 2026-11-10: "first shiny sentret becomes the hm
-- slave, gets evolved to furret"; a shiny Krabby to Kingler later).
M.RESERVED_LINES = {
    {"CATERPIE", "METAPOD", "BUTTERFREE"},
    {"SENTRET", "FURRET"},
    {"KRABBY", "KINGLER"},
}
-- flag(name) -> whether that event flag is set (play sets it): a section's
-- locked maps (sections.lua) count only once theirs is. nil: all open.
M.flag = nil

-- Where each species can be met in a section: {[species] = {{map, time, pct}, ...}}.
function M.spots(section)
    local out = {}
    -- (rate: the % of steps that meet a wild one there - a tower's 2%
    -- against the grass' 10% - data/hunt.lua counts encounters per step)
    local function add(sp, mp, t, pct, rate)
        out[sp] = out[sp] or {}
        out[sp][#out[sp] + 1] = {map = mp, time = t, pct = pct, rate = rate}
    end
    for _, mp in ipairs(section.maps) do
        -- (a map whose wild ones need a flag first - the Inner Chamber's
        -- Unown, a puzzle solved: left out until M.flag says it's set)
        local lock = section.locked and section.locked[mp]
        local g = D.wild_grass[mp]
        if lock and M.flag and not M.flag(lock) then g = nil; mp = "-" end
        if g and section.methods.walk then
            for ti, t in ipairs({"morn", "day", "nite"}) do
                local tally = {}
                for i, slot in ipairs(g[t]) do tally[slot[2]] = (tally[slot[2]] or 0) + SLOTS[i] end
                for sp, pct in pairs(tally) do add(sp, mp, t, pct, g.rates and g.rates[ti]) end
            end
        end
        local w = D.wild_water[mp]
        if w and section.methods.surf then
            local tally = {}
            for i, slot in ipairs(w.mons) do tally[slot[2]] = (tally[slot[2]] or 0) + WATER[i] end
            for sp, pct in pairs(tally) do add(sp, mp, "any", pct, w.rate) end
        end
    end
    return out
end

-- An evolution step's wording and whether it holds up the gym.
local function how(e)
    local kind, param = e[1], e[2]
    if kind == "level" then return "Lv " .. param, true end
    if kind == "happiness" then return "friendship" .. (param == "TR_MORNDAY" and " (day)" or param == "TR_NITE" and " (night)" or ""), true end
    if kind == "stat" then return "Lv " .. param .. " (by stats)", true end
    if kind == "item" then return param:gsub("_", " "):lower(), false end
    return kind, false
end
M.how = how

-- An evolved form met here is evolved from a pre-evolution met here at
-- least this many times as often, not hunted itself (the user, 2026-11-13:
-- a 1% Weezing in the Burned Tower held up the Morty section for months
-- while Koffing is 59% - simulated, all of Johto ~6.9 -> ~5.5 years).
-- Only by level, friendship or stats - a form that needs a stone is still
-- caught. nil: every form met here is caught as itself.
M.EVOLVE_RATIO = 2

-- The forms a section needs: {[species] = {species, catchable, met, from,
-- path = {edges from `from`}, blocking}}. met: seen in the wild here.
-- catchable: hunted as itself - met here and not much rarer than a
-- pre-evolution met here (M.EVOLVE_RATIO). The rest come from `from`: the
-- commonest pre-evolution met here for a met form, else the shortest way.
function M.forms(section)
    local spots = M.spots(section)
    local best = {}
    for sp, list in pairs(spots) do
        local b = 0
        for _, e in ipairs(list) do if e.pct > b then b = e.pct end end
        best[sp] = b
    end
    local function blockingPath(p)
        for _, x in ipairs(p) do local _, b = how(x); if not b then return false end end
        return true
    end
    -- (a line's commonest form is never much rarer than another, so a line
    -- always keeps something to catch)
    local evolveIt = {}
    if M.EVOLVE_RATIO then
        for sp in pairs(spots) do
            local function down(cur, path)
                for _, e in ipairs(D.evos[cur] or {}) do
                    if e[1] ~= "trade" then
                        local p = {}
                        for _, x in ipairs(path) do p[#p + 1] = x end
                        p[#p + 1] = e
                        if blockingPath(p) then
                            local into = e[3]
                            if spots[into] and into ~= sp and best[sp] >= M.EVOLVE_RATIO * best[into] then evolveIt[into] = true end
                            down(into, p)
                        end
                    end
                end
            end
            down(sp, {})
        end
    end
    local forms = {}
    for sp in pairs(spots) do forms[sp] = {species = sp, catchable = not evolveIt[sp], met = true, from = sp, path = {}, blocking = true} end
    local function walk(sp, from, path)
        for _, e in ipairs(D.evos[sp] or {}) do
            if e[1] ~= "trade" then
                local into = e[3]
                local p = {}
                for _, x in ipairs(path) do p[#p + 1] = x end
                p[#p + 1] = e
                local f = forms[into]
                local blocking = blockingPath(p)
                local better
                if not f then better = true
                elseif f.catchable then better = false
                elseif f.met then
                    -- (met here, evolved instead: by level etc. only, from the commonest one)
                    better = blocking and (f.from == into or best[from] > best[f.from] or (best[from] == best[f.from] and #p < #f.path))
                else better = #p < #f.path end
                if better then
                    forms[into] = {species = into, catchable = false, met = f and f.met or nil, from = from, path = p, blocking = blocking}
                    walk(into, from, p)
                end
            end
        end
    end
    for sp in pairs(spots) do if not evolveIt[sp] then walk(sp, sp, {}) end end
    return forms, spots
end

-- What's still needed. owned: {{key, species, shiny, level, egg}, ...}.
function M.plan(section, owned, opts)
    opts = opts or {}
    local forms, spots = M.forms(section)
    local list = {}
    for _, f in pairs(forms) do list[#list + 1] = f end
    table.sort(list, function(a, b) return a.species < b.species end)
    -- The owned shinies, by species, not yet given a part.
    local pool = {}
    local keys = {}
    for _, m in ipairs(owned) do
        -- (the testing switch makes regular Pokemon "shiny" for the team -
        -- collection.lua keeps the truth in realShiny: only that counts here,
        -- unless opts.allShiny says otherwise)
        local shiny = m.realShiny
        if shiny == nil then shiny = m.shiny end
        if not m.egg and (shiny or opts.allShiny) then
            pool[m.species] = pool[m.species] or {}
            table.insert(pool[m.species], m)
        end
    end
    -- (the same copy keeps the same part as long as nothing changes: by
    -- level, then who it is (fp) - the LOWEST level one stays as it is,
    -- the HIGHEST level spare is the one to evolve: less to train, and a
    -- team fighter is usually the one that evolves)
    for _, l in pairs(pool) do
        table.sort(l, function(a, b)
            if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
            return tostring(a.fp or a.key) < tostring(b.fp or b.key)
        end)
    end
    local function take(sp, highest)
        local l = pool[sp]
        if not l or #l == 0 then return nil end
        return table.remove(l, highest and #l or 1)
    end
    -- 0. the team's lines (M.RESERVED_LINES - the catcher's, the HM
    -- slave's): the last form here does the job, so a shiny of the line
    -- goes to that one first - the most evolved, highest level - not to
    -- the copy that stays (the user, 2026-11-10: the first shiny Caterpie
    -- was kept a Caterpie and never trained into the new catcher; "first
    -- shiny sentret becomes the hm slave, gets evolved to furret"). Later
    -- ones fill the rest.
    for _, line in ipairs(M.RESERVED_LINES) do
        local lineSet = {}
        for _, n in ipairs(line) do lineSet[n] = true end
        local top = nil
        for _, f in ipairs(list) do
            if lineSet[tostring(Names[f.species] or ""):upper()] and (not top or #f.path > #top.path) then top = f end
        end
        if top and not top.evolveFrom and not (pool[top.species] and #pool[top.species] > 0) and #top.path > 0 then
            local chain = {top.from}
            for _, e in ipairs(top.path) do chain[#chain + 1] = e[3] end
            for i = #chain - 1, 1, -1 do
                local m = take(chain[i], true)
                if m then
                    top.evolveFrom = m
                    top.evolvePath = {}
                    for k = i, #top.path do top.evolvePath[#top.evolvePath + 1] = top.path[k] end
                    break
                end
            end
        end
    end
    -- 1. each form: one of its own species (the lowest level - it stays)
    for _, f in ipairs(list) do if not f.evolveFrom then f.have = take(f.species) end end
    -- 2. a form not met here and not had: a spare further down its line to
    -- evolve - the longest ways first, so they get the highest-level spares
    local byPath = {}
    for _, f in ipairs(list) do byPath[#byPath + 1] = f end
    table.sort(byPath, function(a, b) if #a.path ~= #b.path then return #a.path > #b.path end; return a.species < b.species end)
    for _, f in ipairs(byPath) do
        if not f.have and not f.catchable then
            local chain = {f.from}
            for _, e in ipairs(f.path) do chain[#chain + 1] = e[3] end
            for i = #chain - 1, 1, -1 do        -- (the most evolved spare first, its highest level)
                local m = take(chain[i], true)
                if m then
                    f.evolveFrom = m
                    f.evolvePath = {}
                    for k = i, #f.path do f.evolvePath[#f.evolvePath + 1] = f.path[k] end
                    break
                end
            end
        end
    end
    -- 3. the rest: catch one (more) of where it comes from
    local catch, catchOrder = {}, {}
    for _, f in ipairs(list) do
        if not f.have and not f.evolveFrom then
            local sp = f.catchable and f.species or f.from
            if not catch[sp] then
                catch[sp] = {species = sp, need = 0, later = 0, blocking = false, spots = spots[sp], forms = {}}
                catchOrder[#catchOrder + 1] = catch[sp]
            end
            -- (for a form that waits for a stone: one for later, not holding up the gym)
            if f.blocking then catch[sp].need = catch[sp].need + 1; catch[sp].blocking = true
            else catch[sp].later = catch[sp].later + 1 end
            catch[sp].forms[#catch[sp].forms + 1] = f.species
            f.toCatch = sp
        end
    end
    -- The evolutions to do now (blocking) or once there's a stone.
    local evolve = {}
    for _, f in ipairs(list) do
        if f.evolveFrom then
            local steps, blocking = {}, true
            for _, e in ipairs(f.evolvePath) do
                local w, b = how(e)
                steps[#steps + 1] = w
                if not b then blocking = false end
            end
            evolve[#evolve + 1] = {key = f.evolveFrom.key, fp = f.evolveFrom.fp, level = f.evolveFrom.level, dvs = f.evolveFrom.dvs,
                otId = f.evolveFrom.otId, from = f.evolveFrom.species, to = f.species, how = table.concat(steps, ", then "),
                blocking = blocking, path = f.evolvePath}
        end
    end
    -- Done: every form that holds up the gym is had.
    local done, haveN, blockingN = true, 0, 0
    for _, f in ipairs(list) do
        if f.have then haveN = haveN + 1 end
        if f.blocking then
            blockingN = blockingN + 1
            if not f.have then done = false end
        end
    end
    table.sort(catchOrder, function(a, b) return a.species < b.species end)
    -- Keepers: each form's own copy, where it could still evolve - it must
    -- not (data/fighter.lua cancels its evolution with B). By fingerprint,
    -- then species: HOW MANY copies stay (M.stays) - twins (every DV the
    -- same, 1 in 8 for two shinies of a species, and Gen 2 has no ID
    -- number) share a fingerprint, and the one to evolve mustn't be held
    -- back with the one that stays (the user's two Spinaraks, 2026-11-10).
    local keepers = {}
    for _, f in ipairs(list) do
        if f.have and D.evos[f.species] and #D.evos[f.species] > 0 then
            local k = f.have.fp or f.have.key
            keepers[k] = keepers[k] or {}
            keepers[k][f.species] = (keepers[k][f.species] or 0) + 1
        end
    end
    return {forms = list, catch = catchOrder, evolve = evolve, done = done, have = haveN, total = #list, blockingTotal = blockingN,
        keepers = keepers}
end

-- Whether a copy (fingerprint fp, species now) must stay as it is - not
-- evolve: keepers from M.plan; have: how many copies of that fingerprint
-- and species are owned now (this one too). One of two twins may evolve
-- when one is to stay; the last may not. (keepers[fp] == true: the old
-- form - every copy stays.)
function M.stays(keepers, fp, species, have)
    local k = keepers and fp and keepers[fp]
    if k == true then return true end
    if type(k) ~= "table" or not k[species] then return false end
    return (have or 1) <= k[species]
end

-- The section now: the first whose gym flag isn't set. flag(name) -> bool.
function M.current(sections, flag)
    for i, s in ipairs(sections) do
        if not flag(s.gym) then return s, i end
    end
    return nil
end

-- A summary for the log.
function M.describe(section, p)
    local lines = {}
    lines[#lines + 1] = string.format("%s: %d of %d forms (%d hold up %s).", section.name, p.have, p.total, p.blockingTotal, section.leader or "the gym")
    local c = {}
    for _, e in ipairs(p.catch) do
        if e.need > 0 then
            c[#c + 1] = string.format("%s x%d%s", name(e.species), e.need, e.later > 0 and string.format(" (+%d for later)", e.later) or "")
        else
            c[#c + 1] = string.format("%s x%d for later", name(e.species), e.later)
        end
    end
    if #c > 0 then lines[#lines + 1] = "To catch shiny: " .. table.concat(c, ", ") .. "." end
    local ev = {}
    for _, e in ipairs(p.evolve) do
        ev[#ev + 1] = string.format("%s -> %s (%s)%s", name(e.from), name(e.to), e.how, e.blocking and "" or " (once there's the stone)")
    end
    if #ev > 0 then lines[#lines + 1] = "To evolve: " .. table.concat(ev, "; ") .. "." end
    return lines
end

return M
