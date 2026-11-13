-- play.lua - the playthrough bot as one module, for the launcher (and
-- story_run.lua): plays the story (data/story_steps.lua) from wherever the
-- save is, with the user's settings - see M.FIELDS. Battles, healing,
-- shopping, catching, the team and training as the data/ modules do them.
--
-- M.run(dir, settings, hooks) - dir: the modules folder; hooks.say(text)
-- for each log line, hooks.should_stop() checked between moves (a battle
-- under way is finished first), hooks.on_encounter(species, level, atk,
-- def, spe, spc, shiny) for each wild one. Returns ok, why, a summary line.

local M = {}

-- Every setting: key, its default, and for the launcher a label, a kind
-- ("choice", "check", "number"), choices or limits. Stored in the
-- settings file as "play_<key>".
M.FIELDS = {
    {key = "mode", default = "testing", kind = "choice", label = "Mode",
        choices = {{"testing", "Testing - regular Pokemon may join"}, {"stream", "Stream - shinies only"}}},
    {key = "testShiny", default = false, kind = "check", label = "Testing: regular Pokemon may fill the team (only shinies are caught; off in Stream mode)"},
    {key = "starter", default = "TOTODILE", kind = "choice", label = "Starter",
        choices = {{"TOTODILE", "Totodile"}, {"CYNDAQUIL", "Cyndaquil"}, {"CHIKORITA", "Chikorita"}}},
    {key = "lowHp", default = 30, kind = "number", label = "Heal when the lead is under (% HP)", min = 5, max = 95},
    {key = "centerNear", default = 150, kind = "number", label = "A Pokemon Center counts as close within (steps)", min = 0, max = 2000},
    {key = "caveHealthy", default = 50, kind = "number", label = "In caves, fight on while the others have (% HP)", min = 0, max = 100},
    {key = "centerBeforeBadge", default = true, kind = "check", label = "Before the first badge, always heal at a Center"},
    {key = "shop", default = true, kind = "check", label = "Shop at the Mart after healing"},
    {key = "potions", default = 5, kind = "number", label = "Potions to keep", min = 0, max = 30},
    {key = "antidotes", default = 3, kind = "number", label = "Antidotes to keep", min = 0, max = 30},
    {key = "moneyFloor", default = 500, kind = "number", label = "Never spend below ($)", min = 0, max = 999999},
    {key = "minBalls", default = 10, kind = "number", label = "Balls alone: only if it can buy at least", min = 1, max = 99},
    {key = "battleHeal", default = 25, kind = "number", label = "In battle, use a potion under (% HP; 0 = never)", min = 0, max = 90},
    {key = "catch", default = true, kind = "check", label = "Catch shinies (sleep, safe weakening, balls)"},
    {key = "catchHp", default = 40, kind = "number", label = "Weaken a shiny to (% HP) before the balls", min = 1, max = 100},
    {key = "trainMargin", default = 2, kind = "number", label = "Train to the next big fight's top level +", min = 0, max = 20},
}

function M.defaults()
    local s = {}
    for _, f in ipairs(M.FIELDS) do s[f.key] = f.default end
    return s
end

-- A value checked against its field: (value, nil) or (nil, why).
function M.check(field, raw)
    if field.kind == "check" then return raw == true or raw == "true" end
    if field.kind == "choice" then
        for _, c in ipairs(field.choices) do if raw == c[1] or raw == c[2] then return c[1] end end
        return nil, field.label .. ": not one of the choices"
    end
    local n = tonumber(raw)
    if n == nil or n ~= math.floor(n) then return nil, field.label .. ": a whole number, please" end
    if n < field.min or n > field.max then return nil, string.format("%s: between %d and %d", field.label, field.min, field.max) end
    return n
end

