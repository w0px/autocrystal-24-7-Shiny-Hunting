-- sections.lua (lives in modules/data/)
-- The run in sections, each ending at a gym (the user's loop, 2026-11-08):
-- story up to the gym -> hunt every shiny the section has (data/goals.lua:
-- a living dex) -> evolve what has to be -> beat the gym -> next section.
--
-- maps: where wild Pokemon can be met in the section, by the game's map
-- constants (the wild tables' names). Only what's reachable then - e.g.
-- before Falkner Route 32 is behind the badge guard (Route32CooltrainerM
-- at 18,8 - its Ruins of Alph gate at 4,2 is north of him), Dark Cave only
-- its Violet entrance before the rocks (worked out 2026-11-04, pre-Falkner
-- economy notes). Route 46: its north is one-way, but the grass just past
-- the Route 29 gate is open - Phanpy (morning), Spearow (the user spotted
-- Phanpy missing, 2026-11-08; checked with world.lua's planner). The Ruins'
-- outside grass (Natu, Smeargle) is on the side reached through Union
-- Cave - after Falkner. The Inner Chamber's Unown need a chamber puzzle
-- solved first: the Kabuto one is reachable before Falkner (the user,
-- 2026-11-08 - a story step), letters A-K, so the shiny one is an I.
-- locked[map]: the event flag that opens a map's wild Pokemon - until it's
-- set, the map isn't in the section's goals (data/goals.lua's M.flag).
-- methods: how wild ones are met: "walk" (grass, caves) now; "surf",
-- "fish", "headbutt" once the bot can.
-- gym: the event flag that says the section is over.

return {
    {name = "Before Falkner", gym = "EVENT_BEAT_FALKNER", leader = "Falkner",
        maps = {"ROUTE_29", "ROUTE_30", "ROUTE_31", "ROUTE_36", "SPROUT_TOWER_2F", "SPROUT_TOWER_3F", "DARK_CAVE_VIOLET_ENTRANCE", "ROUTE_46",
            "RUINS_OF_ALPH_INNER_CHAMBER"},
        locked = {RUINS_OF_ALPH_INNER_CHAMBER = "EVENT_SOLVED_KABUTO_PUZZLE"},
        methods = {walk = true}},
}
