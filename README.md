<p align="center">
  <img src="images/banner.png" alt="autocrystal - 24/7 Shiny Hunting - Pokémon Crystal, live" width="480">
</p>

<p align="center">
  <b>The open-source bot behind the 24/7 Shiny Hunting stream, playing Pokémon Crystal</b><br>
  Built on <a href="https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit">autocrystal</a>, the shiny hunting user bot you can run yourself.
</p>

<p align="center">
  <a href="https://discord.gg/3PMwdtcM87"><b>Discord</b></a> ·
  <a href="https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit"><b>autocrystal user bot</b></a> ·
  <a href="FAQ.md"><b>FAQ</b></a>
</p>

## Table of Contents

- [The Challenge](#the-challenge)
- [The Ground Rules](#the-ground-rules)
- [How a Section Works](#how-a-section-works)
- [The Sections and How Long They Take](#the-sections-and-how-long-they-take)
- [Picking Targets: Where and When to Hunt](#picking-targets-where-and-when-to-hunt)
- [The Team](#the-team)
- [Catching a Shiny](#catching-a-shiny)
- [Battles](#battles)
- [Evolutions](#evolutions)
- [Money and Shopping](#money-and-shopping)
- [Healing](#healing)
- [Getting Around](#getting-around)
- [The PC](#the-pc)
- [Rare Moments](#rare-moments)
- [The Stream and Discord](#the-stream-and-discord)
- [The Code](#the-code)
- [Status](#status)

## The Challenge

A **shiny living dex**, section by section, in a real playthrough of Pokémon Crystal.

The game is split into sections, one per gym. In each section the bot catches a shiny of **every Pokémon it can find there** before it moves on: from the common ones at 30% to the 1% ones that take months. Then it evolves what needs evolving, beats the gym leader, plays the story to the next gym, and starts again.

It's a *living* dex: one shiny for every form. Three shiny Zubat means one stays a Zubat, one becomes a Golbat, one a Crobat.

## The Ground Rules

- **Normal speed.** The game runs at 1x, like on a Game Boy. No fast-forward.
- **Vanilla.** An unmodified English Pokémon Crystal ROM. The bot only presses buttons and reads the game's memory, like a player looking at the screen.
- **No resets.** A shiny that faints or runs away is gone. No retries, no rollbacks, no save scumming.
- **Savestates only for crashes.** If the PC or emulator crashes, the stream carries on from the last automatic save. Never to undo something that happened in the game.
- **Real time.** The game clock follows the real clock, so morning, day and night on stream are morning, day and night where the bot runs.

## How a Section Works

Each section ends at a gym. Inside a section the bot loops:

1. **Story** up to the next gym: the events, trainers and items on the way.
2. **Hunt** until every shiny the section offers is caught.
3. **Evolve** whatever has to be evolved for the living dex.
4. **Beat the gym leader**, then on to the next section.

The first section is everything before Falkner's gym: Routes 29 to 31, Route 36 up to Sudowoodo, the south of Route 46, Sprout Tower, Dark Cave's first room and the Ruins of Alph's inner chamber. That's 45 forms, from Rattata to a 1% Dunsparce.

**Trade evolutions are left out** (Gengar, Golem, Machamp, Alakazam, Politoed, Steelix, ...): the bot plays alone, there's nobody to trade with.

## The Sections and How Long They Take

Each section only needs what the ones before it didn't give: a Pidgey line finished before Falkner isn't hunted again.

| # | Section | New places to hunt | Shinies to catch | Rarest ones still needed | Typical time | 1 in 10 runs |
|---|---|---|---|---|---|---|
| 1 | Before Falkner | Routes 29-31, Route 36, south of Route 46, Sprout Tower, Dark Cave's first room, Ruins of Alph's inner chamber | 42 | Dunsparce 1%, Teddiursa 5% (morning), Hoppip 5%, Weedle 5% | **2.3 years** | under 1.5 / over 3.5 years |
| 2 | Before Bugsy | Route 32, Ruins of Alph, Union Cave, Route 33, Slowpoke Well | 12 | Onix 10%, Smeargle 10%, Slowpoke 15% | **4 months** | under 3 / over 7 months |
| 3 | Before Whitney | Ilex Forest, Routes 34-35, National Park | 22 | Yanma 1%, Ditto 5%, Jigglypuff 5%, Paras 5% | **10 months** | under 6 / over 21 months |
| 4 | Before Morty | Route 37, Burned Tower | 3 | Stantler 40%, Koffing 59% (two: one becomes the Weezing) | **12 days** | under 4 days / over 1 month |
| 5 | Before Chuck | Routes 38-39 | 6 | Miltank 5%, Tauros 5% | **3.5 months** | under 1 / over 8 months |
| 6 | Before Jasmine | Whirl Islands | 4 | Seel 25%, Krabby 60% | **1 month** | under 2 / over 7 weeks |
| 7 | Before Pryce | Route 42, Mt. Mortar, Route 43 | 5 | Machop 20%, Farfetch'd 20%, Marill 20% | **2 months** | under 5 weeks / over 4 months |
| 8 | Before Clair | Route 44, Ice Path | 7 | Sneasel 10%, Jynx 10% | **3 months** | under 6 weeks / over 7 months |
| | **All of Johto** | | **101** | | **about 4.7 years** | under 3.7 / over 6 years |

*Typical time* is the median: half the runs are faster, half slower. *1 in 10 runs* is how fast the luckiest tenth and how slow the unluckiest tenth are. A percentage is the best chance to meet that Pokémon in one encounter anywhere in the section.

**Where the numbers come from:** the bot's own planner, run 100 times through all eight sections with the game's real encounter tables, 1 in 8,192 shinies and 1x speed (one encounter every 23 to 34 seconds, measured on the bot). Every shiny is caught, and each section's evolutions are done before its gym, so a Pidgeotto evolved before Falkner isn't hunted again later. It counts the hunt only: the story, training and evolving add days, not months.

**What can change them:** for now the bot hunts by walking, in grass and caves. Surfing, fishing and Headbutt add more Pokémon to each section once the bot can do them, so the real sections will be longer. The sections after Falkner are the plan and may still move around. Kanto and the Elite Four come after Clair.

## Picking Targets: Where and When to Hunt

Every Pokémon has its own places and times: Gastly only at night, Teddiursa only in the morning, Dunsparce at 1% in Dark Cave. The bot knows every encounter table of the game, by map and time of day.

- **A plan for the whole section.** The bot works out how many hours of each morning, day and night to spend where, so the section is finished as soon as possible. Every encounter counts, however rare the Pokémon it's still waiting for.
- **Time-only Pokémon first.** If something only shows up at night, the night is spent on it first.
- **A dice roll.** Where to go next is rolled, weighted by the plan. That gives the stream variety, and nothing waits forever.
- **It stays.** The bot re-rolls only when the time of day changes or after a catch, so it doesn't hop between routes every few minutes.
- **Its targets on screen.** The overlay shows the current targets, rarest and map-exclusive ones first, and the next rotation ("at 6 PM: Route 31").

## The Team

<p align="center">
  <img src="images/team.png" alt="The team: starter, catcher, weakener, specialist, HM slave" width="640">
</p>

Six slots, each with a job:

- **The starter** (Totodile) fights the story battles and gym leaders.
- **The catcher** puts the shiny to sleep. Always the **Butterfree line** for its Sleep Powder: a regular Caterpie is trained up until a shiny Butterfree takes over.
- **The weakener** brings the shiny's HP down safely. Always a **Zubat**, trained to the level where it can't knock out even the weakest target with a critical hit. A shiny Zubat replaces the regular one.
- **Up to two specialists**, both shiny catches from the run, picked once Falkner is beaten. They're chosen by level, type coverage and rarity, a third each, so a rare shiny beats a common one of the same strength.
- **The HM slave** carries the field moves (Cut, Surf, Strength, Whirlpool, ...) so nobody else has to. It's the **first shiny Sentret** the bot catches, evolved into a Furret. The only Pokémon that can take its job is a **shiny Krabby**, levelled into a Kingler.

The catcher and the weakener are the only jobs a regular Pokémon may do. Everything else is a shiny the bot caught itself. When a better shiny comes along, it takes the job: the bot walks to a Pokémon Center, swaps it in from the PC and trains it.

**Training:** specialists are trained to the next big fight's top level + 2 (Falkner's Pidgeotto is Lv 9, so Lv 11). A trainee fights alone when it wins comfortably, for double EXP, and switches out at the start of a fight otherwise, to share it.

## Catching a Shiny

When a shiny appears:

1. **Sleep.** The catcher uses its sleep move until the shiny is asleep, as often as it takes.
2. **Weaken.** The weakener hits it down to about 40% HP, only with moves that **can't knock it out even with a critical hit and the highest damage roll**. The bot does the game's own damage maths for every hit.
3. **Throw.** The best ball for the moment: Ultra, Great, then Poké Ball, or a Level Ball when the levels allow it. Never a Master Ball.

If the shiny wakes up, it's put back to sleep. If the weakener falls asleep, the bot waits it out or brings in another one. While the shiny can be put to sleep, a critical hit is never risked: no safe hit left means throwing balls.

## Battles

Every battle uses the real numbers from the game: types, stats, stat changes, moves and damage rolls.

- **Best move:** the one that knocks the opponent out fastest, counting accuracy. Stat moves (Leer, Growl, ...) are used when they save a turn and it's safe.
- **Switching:** to a teammate that clearly does better, after a faint to the best matchup, and when the trainer's next Pokémon is a bad match.
- **Running:** from wild Pokémon that are a bad idea. A super-effective move, one that can poison, paralyse or put to sleep, or nothing of ours that hurts it.
- **New moves** are learned only when they're stronger; HMs and the catcher's sleep move are never forgotten.
- **Potions in battle** when the active Pokémon is low and no Pokémon Center is near.

## Evolutions

- **Level evolutions** (Pidgeot at 36, Jumpluff at 27, ...) are trained up before the section's gym.
- **Rare evolved forms are evolved, not hunted.** The Burned Tower has a 1% Weezing, but Koffing is 59% there, so the bot catches a second shiny Koffing and trains it to Lv 35. This applies whenever the pre-evolution is met at least twice as often in the section. A shiny Weezing that turns up anyway still counts.
- **Friendship evolutions** (Crobat) are walked and fought until happy.
- **Stone evolutions** happen when the stone is available. They never hold up a section.
- The Pokémon that has to **stay unevolved** for the living dex is kept from evolving: the bot presses B during the evolution, like a player would.

## Money and Shopping

Money comes from **Youngster Joey**. The bot takes his phone number (and nobody else's), and every time he calls for a rematch it goes to fight his Rattata: **$64** a win. Cave maps have no phone signal, so the bot weighs that in when it's waiting for his call.

- **Poké Balls first.** Once there are fewer than 90 balls and enough money, the bot buys a stack at the nearest Poké Mart, up to 99.
- **Then savings.** With a full bag, Joey's rematches carry on until there's a $100,000 cushion.
- **Supplies.** Five potions and three Antidotes are kept, never Energy Powder or Energy Root (they cost friendship).
- **A floor.** $500 always stays for emergencies.

## Healing

- **Pokémon Center first.** When the lead is low on HP, has a status, or runs out of PP for its attacks or sleep move, the bot walks to a Center.
- **Before the first badge**, it's always the Center: Cherrygrove and Violet are never far.
- **In caves** a strong team fights on: one Pokémon may faint while the others are healthy.
- **Potions and Antidotes** only when no Center is in reach.

## Getting Around

The bot has a map of the whole game, made from the game's own data: every map, every wall, ledge, door, cave and route connection.

- **Routes** are planned like a player would walk them: around trainers it hasn't fought, around tall grass when it's not hunting, and over ledges only in the right direction.
- **Hunting** means walking loops through the grass or cave, not standing still.
- **Story events** are found by their flags in the game's memory, the same way the game knows what has happened.

## The PC

The party has 6 slots, a box has 20. The bot uses **Bill's PC** itself:

- deposits shinies that aren't on the team;
- withdraws the ones it needs, e.g. one set aside to evolve, or a new team member;
- **changes boxes** when one is full. In Gen 2 that saves the game, so the bot answers that prompt only when it's sure it's on its own save.

Releasing Pokémon is never done: every menu step is checked before pressing A.

## Rare Moments

Beyond shinies the bot watches for everything rare and calls it out on the stream overlay:

- **Perfect DVs** (15/15/15/15) and **0/0/0/0**: 1 in 65,536 each
- **Almost shiny:** only the Attack DV kept it from being shiny
- **Four of a kind** DVs, like 7/7/7/7: 1 in 4,681
- **DV records:** the highest and lowest of the run
- **Streaks:** the same Pokémon many times in a row, with the odds
- **Droughts:** no shiny for a long time, and how rare that is
- **Milestones:** 10,000 encounters, the 1,000th Zubat, the 5th shiny Pidgey, ...

## The Stream and Discord

- **The overlay** is drawn in the game's own style: Gen 2 text boxes, fonts and sprites. It shows the current encounter, recent shinies, the wild Pokémon here, the targets, and a log of what the bot is doing and why.
- **[Discord](https://discord.gg/3PMwdtcM87):** every shiny, perfect DV and 0/0/0/0 is posted in #shinies the moment it shows up: sprite, DVs, Hidden Power, how often that species has been met, and whether the catch worked. New autocrystal releases are posted there too, and a daily report is coming.

## The Code

The stream bot is open source, and it's all in this repository:

- **`bot/`** is the bot itself, Lua scripts for BizHawk. `launcher.lua` starts it; `modules/play.lua` plays the game: story, hunting, battles, healing, shopping and the team; `modules/data/` holds the planner, walker, battle logic, team, PC, Mart and the game's data (maps, encounter tables, moves, built from the pokecrystal disassembly by `tools/`). The hunting modules (`wild.lua`, `fishing.lua`, `headbutt.lua`, ...) are the same ones the [autocrystal user bot](https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit) uses.
- **`bot/overlay/`** is the stream overlay: browser pages for OBS, drawn with the game's own tiles and font, fed by a small relay the bot talks to.
- **`discord-server/`** holds the Python tools that set up the [Discord server](https://discord.gg/3PMwdtcM87) and post releases, daily logs and the autocrystal README there.

**Running it yourself:** put [BizHawk 2.11.1](https://github.com/TASEmulators/BizHawk/releases) into `BizHawk\` and your own Pokémon Crystal ROM wherever you like, then double-click `start.bat`. Sprites come from the Stats window's **Download sprites...** button, like in the user bot. The overlay needs the game's graphics in `bot/overlay/gfx/`, copied from the [pokecrystal disassembly](https://github.com/pret/pokecrystal); they aren't in this repository.

## Status

The bot is in testing: the story up to Sprout Tower, the first section's hunt, the team, catching, the PC, money and evolutions are built. The gym and the sections after Falkner come next, so expect the code to change a lot.
