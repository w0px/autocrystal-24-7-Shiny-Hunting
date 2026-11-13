<p align="center">
  <img src="images/banner.png" alt="autocrystal - 24/7 Shiny Hunting - Pokémon Crystal, live" width="480">
</p>

<p align="center">
  <b>The open-source bot behind the 24/7 Shiny Hunting stream, playing Pokémon Crystal</b><br>
  Nobody is playing: the bot makes every decision itself, from the story to the team to where it hunts.<br>
  Built on <a href="https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit">autocrystal</a>, the shiny hunting user bot you can run yourself.
</p>

<p align="center">
  <a href="https://discord.gg/3PMwdtcM87"><b>Discord</b></a> ·
  <a href="https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit"><b>autocrystal user bot</b></a> ·
  <a href="HOW-IT-WORKS.md"><b>How it works, in detail</b></a> ·
  <a href="FAQ.md"><b>FAQ</b></a>
</p>

## Table of Contents

- [Nobody's Playing: the Bot Decides](#nobodys-playing-the-bot-decides)
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

## Nobody's Playing: the Bot Decides

There's no one behind the controller and no one steering from the side. Once it's started, the bot runs the whole game on its own and makes every decision itself:

| The bot... | How it decides |
|---|---|
| **plays the story** | walks to each event, talks to people, fights the trainers in its way and picks up what the story needs, found by the game's own event flags |
| **decides where and when to hunt** | works out the best plan for the whole section from every encounter table, then rolls where to go next ([Picking Targets](#picking-targets-where-and-when-to-hunt)) |
| **builds its team** | picks the catcher, the weakener, two specialists and the HM slave from what it has caught, scoring every possible team ([The Team](#the-team)) |
| **replaces team members** | swaps in a better shiny when one comes along: walks to a Pokémon Center, uses the PC, trains the newcomer |
| **trains** | decides who needs levels, how many, where, and whether a Pokémon fights alone or switch-trains |
| **catches the shinies** | sleep, safe weakening, ball choice: worked out turn by turn from the game's damage and catch formulas ([Catching a Shiny](#catching-a-shiny)) |
| **fights every battle** | picks moves, switches and runs from bad fights ([Battles](#battles)) |
| **evolves the dex** | decides which copy evolves and which stays, and trains it there ([Evolutions](#evolutions)) |
| **farms its own money** | takes Joey's number, answers his calls, beats him again and again, and saves up ([Money and Shopping](#money-and-shopping)) |
| **shops and heals** | buys balls and potions when it needs them, and decides when a Pokémon Center is worth the walk ([Healing](#healing)) |
| **runs its PC** | deposits, withdraws and changes boxes ([The PC](#the-pc)) |

What people decide is the **rules**: this README, written into the bot's code before the run, plus a few settings (like the HP to heal at). During the run nobody picks a route, a team member or a move.

## The Challenge

A **shiny living dex**, section by section, in a real playthrough of Pokémon Crystal.

The game is split into sections, one per gym. In each section the bot catches a shiny of **every Pokémon it can find there** before it moves on: from the common ones at 30% to the 1% ones that take months. Then it evolves what needs evolving, beats the gym leader, plays the story to the next gym, and starts again.

It's a *living* dex: one shiny for every form. Three shiny Zubat means one stays a Zubat, one becomes a Golbat, one a Crobat.

## The Ground Rules

- **Normal speed.** The game runs at 1x, like on a Game Boy. No fast-forward.
- **Vanilla.** An unmodified English Pokémon Crystal ROM. The bot only presses buttons and reads the game's memory, like a player looking at the screen.
- **No resets for wild Pokémon.** A shiny that faints or runs away is gone. No retries, no rollbacks, no save scumming.
- **Soft resets only for one-time Pokémon.** Sudowoodo, the legendaries, gifts and the like appear once per game, so the bot resets for them like players reset for a shiny starter. See the [FAQ](FAQ.md#what-about-pokémon-you-only-meet-once).
- **No breeding.** Every shiny is a wild one (or a one-time Pokémon). Breeding would make eggs shiny 1 in 64; see the [FAQ](FAQ.md#why-no-breeding) for what that leaves out of reach.
- **Savestates only for crashes.** If the PC or emulator crashes, the stream carries on from the last automatic save. Never to undo something that happened in the game.
- **Real time.** The game clock follows the real clock, so morning, day and night on stream are morning, day and night where the bot runs.

## How a Section Works

Each section ends at a gym. Inside a section the bot loops, deciding each step itself:

1. **Story** up to the next gym: it plays the events, trainers and items on the way.
2. **Hunt** until every shiny the section offers is caught: it plans where to go, builds and retrains its team, and farms money as it needs it.
3. **Evolve** whatever has to be evolved for the living dex: it picks the copies and trains them.
4. **Beat the gym leader**, then on to the next section.

The first section is everything before Falkner's gym: Routes 29 to 31, Route 36 up to Sudowoodo, the south of Route 46, Sprout Tower, Dark Cave's first room and the Ruins of Alph's inner chamber. That's 45 forms, from Rattata to a 1% Dunsparce.

**Trade evolutions are left out** (Gengar, Golem, Machamp, Alakazam, Politoed, Steelix, ...): the bot plays alone, there's nobody to trade with.

## The Sections and How Long They Take

Each section only needs what the ones before it didn't give: a Pidgey line finished before Falkner isn't hunted again. Every way the game offers to meet a wild Pokémon counts, from the section that unlocks it: the **Old Rod** after Falkner, **Headbutt** in Ilex Forest, **Rock Smash** after Sudowoodo, **Surf** and the **Good Rod** after Morty, and the swarm callers once their numbers are in the phone. A new method also opens up the places from earlier sections.

| # | Section | New places and methods | Shinies to catch | Rarest ones still needed | Typical time | Lucky / unlucky (1 in 10 runs) |
|---|---|---|---|---|---|---|
| 1 | Before Falkner | Routes 29-31, Route 36, south of Route 46, Sprout Tower, Dark Cave's first room, Ruins of Alph's inner chamber | 42 | Dunsparce 1%, Teddiursa 5% (morning), Phanpy 5% (morning), Hoppip 5%, Weedle 5% | **2.8 years** | 1.9 / 4.4 years |
| 2 | Before Bugsy | Routes 32-33, Ruins of Alph, Union Cave, Slowpoke Well; **Old Rod**; Ralph's Qwilfish swarm | 21 | Onix 10%, Smeargle 10%, Qwilfish 15% (swarm), Krabby, Goldeen, Tentacool 15% (Old Rod) | **12 months** | 9 / 16 months |
| 3 | Before Whitney | Ilex Forest, Routes 34-35, National Park; **Headbutt**; Arnie's Yanma swarm; the **Bug-Catching Contest** | 27 + Scyther and Pinsir | Ditto 5%, Jigglypuff 5%, Paras 5%, Aipom and Exeggcute 20% (rare trees); Scyther and Pinsir 5% (Contest only) | **11 months**, plus the Contest | 8 / 16 months |
| 4 | Before Morty | Route 37, Burned Tower; **Rock Smash** | 4 | Shuckle 10% (rocks), Stantler 40%, two Koffing (one becomes the Weezing) | **2 months** | 6 weeks / 5 months |
| 5 | Before Chuck | Routes 38-41, Olivine, Cianwood; **Surf** and the **Good Rod** | 12 | Tauros 5%, Miltank 5%, Mantine 10% (surfing), Staryu, Corsola, Shellder 10% (Good Rod) | **9 months** | 6 / 14 months |
| 6 | Before Jasmine | Whirl Islands | 4 | Seel 25%, Horsea 30% (surfing) | **8 weeks** | 6 weeks / 3 months |
| 7 | Before Pryce | Route 42, Mt. Mortar, Route 43, Lake of Rage | 5 | Farfetch'd 20%, Machop 20%, Marill 30% (surfing) | **3 months** | 7 weeks / 5 months |
| 8 | Before Clair | Route 44, Ice Path, Route 45, Dark Cave's Blackthorn side | 13 | Skarmory 5%, Jynx 10%, Sneasel 10%, Dratini 10% (Good Rod) | **10 months** | 6 / 15 months |
| | **Johto without the Contest** | | **128** | | **about 7.3 years** | 5.7 / 9.1 years |
| | **Johto with the Contest** | | **130** | | **about 29 years** | the Contest decides it |

*Typical time* is the median: half the runs are faster, half slower. *Lucky / unlucky* is how fast the luckiest tenth and how slow the unluckiest tenth of the runs are. A percentage is the best chance to meet that Pokémon in one encounter anywhere in the section.

### The Bug-Catching Contest

Scyther and Pinsir live **only** in the Bug-Catching Contest in National Park, at 5% each. The contest is the slowest part of the whole challenge by far:

| | |
|---|---|
| When | Tuesdays, Thursdays and Saturdays, once a day |
| How long | 20 minutes |
| Encounters | about **57 a contest**: in the contest, 40% of steps in the extra-tall grass meet something (20% elsewhere), so nearly all of it is battles at ~21 seconds each |
| A year | about **8,900** contest encounters |
| One shiny Scyther (or Pinsir) | 8,192 ÷ 0.05 = 163,840 encounters: **about 18 years** on average |
| Both | **about 22.5 years** (half of all runs), **27.5** on average; 7 years for the luckiest tenth, 54 for the unluckiest |

Without breeding there's no faster way, and as the rules stand the Whitney section waits for them: that's what turns about 7 years into about 29. The bot hunts everything else in between contests.

### One-time Pokémon

About a dozen in Johto (Togepi, Spearow, Eevee, Sudowoodo, Raikou, Entei, Shuckle, Lapras, the Electrodes, Tyrogue, Suicune): soft resets, about 5 days each at normal speed. They add about 2 months in all. The red Gyarados is always shiny.

### Where the numbers come from

**The hunt:** the bot's own planner, run 100 times through all eight sections with every wild table of the game (grass, caves, water, both rods, headbutt trees, rocks, swarms), 1 in 8,192 shinies and normal speed, with each section's level evolutions done before its gym. The speeds:

| | Seconds per encounter | Source |
|---|---|---|
| Grass | ~23 | measured on the bot: 145-160 an hour |
| Dark Cave | ~27 | measured: 128 an hour |
| Sprout Tower | ~42 | measured: 85 an hour |
| Surfing | 25-34 | the water's encounter rate, like grass |
| Fishing | ~31 | estimate: two casts per bite, then the battle |
| Headbutt | 28-33 | estimate: rare trees 80%, good trees 50% |
| Rock Smash | ~50 | estimate: 40% per rock, rocks come back on a map change |

A swarm is counted as running 60% of the time once its caller's number is in the phone, and every tree map is assumed to have a rare tree for the bot's Trainer ID.

**Rounded up for real life**, because the simulation is the best case in a few ways:

- **+10% for whole days that aren't hunting:** Joey, Pokémon Centers, catches. Measured on the bot over whole game days.
- **+10% for lost shinies:** the simulation catches every shiny. In the real game a shiny can flee or faint, and then that Pokémon is hunted again.
- **+5% for downtime:** crashes, updates and maintenance.
- **+2 weeks per section** for the story, training, evolving and the gym.

So the times above are about a quarter longer than the simulation itself.

**What can still change them:** the sections after Falkner are the plan and may still move around, and the fishing, Headbutt and Rock Smash speeds are estimates until the bot does them. The Super Rod, Kanto and the Elite Four come after Clair.

## Picking Targets: Where and When to Hunt

*The maths and an example: [the planner](HOW-IT-WORKS.md#1-where-to-hunt-the-planner) and [the roll](HOW-IT-WORKS.md#2-the-roll-picking-a-spot).*

Nobody tells the bot where to go: it decides where and when to hunt by itself.

Every Pokémon has its own places and times: Gastly only at night, Teddiursa only in the morning, Dunsparce at 1% in Dark Cave. The bot knows every encounter table of the game, by map and time of day.

- **A plan for the whole section.** The bot works out how many hours of each morning, day and night to spend where, so the section is finished as soon as possible. Every encounter counts, however rare the Pokémon it's still waiting for.
- **Time-only Pokémon first.** If something only shows up at night, the night is spent on it first.
- **A dice roll.** Where to go next is rolled, weighted by the plan. That gives the stream variety, and nothing waits forever.
- **It stays.** The bot re-rolls only when the time of day changes or after a catch, so it doesn't hop between routes every few minutes.
- **Its targets on screen.** The overlay shows the current targets, rarest and map-exclusive ones first, and the next rotation ("at 6 PM: Route 31").

## The Team

*Why Butterfree and Zubat, and why Zubat stops at Lv 8-10: [the catching crew](HOW-IT-WORKS.md#3-the-catching-crew-why-butterfree-and-zubat); how the team is scored: [picking the team](HOW-IT-WORKS.md#8-picking-the-team).*

<p align="center">
  <img src="images/team.png" alt="The team: starter, catcher, weakener, specialist, HM slave" width="640">
</p>

The bot builds its own team. Nobody picks a team member: the bot decides who fills each job from the Pokémon it has caught, and replaces them when something better comes along. Six slots, each with a job:

- **The starter** (Totodile) fights the story battles and gym leaders.
- **The catcher** puts the shiny to sleep. Always the **Butterfree line**: Sleep Powder lands 75% of the time (Hypnosis 60%), and at Lv 15 Butterfree outspeeds every wild Pokémon before Falkner. A regular Caterpie is trained to Lv 15 until a shiny one takes over.
- **The weakener** brings the shiny's HP down safely. Always a **Zubat**: its Leech Life is the only move before Falkner that hurts every target, Ghost-type Gastly included, without risking a knockout. It's trained to Lv 8-10, depending on its Attack DV. A shiny Zubat replaces the regular one. ([Why these two, in numbers](FAQ.md#why-does-the-bot-catch-with-a-caterpie-and-a-zubat-in-the-first-section))
- **Up to two specialists**, both shiny catches from the run, picked once Falkner is beaten. They're chosen by level, type coverage and rarity, a third each, so a rare shiny beats a common one of the same strength.
- **The HM slave** carries the field moves (Cut, Surf, Strength, Whirlpool, ...) so nobody else has to. It's the **first shiny Sentret** the bot catches, evolved into a Furret. The only Pokémon that can take its job is a **shiny Krabby**, levelled into a Kingler.

The catcher and the weakener are the only jobs a regular Pokémon may do. Everything else is a shiny the bot caught itself. When a better shiny comes along, the bot gives it the job on its own: it walks to a Pokémon Center, swaps the newcomer in from the PC and trains it.

**Training:** the bot decides who needs levels and trains them itself. Specialists are trained to the next big fight's top level + 2 (Falkner's Pidgeotto is Lv 9, so Lv 11). A trainee fights alone when it wins comfortably, for double EXP, and switches out at the start of a fight otherwise, to share it.

## Catching a Shiny

*Turn by turn, with every limit: [catching a shiny](HOW-IT-WORKS.md#4-catching-a-shiny-turn-by-turn).*

When a shiny appears, the bot catches it by itself, deciding every turn:

1. **Sleep.** The catcher uses its sleep move until the shiny is asleep, as often as it takes.
2. **Weaken.** The weakener hits it down to about 40% HP, only with moves that **can't knock it out even with a critical hit and the highest damage roll**. The bot does the game's own damage maths for every hit.
3. **Throw.** The best ball for the moment: Ultra, Great, then Poké Ball, or a Level Ball when the levels allow it. Never a Master Ball.

If the shiny wakes up, it's put back to sleep. If the weakener falls asleep, the bot waits it out or brings in another one. While the shiny can be put to sleep, a critical hit is never risked: no safe hit left means throwing balls.

## Battles

*Move choice, switching, running and training in detail: [battles](HOW-IT-WORKS.md#5-battles).*

The bot fights every battle itself: story trainers, gym leaders, Joey, wild Pokémon. Every choice uses the real numbers from the game: types, stats, stat changes, moves and damage rolls.

- **Best move:** the one that knocks the opponent out fastest, counting accuracy. Stat moves (Leer, Growl, ...) are used when they save a turn and it's safe.
- **Switching:** to a teammate that clearly does better, after a faint to the best matchup, and when the trainer's next Pokémon is a bad match.
- **Running:** from wild Pokémon that are a bad idea. A super-effective move, one that can poison, paralyse or put to sleep, or nothing of ours that hurts it.
- **New moves** are learned only when they're stronger; HMs and the catcher's sleep move are never forgotten.
- **Potions in battle** when the active Pokémon is low and no Pokémon Center is near.

## Evolutions

The bot works out which forms the living dex still needs, picks which copy evolves and which stays as it is, and trains it.

- **Level evolutions** (Pidgeot at 36, Jumpluff at 27, ...) are trained up before the section's gym.
- **Rare evolved forms are evolved, not hunted.** The Burned Tower has a 1% Weezing, but Koffing is 59% there, so the bot catches a second shiny Koffing and trains it to Lv 35. This applies whenever the pre-evolution is met at least twice as often in the section. A shiny Weezing that turns up anyway still counts.
- **Friendship evolutions** (Crobat) are walked and fought until happy.
- **Stone evolutions** happen when the stone is available. They never hold up a section.
- The Pokémon that has to **stay unevolved** for the living dex is kept from evolving: the bot presses B during the evolution, like a player would.

## Money and Shopping

The bot farms its own money. It comes from **Youngster Joey**: the bot takes his phone number, and every time he calls for a rematch it goes to fight his Rattata, **$64** a win. Cave maps have no phone signal, so the bot weighs that in when it's waiting for his call.

The only other numbers it takes are the **swarm callers'**: Hiker Anthony (Dunsparce), Bug Catcher Arnie (Yanma) and Fisher Ralph (Qwilfish). Their swarms turn a 1% Pokémon into a 30-40% one until midnight; the [FAQ](FAQ.md#what-are-swarms-and-why-does-the-bot-answer-the-phone) has the maths. (Planned: the bot doesn't take these numbers yet.)

- **Poké Balls first.** Once there are fewer than 90 balls and enough money, the bot buys a stack at the nearest Poké Mart, up to 99.
- **Then savings.** With a full bag, Joey's rematches carry on until there's a $100,000 cushion.
- **Supplies.** Five potions and three Antidotes are kept, never Energy Powder or Energy Root (they cost friendship).
- **A floor.** $500 always stays for emergencies.

## Healing

The bot decides when a Pokémon needs healing and where.

- **Pokémon Center first.** When the lead is low on HP, has a status, or runs out of PP for its attacks or sleep move, the bot walks to a Center.
- **Before the first badge**, it's always the Center: Cherrygrove and Violet are never far.
- **In caves** a strong team fights on: one Pokémon may faint while the others are healthy.
- **Potions and Antidotes** only when no Center is in reach.

## Getting Around

The bot has a map of the whole game, made from the game's own data: every map, every wall, ledge, door, cave and route connection.

- **Routes** are planned like a player would walk them: around trainers it hasn't fought, around tall grass when it's not hunting, and over ledges only in the right direction.
- **Hunting** means walking loops through the grass or cave, not standing still.
- **The story** is played the same way: the bot finds the next event by its flag in the game's memory (the same way the game knows what has happened), walks there and does it.

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

Not built yet for the stream bot: fishing, surfing, Headbutt and Rock Smash hunts (the user bot has its own versions), the swarm callers, the Bug-Catching Contest and soft resets for one-time Pokémon.
