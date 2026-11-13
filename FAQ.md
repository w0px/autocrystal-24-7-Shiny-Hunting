<p align="center">
  <img src="images/faq.png" alt="Questions? Here are the answers!" width="384">
</p>

# FAQ

Every number here comes from the game's own code (the [pokecrystal disassembly](https://github.com/pret/pokecrystal)) or from the bot's logs at normal speed.

**The basics**
- [Is the stream really live?](#is-the-stream-really-live)
- [Is anyone controlling the bot?](#is-anyone-controlling-the-bot)
- [Is the game modified?](#is-the-game-modified)
- [Is the bot cheating?](#is-the-bot-cheating)
- [What happens if a shiny runs away or faints?](#what-happens-if-a-shiny-runs-away-or-faints)

**The odds**
- [What are DVs?](#what-are-dvs)
- [Why exactly 1 in 8,192?](#why-exactly-1-in-8192)
- [How many encounters does a shiny take?](#how-many-encounters-does-a-shiny-take)
- [What do the percentages mean?](#what-do-the-percentages-mean)
- [How fast is normal speed?](#how-fast-is-normal-speed)
- [What does a shiny's Hidden Power look like?](#what-does-a-shinys-hidden-power-look-like)
- [Why are there no shiny female starters?](#why-are-there-no-shiny-female-starters)
- [How likely is the catch?](#how-likely-is-the-catch)
- [How rare are perfect DVs, almost shinies and four of a kind?](#how-rare-are-perfect-dvs-almost-shinies-and-four-of-a-kind)

**Time**
- [Why is it so slow?](#why-is-it-so-slow)
- [How long will it take?](#how-long-will-it-take)
- [Why does the Bug-Catching Contest take decades?](#why-does-the-bug-catching-contest-take-decades)
- [What are swarms, and why does the bot answer the phone?](#what-are-swarms-and-why-does-the-bot-answer-the-phone)

**The rules**
- [Why no breeding?](#why-no-breeding)
- [What about Pokémon you only meet once?](#what-about-pokémon-you-only-meet-once)
- [Why no Gengar, Machamp or Alakazam?](#why-no-gengar-machamp-or-alakazam)

**The bot**
- [Why does it go back to the same route so often?](#why-does-it-go-back-to-the-same-route-so-often)
- [Why does it run from some wild Pokémon?](#why-does-it-run-from-some-wild-pokémon)
- [Why does it keep fighting Youngster Joey?](#why-does-it-keep-fighting-youngster-joey)
- [Why does a regular Caterpie or Zubat have a job?](#why-does-a-regular-caterpie-or-zubat-have-a-job)
- [Can I run the bot myself?](#can-i-run-the-bot-myself)
- [Where do I get notified about shinies?](#where-do-i-get-notified-about-shinies)

## The basics

### Is the stream really live?

Yes. What you see is the game running right now, at normal speed. Nothing is recorded, sped up or cut. The in-game clock follows the real one, so it's night in the game when it's night where the bot runs.

### Is anyone controlling the bot?

No. Once it's started, the bot makes every decision on its own:
- it plays the story;
- it picks where and when to hunt;
- it builds its team, and replaces members when a better shiny comes along;
- it trains, evolves, farms its own money, shops, heals and runs the PC.

Nobody picks a route, a team member or a move during the run. What people decide are the rules it follows, written into its code beforehand, like "no breeding" or "the catcher is always the Butterfree line". The [README](README.md#nobodys-playing-the-bot-decides) lists every decision, and [How it works](HOW-IT-WORKS.md) explains how each one is made.

### Is the game modified?

No. It's an unmodified English Pokémon Crystal. The bot presses buttons and reads the game's memory, the same numbers the game itself uses, and never writes to it.

### Is the bot cheating?

No. Every wild shiny is a real 1 in 8,192 encounter, met by walking, fishing or headbutting like you would. There are no resets for wild Pokémon, no savestates to retry an encounter and no fast-forward. The one exception is the handful of Pokémon the game gives you only once; see [Pokémon you only meet once](#what-about-pokémon-you-only-meet-once). A savestate is used only to recover from a crash of the PC or emulator.

### What happens if a shiny runs away or faints?

It's gone, like it would be for you. The hunt for that Pokémon starts again. The bot does a lot to stop that happening: it puts the shiny to sleep first, never risks a critical hit that could knock it out, and keeps throwing balls; see [How likely is the catch?](#how-likely-is-the-catch)

## The odds

### What are DVs?

Every Pokémon in Gen 2 has four hidden values from 0 to 15, for Attack, Defense, Speed and Special. They make each Pokémon a little stronger or weaker (twice the DV in stat points at Lv 100, so up to 30), and the HP value is built from them too. In Gen 2 they also decide whether a Pokémon is shiny, its gender, its Hidden Power and, for Unown, its letter.

### Why exactly 1 in 8,192?

A Pokémon is shiny when its **Defense, Speed and Special DVs are all 10**, and its **Attack DV is 2, 3, 6, 7, 10, 11, 14 or 15**:

> 1/16 (Defense) × 1/16 (Speed) × 1/16 (Special) × 8/16 (Attack) = **1/8,192**

Each DV is rolled at random when the encounter starts, so every wild Pokémon has the same chance, whatever its species or level.

### How many encounters does a shiny take?

On average **8,192**, but luck swings it a lot. Every encounter is a fresh 1 in 8,192, so the chance to have found one after *n* encounters is 1 − (8,191/8,192)<sup>n</sup>:

| Chance of at least one shiny | after |
|---|---|
| 50% | 5,678 encounters |
| 63% | 8,192 encounters |
| 90% | 18,863 encounters |
| 99% | 37,726 encounters |

So a hunt three times longer than average isn't bad luck in a meaningful sense: it happens about once in 20 hunts. The overlay calls out droughts once they get rarer than 1 in 10.

That's for *any* shiny. For one particular Pokémon, divide by how often it shows up: a Pokémon in 5% of encounters needs 8,192 ÷ 0.05 = **163,840 encounters** on average.

### What do the percentages mean?

Each patch of grass or cave floor has **seven slots** for each time of day, picked with fixed chances:

> 30% · 30% · 20% · 10% · 5% · 4% · 1%

A Pokémon's percentage is the sum of the slots it fills. Dunsparce in Dark Cave sits only in the last slot: 1% of all encounters there, at any time of day. Teddiursa is in the 5% slot, and only in the morning (4-10 AM). Water has three slots (60/30/10), fishing rods have their own tables, and headbutt trees have a common and a rare table.

| Rarity | Encounters for one shiny, on average | Time at normal speed, non-stop on one route |
|---|---|---|
| 30% | 27,307 | 7.6 days |
| 20% | 40,960 | 11.4 days |
| 10% | 81,920 | 23 days |
| 5% | 163,840 | 46 days |
| 4% | 204,800 | 57 days |
| 1% | 819,200 | 228 days |

A Pokémon that only appears at one time of day takes longer by that much: morning is 6 of the day's 24 hours, so a morning-only 5% Teddiursa needs about **213 mornings** in Dark Cave.

### How fast is normal speed?

Measured on the bot's own logs, counted in game hours (the game clock runs at real speed on the stream):

- **Grass:** 145-160 encounters an hour, about 23 seconds each: ~3 seconds of walking (10% of steps meet something) and ~20 for the battle and running away.
- **Dark Cave:** 128 an hour. Caves meet something on 4% of steps, so there's more walking.
- **Sprout Tower:** 85 an hour. Towers meet something on only 2% of steps.
- **Whole days, everything included** (Joey, Pokémon Centers, catches): 120-147 an hour.

Fishing takes about two casts per bite (50% bite chance), so about 31 seconds an encounter; headbutting a tree about 28-33 seconds.

### What does a shiny's Hidden Power look like?

Always the same two options. Hidden Power's type comes from the last two bits of the Attack and Defense DVs, and a shiny's Defense is always 10:

- Attack 2, 6, 10, 14: **Grass**
- Attack 3, 7, 11, 15: **Dragon**

Its power comes from the top bit of each DV, so it's **49** with an Attack DV under 8 and **69** with 8 or more. A shiny's Hidden Power is always Grass or Dragon, 49 or 69. The Discord post shows it with every shiny.

### Why are there no shiny female starters?

Gen 2 decides gender from the Attack DV too (Speed only breaks ties). For a Pokémon that's female 1 time in 8 (the starters, Eevee, ...), only an Attack of 0 or 1 makes it female, and a shiny never has those. So:

| Female share of the species | Shiny females |
|---|---|
| 12.5% (starters, Eevee) | none |
| 25% | 1 in 4 shinies (Attack 2, 3) |
| 50% | 1 in 2 shinies |
| 75% | 3 in 4 shinies |

And **Unown**: its letter comes from the DVs, and a shiny Unown can only be an **I** or a **V**. Before Falkner only the letters A-K exist, so the stream's shiny Unown will be an I.

### How likely is the catch?

The game's own formula, from `engine/items/item_effects.asm`:

> catch value = catch rate × ball bonus × (3 × max HP − 2 × HP) ÷ (3 × max HP), **+10 if asleep or frozen**
>
> chance per ball = (catch value + 1) ÷ 256

Two quirks matter:
- Only **sleep and freeze** help. Paralysis, poison and burn were meant to add 5 but add nothing: a bug in Gen 2. That's why the bot always uses Sleep Powder.
- Lowering HP helps a lot: at 40% HP the formula keeps 73% of the catch rate, at full HP a third.

Example: a sleeping shiny Teddiursa (catch rate 120) at 40% HP takes an Ultra Ball **73%** of the time, a Poké Ball **39%**. A Scyther (catch rate 45) under the same conditions: Ultra Ball 30%.

### How rare are perfect DVs, almost shinies and four of a kind?

Out of the 65,536 possible DV combinations:

- **Perfect (15/15/15/15)** and **0/0/0/0**: 1 each, so **1 in 65,536**.
- **Four of a kind** (7/7/7/7 and the like, not counting those two): 14, so **1 in 4,681**.
- **Almost shiny** (Defense, Speed and Special 10, the Attack wrong): 8, so **1 in 8,192**, as rare as a shiny itself.

## Time

### Why is it so slow?

Because it's normal speed and every shiny is earned: about 150 encounters an hour, 1 in 8,192 each. A 30% Pokémon takes about a week of non-stop hunting, a 1% one over seven months. That's the point of the challenge.

### How long will it take?

About **6 years** for the wild Pokémon of all eight Johto gyms (8 in 10 simulated runs land between 4.6 and 7.6 years), from simulating the bot's own planner with the game's real encounter tables. The Bug-Catching Contest comes on top of that, see below. Each section's numbers are in [the README](README.md#the-sections-and-how-long-they-take).

### Why does the Bug-Catching Contest take decades?

Scyther and Pinsir exist **only** in the Bug-Catching Contest in National Park, at 5% each. The contest:

- runs only on **Tuesday, Thursday and Saturday**,
- lasts **20 minutes**, once a day,
- gives about **50 encounters** at normal speed.

That's about 7,800 contest encounters a year. A shiny Scyther needs 163,840 on average: **21 years**. Both Scyther *and* Pinsir: **31 years** on average (half of all runs within 26 years). Without breeding there's no faster way, so the contest is the one place where the challenge's maths really bites.

### What are swarms, and why does the bot answer the phone?

Some trainers call to say a Pokémon is swarming. While the swarm lasts (until midnight), that Pokémon is suddenly common:

| Caller | Where | Swarm | Normally | During the swarm |
|---|---|---|---|---|
| Hiker Anthony | Route 33 | Dunsparce in Dark Cave | 1% | 40% |
| Bug Catcher Arnie | Route 35 | Yanma on Route 35 | 1% | 30% |
| Fisher Ralph | Route 32 | Qwilfish on Route 32 | Super Rod only | 15% (Old Rod), 65% (Good Rod) |

How a call works, from the game's code: every 20, then 10, 5 and 3 minutes, there's a 50% chance of a call, from a random one of the numbers you have. It only rings where there's phone signal (not in caves). A swarm caller's call is either a rematch request or a **1 in 5** chance to start his swarm. Once he has asked for a rematch and is waiting for it, every call he makes is the 1 in 5 roll, so the bot lets him wait.

For Yanma that's the difference between 819,200 encounters (1%) and 27,307 (30%). So the bot takes the swarm callers' numbers along with Joey's.

## The rules

### Why no breeding?

Because every shiny should be a wild one. In Gen 2 breeding is a shortcut: a shiny parent passes its Defense DV on and the Special DV half the time, so its eggs are shiny **1 in 64** instead of 1 in 8,192.

Without breeding some forms can't be finished: there's only one Eevee (from Bill), one Tyrogue (from Kiyo) and one Togepi egg, the baby Pokémon (Pichu, Cleffa, Igglybuff, Smoochum, Elekid, Magby) only come from eggs, Chikorita and Cyndaquil can't be had at all without trading, and Totodile is a single starter, so two of its three forms are missing. Bulbasaur, Charmander and Squirtle aren't in Crystal at all. Those count as out of reach, like trade evolutions.

### What about Pokémon you only meet once?

Some Pokémon appear once per game: Sudowoodo, the red Gyarados, the three Rocket HQ Electrodes, Raikou, Entei, Suicune, Lugia, Ho-Oh, and gifts like Eevee or Shuckle. Lapras comes back only on Fridays. With no resets they'd be shiny 1 time in 8,192, so for these the bot does what players do with their starter: it **soft-resets** until the shiny shows up.

At normal speed that's about 8,192 resets of ~50 seconds each, around **5 days per Pokémon** on average. The red Gyarados is always shiny, so it's free.

**Frame search** is the clever version from the [autocrystal user bot](https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit). The game's random numbers change every frame, so pressing A on frame 1,000 or frame 1,001 rolls different DVs. Resetting with random delays keeps landing on the same few hundred results. Frame search instead tries every frame once, in order: save, press A, read the DVs as soon as they're rolled, load, next frame. It skips frames it can tell will roll the same DVs as the frame before. Nothing in the game is changed: every result is one the game would really give on that frame, the same idea speedrunners use for RNG manipulation. While it searches, the emulator runs as fast as it can, muted, and it finds about 4.4 new DV combinations a second, so a shiny takes about **30 minutes** instead of days.

### Why no Gengar, Machamp or Alakazam?

They evolve by trading. The bot plays alone, so trade evolutions are left out of the living dex: Gengar, Golem, Machamp, Alakazam, Politoed, Slowking, Steelix, Scizor, Kingdra and Porygon2.

## The bot

### Why does it go back to the same route so often?

Because the maths says so. The planner works out, for the whole section, how many of each day's morning, day and night hours to spend where, so that **the slowest Pokémon still needed** gets done as soon as possible, then the next slowest, and so on. A spot gets hours only for what it's best at: Sprout Tower at night is 85% Gastly against 5% on the routes, so the night's Gastly hours go there. Where to go next is then a dice roll weighted by those hours, so it isn't always the same.

### Why does it run from some wild Pokémon?

When it isn't catching, it runs from anything that's a bad fight: a super-effective move, a move that can poison, paralyse or put to sleep, or nothing it can hurt. A fainted or poisoned teammate costs a walk to the Pokémon Center, and that's time not spent hunting.

### Why does it keep fighting Youngster Joey?

He's its job. Joey's rematch is the only money that keeps coming before the first badge ($64 a win), and Poké Balls cost money. He calls when he wants a rematch, and the bot goes and beats his Rattata again.

### Why does a regular Caterpie or Zubat have a job?

They're the catching crew. Butterfree's Sleep Powder puts a shiny to sleep (the only status that helps the catch, see above), and Zubat weakens it without risking a knockout: the bot checks every move against the highest damage roll *and* a critical hit before using it. They're the only Pokémon allowed to be regular, and a shiny one replaces them as soon as the bot catches it.

### Can I run the bot myself?

Yes, both are open source. The [autocrystal user bot](https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit) hunts wild, fishing, headbutt, egg and static shinies for you in BizHawk, on Gold, Silver and Crystal; that's the one to start with. The stream bot that plays the whole game is in [this repository](README.md#the-code), but it's still in testing and changes a lot.

### Where do I get notified about shinies?

On the [Discord server](https://discord.gg/3PMwdtcM87): pick **Shinies** in Channels & Roles and you're pinged for every shiny the stream finds, in #shinies.
