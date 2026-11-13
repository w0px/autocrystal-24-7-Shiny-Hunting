-- story_steps.lua (lives in modules/data/)
-- The story, from the player's room to Elder Li at the top of Sprout Tower
-- (the user's first stretch: after that the bot goes shiny hunting).
-- Played by data/story.lua: a step is skipped when it's done -
--   done = "EVENT_..."      that event flag is set (constants/event_flags.asm)
--   done = {balls = true}   there's a Poke Ball in the bag
--   done = {level = n}      the team's fighters (or the lead, without a team) are at level n+;
--                           n = "next": the next big fight's top level +2 (data/big_fights.lua)
--   done = {sleeper = true} something owned knows a sleep move (the catcher)
--   done = {owns = {names}} one of those species is owned (party or box)
--   done = {roles = true}   the catchers are trained (M.role_next has nobody left)
--   optional = true         not done after its actions: go on, try again next run
--   testOnly = true         skipped with SHINY_ONLY (the stream: no regular catches)
--   no done                 a walk: done once any later step is
-- actions, in order:
--   {go = {map, x, y}}               walk there (scene triggers on the way run)
--   {talk = {map, script}}           walk up to that person/thing and press A
--   {train = {map, level, near}}     fight wild ones there (grass, or a cave/tower floor),
--                                    each team fighter in turn up front
--   {catch = {map, species, times}}  catch one of those (not shiny) there, at those times of day
--   {roles = {map, near}}           train the catchers there (switch-training: the
--                                    future catcher, then the second catcher)
--   {puzzle = {map, x, y}}           a Ruins of Alph stone puzzle: stand at x, y facing up, A,
--                                    solve it (data/unown_puzzle.lua)
-- Maps by their pokecrystal names; tiles in steps (2 per block).

return {
    {name = "Downstairs - Mom gives the Pokegear", done = "EVENT_PLAYERS_HOUSE_MOM_1",
        -- (the right of her two trigger tiles, straight down from the stairs)
        actions = {{go = {"PlayersHouse1F", 9, 4}}}},

    {name = "Prof. Elm's lab - take Totodile", done = "EVENT_GOT_TOTODILE_FROM_ELM",
        -- (walking in starts Elm's scene; then the middle ball)
        actions = {{talk = {"ElmsLab", "TotodilePokeBallScript"}}}},

    {name = "Route 29, Cherrygrove, Route 30 - Mr. Pokemon's egg", done = "EVENT_GOT_MYSTERY_EGG_FROM_MR_POKEMON",
        -- (walking in starts his scene: the egg, then Prof. Oak and the Pokedex)
        actions = {{go = {"MrPokemonsHouse", 3, 6}}}},

    {name = "Back through Cherrygrove - the rival", done = "EVENT_RIVAL_CHERRYGROVE_CITY",
        -- (his trigger: the road east out of town; a battle you may lose)
        actions = {{go = {"CherrygroveCity", 33, 7}}}},

    {name = "Back to Elm - the police, then the egg", done = "EVENT_GAVE_MYSTERY_EGG_TO_ELM",
        -- (the officer's trigger, then Elm)
        actions = {{go = {"ElmsLab", 4, 5}}, {talk = {"ElmsLab", "ProfElmScript"}}}},

    {name = "Elm's aide - Poke Balls", done = {aideBalls = true},
        actions = {{go = {"ElmsLab", 4, 8}}}},

    -- The two catchers, caught early - the starter still weak enough to take
    -- them low with one hit, crits risked (a regular one may faint: the next
    -- one will do) - so few balls go on them (the user, 2026-11-09: 10 balls
    -- went at a full-HP Caterpie). The catcher: a Caterpie (Route 30, morning
    -- or day; trained to a Lv 15 Butterfree later). The second catcher: a
    -- Zubat (Dark Cave, off Route 31, any time; trained to Lv 8-9). At night
    -- there's no Caterpie: the step waits - the hunt goes for one later.
    {name = "Route 30 - a Caterpie, the future catcher", done = {owns = {"CATERPIE", "METAPOD", "BUTTERFREE"}}, optional = true,
        actions = {{catch = {map = "Route30", species = {"Caterpie"}, times = {"MORN", "DAY"}}}}},
    {name = "Dark Cave - a Zubat, the second catcher", done = {owns = {"ZUBAT", "GOLBAT", "CROBAT"}}, optional = true,
        actions = {{catch = {map = "DarkCaveVioletEntrance", species = {"Zubat"}}}}},

    -- (done once Violet's fly point is set - entering the city does it: a
    -- Center trip on the way then doesn't walk back to the Center's door
    -- just to tick this off - the user, 2026-11-09)
    {name = "Routes 29, 30, 31 - to Violet City (in front of the Pokemon Center)", done = {flypoint = 16},
        actions = {{go = {"VioletCity", 31, 26}}}},

    -- (the user, 2026-11-09: the catchers trained before Sprout Tower - the
    -- starter comes in to finish their fights and shares the EXP, and they
    -- aren't Lv 5 when a Sage's Bellsprout comes; done when there's nobody
    -- left to train them to)
    {name = "Train the catchers on Route 31 (the future catcher to its sleep move, the second catcher to its level)",
        done = {roles = true}, optional = true,
        actions = {{roles = {map = "Route31", near = {6, 7}}}}},

    {name = "Train the team on Route 31 for the next big fight (Elder Li: top Lv 10, so Lv 12)", done = {level = "next"},
        actions = {{train = {map = "Route31", level = "next", near = {6, 7}}}}},

    -- (no "catch a regular Gastly for the catcher" step any more - the user,
    -- 2026-11-08: only shinies are caught; it threw the last Poke Balls at
    -- one. The catcher comes from what's owned, or a shiny.)

    {name = "Sprout Tower - Elder Li (Flash)", done = "EVENT_GOT_HM05_FLASH",
        actions = {{talk = {"SproutTower3F", "SageLiScript"}}}},

    -- (the user, 2026-11-08: Falkner's gym trainers can be beaten before
    -- the hunt - money and EXP - just not Falkner: he ends the section.
    -- Abe stands nearer the door, then Rod. Never VioletGymFalknerScript.)
    {name = "Violet Gym - Bird Keeper Abe (not Falkner)", done = "EVENT_BEAT_BIRD_KEEPER_ABE",
        actions = {{talk = {"VioletGym", "TrainerBirdKeeperAbe"}}}},
    {name = "Violet Gym - Bird Keeper Rod (not Falkner)", done = "EVENT_BEAT_BIRD_KEEPER_ROD",
        actions = {{talk = {"VioletGym", "TrainerBirdKeeperRod"}}}},

    -- (the user, 2026-11-08: the Kabuto puzzle can be solved before Falkner
    -- - through the Route 32 gate, north of the badge guard - and it's what
    -- makes Unown appear in the Inner Chamber: letters A-K, so a shiny one
    -- is an I. The slab is at 3,2: stand below it, facing up.)
    {name = "Ruins of Alph - the Kabuto puzzle (Unown appear)", done = "EVENT_SOLVED_KABUTO_PUZZLE", optional = true,
        actions = {{puzzle = {"RuinsOfAlphKabutoChamber", 3, 3}}}},
}
