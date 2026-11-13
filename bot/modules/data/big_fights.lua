-- big_fights.lua (lives in modules/data/)
-- The big fights of the story in the order they come, for the training
-- rule (the user's, 2026-11-07): the team's fighters train to the top level
-- of the NEXT one not beaten yet, +2 (data/story.lua, a train step with
-- level = "next").
--
-- trainer: "CLASS:NAME" in battle_data.lua's trainers (the highest level in
-- that party, from the game's data/trainers/parties.asm).
-- beaten: the event flag the game sets when it's won.
--
-- Rivals aren't here: the game sets their flags at the start of a new game
-- (to hide him), so they don't say "beaten" - and each rival fight comes
-- before a gym leader at least as strong (16/Bugsy 16, 22 then Morty 25,
-- 32 then Clair 40), so the target only ever ends up the same or higher.

return {
    {name = "Elder Li (Sprout Tower)", trainer = "SAGE:LI", beaten = "EVENT_BEAT_SAGE_LI"},
    {name = "Falkner", trainer = "FALKNER:FALKNER1", beaten = "EVENT_BEAT_FALKNER"},
    {name = "Bugsy", trainer = "BUGSY:BUGSY1", beaten = "EVENT_BEAT_BUGSY"},
    {name = "Whitney", trainer = "WHITNEY:WHITNEY1", beaten = "EVENT_BEAT_WHITNEY"},
    {name = "Morty", trainer = "MORTY:MORTY1", beaten = "EVENT_BEAT_MORTY"},
    {name = "Chuck", trainer = "CHUCK:CHUCK1", beaten = "EVENT_BEAT_CHUCK"},
    {name = "Jasmine", trainer = "JASMINE:JASMINE1", beaten = "EVENT_BEAT_JASMINE"},
    {name = "Pryce", trainer = "PRYCE:PRYCE1", beaten = "EVENT_BEAT_PRYCE"},
    {name = "Clair", trainer = "CLAIR:CLAIR1", beaten = "EVENT_BEAT_CLAIR"},
    {name = "Will", trainer = "WILL:WILL1", beaten = "EVENT_BEAT_ELITE_4_WILL"},
    {name = "Koga", trainer = "KOGA:KOGA1", beaten = "EVENT_BEAT_ELITE_4_KOGA"},
    {name = "Bruno", trainer = "BRUNO:BRUNO1", beaten = "EVENT_BEAT_ELITE_4_BRUNO"},
    {name = "Karen", trainer = "KAREN:KAREN1", beaten = "EVENT_BEAT_ELITE_4_KAREN"},
    {name = "Lance", trainer = "CHAMPION:LANCE", beaten = "EVENT_BEAT_CHAMPION_LANCE"},
}