-- From the settings store (data/gui_settings.lua's get_text/set/save):
-- every field, its stored value if it's valid, else the default.
function M.load_settings(store)
    local s = M.defaults()
    for _, f in ipairs(M.FIELDS) do
        local raw = store.get_text("play_" .. f.key)
        if raw ~= nil and raw ~= "" then
            local v = M.check(f, raw)
            if v ~= nil then s[f.key] = v end
        end
    end
    return s
end

function M.save_settings(store, s)
    for _, f in ipairs(M.FIELDS) do
        local v = s[f.key]
        if f.kind == "check" then v = v and "true" or "false" end
        store.set("play_" .. f.key, tostring(v))
    end
    store.save()
end

local LINES = {
    TOTODILE = {"TOTODILE", "CROCONAW", "FERALIGATR"},
    CYNDAQUIL = {"CYNDAQUIL", "QUILAVA", "TYPHLOSION"},
    CHIKORITA = {"CHIKORITA", "BAYLEEF", "MEGANIUM"},
}
local function cap(n) return n:sub(1, 1) .. n:sub(2):lower() end

-- The story's steps for another starter: its Poke Ball in Elm's lab, its
-- flag, its name.
function M.steps_for_starter(steps, starter)
    if starter == "TOTODILE" then return steps end
    local name = cap(starter)
    for _, st in ipairs(steps) do
        if st.done == "EVENT_GOT_TOTODILE_FROM_ELM" then st.done = "EVENT_GOT_" .. starter .. "_FROM_ELM" end
        st.name = st.name:gsub("Totodile", name)
        for _, a in ipairs(st.actions or {}) do
            if a.talk and a.talk[2] == "TotodilePokeBallScript" then a.talk[2] = name .. "PokeBallScript" end
        end
    end
    return steps
end

-- The YES/NO answers for the starter: YES to the chosen one, NO to the rest.
function M.answers_for_starter(answers, starter)
    for _, a in ipairs(answers) do
        if a[1] == "totodile" or a[1] == "cyndaquil" or a[1] == "chikorita" then a[2] = (a[1] == starter:lower()) end
    end
end

-- Read only: the current section's goals (data/goals.lua) from the save,
-- line by line to say(). Presses nothing.
function M.show_goals(dir, s, say)
    say = say or print
    for _, name in ipairs({"data.world", "data.game_state", "data.collection", "data.goals", "data.pokemon_names"}) do package.loaded[name] = nil end
    local World = require("data.world")
    local State = require("data.game_state")
    local Collection = require("data.collection")
    local Goals = require("data.goals")
    local okNames, Names = pcall(require, "data.pokemon_names")
    if not okNames then Names = {} end
    local version = memory.readbyte(0x141)
    if version ~= 0x54 then say("Pokemon Crystal (English) only."); return end
    World.load(dofile(dir .. "data/world_data.lua"))
    local battleData = dofile(dir .. "data/battle_data.lua")
    Collection.setup(State, battleData.charmap)
    require("data.family").setup(battleData.evos)
    if not Collection.readSram then say("No save-RAM memory domain in this BizHawk core."); return end
    Collection.ALL_SHINY = s.mode ~= "stream" and s.testShiny == true
    Goals.setup(battleData, Names)
    Goals.flag = function(f) local n = World.data.flags[f]; return n ~= nil and State.flag(n) end
    local sections = dofile(dir .. "data/sections.lua")
    local section = Goals.current(sections, function(f) local n = World.data.flags[f]; return n ~= nil and State.flag(n) end)
    if not section then say("Every section's gym is beaten - no section left in data/sections.lua."); return end
    local all, bad = Collection.all()
    local plan = Goals.plan(section, all, {})
    for _, l in ipairs(Goals.describe(section, plan)) do say(l) end
    local have = {}
    for _, f in ipairs(plan.forms) do if f.have then have[#have + 1] = Goals.name(f.species) end end
    if #have > 0 then say("Have: " .. table.concat(have, ", ") .. ".") end
    if #bad > 0 then say("(Boxes that didn't read - normal before the first save: " .. table.concat(bad, ", ") .. ".)") end
    if Collection.ALL_SHINY then say("(Testing switch on - since 2026-11-08 it changes nothing for the team: specialists are real shinies only; the catcher and second catcher may be regular in both modes, the HM slave is always a shiny.)") end
    return plan
end

function M.run(dir, s, hooks)
    hooks = hooks or {}
    -- Nothing in the Lua Console while the launcher listens (the user,
    -- 2026-11-10: "in the console I don't wanna see anything since we have
    -- our own logs"): its say() writes every line to the log file (and the
    -- overlay), its log() the modules' own notes to the file only. Run
    -- without the launcher: the console, as before.
    local console = AutocrystalConsolePrint or print
    local function say(t)
        if hooks.say then pcall(hooks.say, t) else console(os.date("%H:%M:%S ") .. t) end
    end
    local function print(t)
        if hooks.log then pcall(hooks.log, t) elseif not hooks.say then console(tostring(t)) end
    end
    -- BizHawk keeps required modules between runs: drop ours.
    for _, name in ipairs({"data.world", "data.game_state", "data.walker", "data.button_wait", "data.pokemon_names",
        "data.fighter", "data.bag", "data.mart", "data.story", "data.story_steps", "data.screen",
        "data.collection", "data.pc", "data.team", "data.teamer"}) do
        package.loaded[name] = nil
    end
    local Mem = require("data.memory")
    local ButtonWait = require("data.button_wait")
    local World = require("data.world")
    local State = require("data.game_state")
    local Walker = require("data.walker")
    local Fighter = require("data.fighter")
    local Bag = require("data.bag")
    local Mart = require("data.mart")
    local Story = require("data.story")
    local Collection = require("data.collection")
    local PC = require("data.pc")
    local Team = require("data.team")
    local Teamer = require("data.teamer")
    local okNames, Names = pcall(require, "data.pokemon_names")
    if not okNames then Names = {} end
    local Goals, section      -- (the section and its goals: set below)

    local version, region = memory.readbyte(0x141), memory.readbyte(0x142)
    if version ~= 0x54 or region == 0x4A or region == 0x4B then
        say("This is for Pokemon Crystal (English) only.")
        return false, "not Crystal", "Not Pokemon Crystal (English)."
    end
    Mem.SetRomBankAddress("Crystal")
    ButtonWait.setup(version, region)
    ButtonWait.register(Mem)
    World.load(dofile(dir .. "data/world_data.lua"))
    local battleData = dofile(dir .. "data/battle_data.lua")
    require("data.screen").setup(State, Mem, battleData.charmap)
    Fighter.setup(battleData, State, ButtonWait, Mem, Names, print)
    Bag.setup(battleData, State, ButtonWait, Mem, Names, print)
    Mart.setup(battleData, State, ButtonWait, Mem, print)
    Collection.setup(State, battleData.charmap)
    PC.setup(State, ButtonWait, Mem, Names, print)
    Team.setup(battleData, Names)
    -- (one ID per Pokemon that survives evolving: data/family.lua)
    package.loaded["data.family"] = nil
    require("data.family").setup(battleData.evos)

    -- The settings.
    Team.SHINY_ONLY = s.mode == "stream"
    -- (the testing switch: every Pokemon counts as shiny - never in Stream mode)
    Collection.ALL_SHINY = s.mode ~= "stream" and s.testShiny == true
    local starterLine = {}
    for _, n in ipairs(LINES[s.starter] or LINES.TOTODILE) do
        for id, nm in pairs(Names) do if type(id) == "number" and nm:upper() == n then starterLine[#starterLine + 1] = id end end
    end
    Walker.LOW_HP = s.lowHp / 100
    Walker.CENTER_NEAR = s.centerNear
    Walker.HEALTHY = s.caveHealthy / 100
    Walker.CENTER_BEFORE_BADGE = s.centerBeforeBadge
    Walker.should_stop = hooks.should_stop
    Mart.RULES.stock = {{"POTION", s.potions, potions = true}, {"ANTIDOTE", s.antidotes}}
    Mart.RULES.floor = s.moneyFloor
    Mart.RULES.minBalls = s.minBalls
    Fighter.CATCH_HP = s.catchHp / 100
    -- (the badges we really have, from the start - not only once a fight
    -- has read them: unknown, a type boost is assumed, and the second
    -- catcher's level came out at 11 at a restart, the user's log 2026-11-09)
    Fighter.badgeTypes = Fighter.badge_types(State.read8(0xD857), State.read8(0xD858))
    Fighter.HEAL_HP = s.battleHeal / 100

    Teamer.setup(World, State, Walker, Team, Collection, PC, Names, print, starterLine)
    -- (no specialists before the first badge - the user, 2026-11-09: they're
    -- picked after Falkner; till then only the starter trains, and the
    -- catchers to their levels)
    Team.specialists_open = function() return State.badges() >= 1 end
    Walker.setup(World, State, ButtonWait, Mem, print, Fighter, Bag, s.shop and Mart or nil, Collection.readSram and Teamer or nil)
    Walker.should_stop = hooks.should_stop
    Walker.on_encounter = hooks.on_encounter
    Walker.on_walk = hooks.on_walk
    Walker.on_catch_result = hooks.on_catch_result   -- (the launcher's Discord shiny message)
    -- (the healer - Milk Drink, Softboiled - outside battle: data/pc.lua)
    Walker.field_heal = function(share, o) return PC.field_heal(share, o) end
    Walker.healer_index = PC.healer_index
    -- Who may faint rather than get a potion or an Antidote (the user,
    -- 2026-11-08): only before the first badge, only with a Pokemon Center
    -- within SPARE_STEPS, never the starter, the catcher, the future catcher,
    -- the last specialist standing, or the last one able to fight.
    local SPARE_STEPS = 300
    local function spare(fp)
        local cur = Teamer.current
        if not fp or not cur or State.badges() > 0 then return false end
        for _, m in ipairs({cur.starter, cur.catcher, cur.prospect and cur.prospect.mon}) do
            if m and m.fp == fp then return false end
        end
        local party = Collection.party()
        local others, isSpec, otherSpec = 0, false, 0
        local specs = {}
        for _, m in ipairs(cur.specialists or {}) do specs[m.fp or ""] = true end
        for _, m in ipairs(party) do
            if m.fp ~= fp and not m.egg and m.hp > 0 then
                others = others + 1
                if specs[m.fp] then otherSpec = otherSpec + 1 end
            end
        end
        if specs[fp] then isSpec = true end
        if others == 0 or (isSpec and otherSpec == 0) then return false end
        local w = State.where()
        local c = Walker.nearest_center({map = w.map, x = w.x, y = w.y, face = State.facing()})
        return c ~= nil and c.steps <= SPARE_STEPS
    end
    Fighter.spare = function(mon) return spare(mon and mon.fp) end
    Walker.spare_slot = function(k) local m = Collection.party()[k]; return m ~= nil and spare(m.fp) end
    Story.setup(World, State, ButtonWait, Mem, Walker, battleData, print)
    Story.use_team(Teamer, PC, Collection, Names)
    Story.bigFights = dofile(dir .. "data/big_fights.lua")
    Story.MARGIN = s.trainMargin
    M.answers_for_starter(Story.ANSWERS, s.starter)
    local steps = M.steps_for_starter(dofile(dir .. "data/story_steps.lua"), s.starter)

    local snap = State.snapshot()
    local here = World.map(snap.map)
    say(string.format("Walker build %s. I'm on %s at %d,%d; %d badges, $%d.", tostring(Walker.BUILD),
        here and here.name or snap.map, snap.x, snap.y, snap.badges, snap.money))
    if not here then return false, "map", "This map isn't in the data - stopped." end
    local done = 0
    for _, st in ipairs(steps) do if st.done ~= nil and not st.testOnly and Story.is_done(st) then done = done + 1 end end
    say(string.format("Story so far: %d of the %d checkpoints done. Starter %s; %s.", done, #steps, cap(s.starter),
        Team.SHINY_ONLY and "stream mode - only shinies are caught and fill the team" or "testing mode - regular Pokemon may be the catcher and second catcher"))
    if Collection.readSram then
        Teamer.current = Team.pick(Collection.for_team(starterLine))
        say("Team as of now: " .. table.concat(Teamer.current.why, " | ") .. ".")
    end
    -- The section's goals (a living dex: data/goals.lua).
    package.loaded["data.goals"] = nil
    Goals = require("data.goals")
    Goals.setup(battleData, Names)
    Goals.flag = function(f) local n = World.data.flags[f]; return n ~= nil and State.flag(n) end
    local sections = dofile(dir .. "data/sections.lua")
    section = Goals.current(sections, function(f) local n = World.data.flags[f]; return n ~= nil and State.flag(n) end)
    if section and Collection.readSram then
        local plan = Goals.plan(section, Collection.all(), {})
        for _, l in ipairs(Goals.describe(section, plan)) do say(l) end
        -- (the overlay from the start, story steps too: icons, phase count)
        require("data.hunt").tell_overlay(plan, hooks)
        Fighter.no_evolve = plan.keepers     -- (the keepers never evolve - from the first battle on)
        -- (how many copies of a fingerprint and species are owned: of twins
        -- one may evolve - Goals.stays)
        Fighter.copies = function(fp, species)
            local n = 0
            for _, m in ipairs(Collection.all()) do if m.fp == fp and m.species == species then n = n + 1 end end
            return n
        end
        if Collection.ALL_SHINY then say("(Testing switch on - since 2026-11-08 it changes nothing for the team: specialists are real shinies only; the catcher and second catcher may be regular in both modes, the HM slave is always a shiny.)") end
    end

    local fights, runs = 0, 0
    local lastMapSaid = nil
    local f0 = emu.framecount()
    local walkOpts = {say = say, on_targets = hooks.on_targets, on_next = hooks.on_next, on_done = hooks.on_done, on_phase = hooks.on_phase, shinyOnly = Team.SHINY_ONLY, catch = s.catch, should_stop = hooks.should_stop,
        count_owned = function() local all = Collection.all(); return #all end,
        -- (a shiny caught outside the hunt - the evolving, the story steps:
        -- the overlay's icons and phase count at once; the hunt does its own)
        on_shiny = function(_, _, caught)
            if not (caught and section) then return end
            local okP, p = pcall(Goals.plan, section, Collection.all(), {})
            if okP and p then pcall(require("data.hunt").tell_overlay, p, hooks) end
        end,
        on_fight_over = function(trainer)
            fights = fights + 1
            local hp = State.party_hp()
            say(string.format("Won the %s battle. Party HP %s, lead Lv %d.", trainer and "trainer" or "wild",
                hp and (math.floor(hp * 100) .. "%") or "?", Story.lead_level()))
        end,
        -- (only when the map really changes - not at every pace in the grass)
        on_map = function(key)
            if key == lastMapSaid then return end
            lastMapSaid = key
            say("Now on " .. World.map(key).name .. ".")
        end,
        on_battle_over = function(species, level)
            runs = runs + 1
            say(string.format("Ran from a wild %s (Lv %d).", Names[species] or ("#" .. species), level))
        end}

    -- The section's wild ones still wanted, with their levels (data/sweet_spot.lua):
    -- the catcher's risk (team picks - story and hunt), its sweet spot, the
    -- second catcher's choice.
    package.loaded["data.sweet_spot"] = nil
    local SweetSpot = require("data.sweet_spot")
    SweetSpot.setup(battleData, Fighter)
    local function section_targets()
        local need = {}
        for _, e in ipairs(Goals.plan(section, Collection.all(), {}).catch) do
            if e.need > 0 then need[e.species] = true end
        end
        return SweetSpot.targets(section, need)
    end
    if section and Collection.readSram then
        -- (a catcher that gets hit while it tries: worse, however accurate -
        -- the user, 2026-11-08, Gastly vs Butterfree)
        -- (the living dex's copy that stays as it is: never a future catcher
        -- that needs evolving)
        Team.is_keeper = function(m)
            return m.fp ~= nil and Goals.stays(Fighter.no_evolve, m.fp, m.species, Fighter.copies and Fighter.copies(m.fp, m.species) or 1)
        end
        local riskMemo = {}
        Team.catcher_risk = function(mon, acc)
            local k = os.time() // 60       -- (one pick asks for every candidate)
            if riskMemo.k ~= k then riskMemo = {k = k, targets = section_targets()} end
            return (SweetSpot.catcher_risk(mon, riskMemo.targets, acc))
        end
    end

    local saidBand = nil
    -- The second catcher (team.lua's weak role): the one that weakens most
    -- of the weak ones the main catcher can't.
    local memo = {}     -- (one pick asks for every candidate: the targets and the catcher's part once)
    Team.weak_score = function(m, catcher)
        if not section then return nil end
        local k = (catcher.fp or "?") .. ":" .. (catcher.level or 0) .. ":" .. os.time()
        if memo.k ~= k then
            local t = section_targets()
            memo = {k = k, targets = t, main = SweetSpot.main_cover(catcher, t)}
        end
        return SweetSpot.second_score(m, memo.main, memo.targets)
    end
    local function catcher_plan(party)
        local c = Teamer.current and Teamer.current.catcher
        local now = nil
        for _, m in ipairs(party) do if c and m.fp == c.fp then now = m end end
        -- (no catcher yet - the future one in training: the second
        -- catcher still trains to its level meanwhile; the user,
        -- 2026-11-09: "when will the bot catch a zubat as 2nd catcher?")
        local weak, weakNow = Teamer.current and Teamer.current.weak, nil
        Fighter.no_partner = Fighter.no_partner or {}     -- (mark_partners set it)
        if weak and weak.fp then
            Fighter.no_partner[weak.fp] = true
            for _, m in ipairs(party) do if m.fp == weak.fp then weakNow = m end end
        end
        local function weak_training()
            local wl = Teamer.current and Teamer.current.weakLevel
            if weakNow and wl and weakNow.level < wl then
                return {fp = weakNow.fp, species = weakNow.species, level = weakNow.level, target = wl,
                    why = "the second catcher - it weakens the weak ones fastest there, still safely"}
            end
            return nil
        end
        if not now then return weak_training() end
        local band = SweetSpot.band(now, section_targets())
        local note = string.format("Catcher %s (Lv %d): outspeeds everything still wanted here from Lv %s - its sweet spot; it weakens %d%% of their levels safely there.",
            Names[now.species] or "?", now.level, tostring(band.low or "-"), math.floor(band.cover * 100 + 0.5))
        if note ~= saidBand then say(note); saidBand = note end
        -- (no EXP past their spots: the catcher once there, the second
        -- catcher once at its best level - team.lua's weakLevel: where it
        -- weakens the weak ones fastest and still safely; the user,
        -- 2026-11-08: "a 2nd weakener a bit stronger and more suitable")
        if now.level < band.train then return {fp = now.fp, species = now.species, level = now.level, target = band.train} end
        return weak_training()
    end
    local prospectDone = {}
    local prospectFetch = {}
    -- (who never comes in as a switch-training partner: the second
    -- catcher always - EXP would take it past its level, and a Lv 3-9
    -- Zubat faints; the catcher once at its sweet spot. Set before any
    -- training - the future catcher's too. The starter comes in first.)
    local function mark_partners(party)
        local cur = Teamer.current
        local np = {}
        if cur and cur.weak and cur.weak.fp then np[cur.weak.fp] = true end
        -- (a Zubat-line one even before a Center visit names it the second catcher)
        for _, m in ipairs(party) do if m.fp and Team.weak_style(m.species) then np[m.fp] = true end end
        -- (the catcher may get any EXP - it only puts them to sleep: the
        -- user, 2026-11-09 "Butterfree over 15 would not matter")
        Fighter.no_partner = np
        local nf = {}
        for fp in pairs(np) do nf[fp] = true end
        Fighter.no_fight = nf
        local first = cur and cur.starter and cur.starter.fp or nil
        if not first then
            local line = {}
            for _, id in ipairs(starterLine) do line[id] = true end
            for _, m in ipairs(party) do if line[m.species] and not first then first = m.fp end end
        end
        Fighter.partner_first = first
    end
    -- The catchers' training (the hunt's, and the story's before Sprout Tower -
    -- the user, 2026-11-09: "put the 2 catcher levelings before sprout tower so
    -- they can benefit from the free xp": switch-training, the starter shares
    -- it). The future catcher first, to its sleep move (the user, 2026-11-08:
    -- "get it to 15 asap") - then a Center visit makes it the catcher (the
    -- second value: why); then catcher_plan (the catcher's sweet spot, the
    -- second catcher's level). Returns the trainee or nil, and a Center reason.
    local function role_next(party, story)
        local pr = Teamer.current and Teamer.current.prospect
        local centerWhy = nil
        if pr then
            -- (in the PC: a Center visit gets it - the Teamer there takes the
            -- future catcher out. The hunt's ask only (core_slots asks as the
            -- story and drops the reason), once per Pokemon: the user,
            -- 2026-11-10 - a shiny Caterpie waited in the box for hours while
            -- the hunt only ran, nobody got hurt, so no Center came)
            local inParty = false
            for _, m in ipairs(party) do if m.fp == pr.mon.fp then inParty = true end end
            if not story and not inParty and pr.mon.fp and not prospectFetch[pr.mon.fp] then
                prospectFetch[pr.mon.fp] = true
                centerWhy = string.format("%s, the future catcher, is in the PC - getting it at a Pokemon Center", Names[pr.mon.species] or "?")
            end
            for _, m in ipairs(party) do
                if m.fp == pr.mon.fp then
                    if m.level < pr.level then
                        return {fp = m.fp, species = m.species, level = m.level, target = pr.level,
                            why = "the future catcher - " .. (battleData.moves[pr.move] and battleData.moves[pr.move][1]:gsub("_", " "):lower() or "its sleep move") .. " there"}
                    elseif story or not prospectDone[m.fp] then
                        -- (the story asks till the Center visit - its done-check asks too)
                        if not story then prospectDone[m.fp] = true end
                        centerWhy = string.format("%s is Lv %d - it takes over as the catcher at a Pokemon Center", Names[m.species] or "?", m.level)
                    end
                end
            end
        end
        return catcher_plan(party), centerWhy
    end
    -- Who counts when one has fainted (the user, 2026-11-09: a Center only
    -- if fewer than 2 of them are over 70% HP): the starter, the
    -- specialists, the catcher once it's done levelling - while it (or the
    -- future one) still trains, only the starter and the specialists.
    if Collection.readSram then
        -- (the switch-training partner's slot: Fighter.partner_first - the starter)
        Walker.partner_slot = function()
            local fp = Fighter.partner_first
            if not fp then return nil end
            for _, m in ipairs(Collection.party()) do if m.fp == fp then return m.slot end end
            return nil
        end
        Walker.core_slots = function()
            local party = Collection.party()
            local cur = Teamer.current
            local want = {}
            if cur then
                if cur.starter and cur.starter.fp then want[cur.starter.fp] = true end
                for _, m in ipairs(cur.specialists or {}) do if m.fp then want[m.fp] = true end end
                if cur.catcher and cur.catcher.fp and section then
                    local okT, t = pcall(role_next, party, true)
                    if okT and not (t and t.fp == cur.catcher.fp) then want[cur.catcher.fp] = true end
                end
            end
            if not (cur and cur.starter) then
                local line = {}
                for _, id in ipairs(starterLine) do line[id] = true end
                for _, m in ipairs(party) do if line[m.species] then want[m.fp or ""] = true end end
            end
            local slots = {}
            -- (by the game's slot: an egg isn't in Collection.party's list)
            for _, m in ipairs(party) do if m.fp and want[m.fp] then slots[m.slot] = true end end
            return slots
        end
    end
    if section and Collection.readSram then
        local repicked = false
        Story.role_next = function()
            -- (the team as it is now - the start's pick came before the second
            -- catcher could be scored)
            if not repicked then
                repicked = true
                Teamer.current = Team.pick(Collection.for_team(starterLine), Teamer.current)
                say("Team as of now: " .. table.concat(Teamer.current.why, " | ") .. ".")
            end
            local party = Collection.party()
            mark_partners(party)
            local t, centerWhy = role_next(party, true)
            if centerWhy then return {center = centerWhy} end
            return t
        end
    end
    local ok, why = Story.run(steps, walkOpts)
    -- The story's done up to here: hunt the section's shinies (data/hunt.lua).
    local hunted = false
    if ok and section and Collection.readSram then
        package.loaded["data.hunt"] = nil
        package.loaded["data.evolve"] = nil
        local Hunt = require("data.hunt")
        local Evolve = require("data.evolve")
        Hunt.setup(World, State, Walker, Goals, Collection, say)
        package.loaded["data.joey"] = nil
        local Joey = require("data.joey")
        Joey.setup(State, World, Walker, Story, Mart, say)
        Joey.on_win = hooks.on_joey
        Hunt.joey = Joey
        -- Training while hunting: the team's fighters (starter + specialists)
        -- under the next big fight's top level +2, one at a time.
        -- The catcher first, but only to its sweet spot (data/sweet_spot.lua:
        -- the level it outspeeds every species still wanted here) - past it,
        -- fewer of them can be weakened safely; once there it's kept out of
        -- switch-training (Fighter.no_partner).
        -- A regular one for an empty catcher or second-catcher slot (the
        -- user, 2026-11-08: "2nd catcher and catcher are the only ones the
        -- bot should catch non-shiny, in the test and the real stream
        -- version"): only when nothing owned can do the job. The catcher
        -- first: a Caterpie, Metapod or Butterfree (the user's style,
        -- 2026-11-09); then the second catcher, if the catcher leaves weak
        -- target levels it can't weaken safely.
        local function wild_mon(sp, L) return {key = "wild", species = sp, level = L, dvs = {0x88, 0x88}, moves = SweetSpot.wild_moves(sp, L)} end
        Hunt.role_catch = function(time, spot)
            local pick = Team.pick(Collection.for_team(starterLine), Teamer.current)
            local test, job
            if not pick.catcher and not pick.prospect then
                job = "catcher"
                -- (a regular Caterpie, Metapod or Butterfree only - the
                -- user's style, 2026-11-09: Team.catcher_tier; trained to
                -- Sleep Powder at 15 however far off)
                test = function(m)
                    if not Team.catcher_tier(m) then return false end
                    return Team.catcher_score(m) ~= nil or Team.prospect(m, 100) ~= nil
                end
            elseif (pick.catcher or pick.prospect) and not pick.weak and Team.weak_score then
                -- (the Zubat right away - also while the future catcher still
                -- trains: then measured against what it will be)
                local c = pick.catcher or pick.prospect.as
                -- (needed at all? the catcher covers every weak level: no)
                local t = section_targets()
                local main = SweetSpot.main_cover(c, t)
                local left = false
                for _, x in ipairs(t) do for l = x.low, x.high do if not main[x.species .. ":" .. l] then left = true end end end
                if left then
                    job = "second catcher"
                    -- (a regular Zubat only - the user, 2026-11-09: Team.weak_ok)
                    test = function(m) return Team.weak_ok(m) and Team.weak_score(m, c) ~= nil end
                end
            end
            if not test then return nil end
            local want = {}
            for sp in pairs(Goals.spots(section)) do
                want[sp] = function(L) return test(wild_mon(sp, L)) end
            end
            return want, string.format("No %s yet, and nothing owned can do it - catching one regular Pokemon that can (a %s only).", job, job)
        end
        -- Where to go for a missing catcher (the user, 2026-11-09: "go into a
        -- place wherever zubat can get encountered right after training
        -- butterfree and catch it, into training, then the shiny hunting"):
        -- no catcher nor future one - a Caterpie line one; the Butterfree
        -- trained (an actual catcher) but no second catcher - a Zubat.
        Hunt.role_species = function()
            local pick = Team.pick(Collection.for_team(starterLine), Teamer.current)
            local want, job = {}, nil
            if not pick.catcher and not pick.prospect then
                job = "catcher"
                for id = 1, 251 do if Team.style_line(id) then want[#want + 1] = id end end
            elseif pick.catcher and not pick.weak then
                local t = section_targets()
                local main = SweetSpot.main_cover(pick.catcher, t)
                local left = false
                for _, x in ipairs(t) do for l = x.low, x.high do if not main[x.species .. ":" .. l] then left = true end end end
                if left then
                    job = "second catcher"
                    for id = 1, 251 do if Team.weak_style(id) then want[#want + 1] = id end end
                end
            end
            if #want == 0 then return nil end
            return want, job
        end
        Hunt.training = {
            next = function()
                local party = Collection.party()
                mark_partners(party)
                local c, centerWhy = role_next(party)
                if centerWhy then Hunt.needCenter = centerWhy end
                if c then return c end
                if not Story.next_big_fight() then return nil end
                local target = Story.target_level("next")
                for _, f in ipairs(Teamer.fighters()) do
                    for _, m in ipairs(party) do
                        if m.fp == f.fp and m.level < target then
                            return {fp = f.fp, species = m.species, level = m.level, target = target}
                        end
                    end
                end
                return nil
            end,
            -- (Teamer.front: a Center visit keeps the trainee in front too)
            front = function(fp) Teamer.front = fp; PC.order_party({fp}, {say = say}) end,
            restore = function()
                Teamer.front = nil
                if not Teamer.current then return end
                local _, order = Teamer.plan_moves(Teamer.current, Collection.party(), Collection.current_box(), 0, true)
                PC.order_party(order, {say = say})
            end,
            -- (hunting, nobody training: the catcher in front - put back
            -- through the party menu when not. The user, 2026-11-11: after a
            -- ball trip's Center stop Croconaw led the hunt for hours.)
            ensure_order = function()
                if Teamer.front or not Teamer.current then return end
                local party = Collection.party()
                local _, order = Teamer.plan_moves(Teamer.current, party, Collection.current_box(), 0, true)
                if Teamer.lead_out_of_place(order, party) then
                    say("The catcher isn't in front - putting the hunting order back.")
                    PC.order_party(order, {say = say})
                end
            end,
        }
        Evolve.setup(battleData, World, State, Walker, Goals, Collection, PC, Teamer, Fighter, say)
        walkOpts.allShiny = false   -- (only real shinies are caught - the testing switch is for the team)
        say(string.format("The story's done up to %s - now every shiny of %s.", section.leader or "the gym", section.name))
        -- Hunt, then evolve - and back to hunting if a copy has to be caught again.
        for _ = 1, 50 do
            ok, why = Hunt.run(section, walkOpts)
            if not ok then break end
            ok, why = Evolve.run(section, walkOpts)
            if ok or why ~= "catch" then break end
        end
        hunted = ok
    end
    local minutes = (emu.framecount() - f0) / 59.73 / 60
    local summary
    if ok and hunted then
        summary = string.format("%s: every shiny that holds up %s is caught and evolved - next, %s (not built yet). %.1f minutes at 1x.",
            section.name, section.leader or "the gym", section.leader or "the gym", minutes)
    elseif why == "box full" then
        summary = "Every PC box is full (or changing boxes didn't work) - a catch would have nowhere to go. Make room, then Start again."
    elseif ok then
        summary = string.format("Story stretch done - %d battles fought, %d run from, %.1f minutes at 1x.", fights, runs, minutes)
    elseif why == "shiny" then
        summary = "A SHINY and no way to catch it (no balls, or catching off) - stopped, it's all yours."
        client.pause()
    elseif why == "stopped" then
        summary = string.format("Stopped with the Stop button (after %.1f minutes).", minutes)
    else
        summary = string.format("Stopped: %s (after %.1f minutes).", tostring(why), minutes)
    end
    say(summary)
    if #Story.unknown > 0 then say(string.format("%d question(s) had no rule and got NO - see the log.", #Story.unknown)) end
    for _ = 1, 2 do joypad.set({}); emu.frameadvance() end
    return ok, why, summary
end

return M
