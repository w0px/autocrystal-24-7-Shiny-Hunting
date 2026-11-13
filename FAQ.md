<p align="center">
  <img src="images/faq.png" alt="Questions? Here are the answers!" width="384">
</p>

# FAQ

- [Is the stream really live?](#is-the-stream-really-live)
- [Is the game modified?](#is-the-game-modified)
- [Is the bot cheating?](#is-the-bot-cheating)
- [What happens if a shiny runs away or faints?](#what-happens-if-a-shiny-runs-away-or-faints)
- [Why is it so slow?](#why-is-it-so-slow)
- [How long will it take?](#how-long-will-it-take)
- [Why does it go back to the same route so often?](#why-does-it-go-back-to-the-same-route-so-often)
- [Why does it run from some wild Pokémon?](#why-does-it-run-from-some-wild-pokémon)
- [Why does it keep fighting Youngster Joey?](#why-does-it-keep-fighting-youngster-joey)
- [Why does a regular Caterpie or Zubat have a job?](#why-does-a-regular-caterpie-or-zubat-have-a-job)
- [Why no Gengar, Machamp or Alakazam?](#why-no-gengar-machamp-or-alakazam)
- [What are DVs?](#what-are-dvs)
- [Can I run the bot myself?](#can-i-run-the-bot-myself)
- [Where do I get notified about shinies?](#where-do-i-get-notified-about-shinies)

### Is the stream really live?

Yes. What you see is the game running right now, at normal speed. Nothing is recorded, sped up or cut. The in-game clock follows the real one, so it's night in the game when it's night where the bot runs.

### Is the game modified?

No. It's an unmodified English Pokémon Crystal. The bot plays it like a player: it presses buttons and reads what's on screen and in the game's memory. It never changes anything in the game.

### Is the bot cheating?

No. Every shiny is a real 1 in 8,192 encounter, met by walking around like you would. There are no resets, no savestates to retry an encounter, no RNG tricks, no fast-forward. A savestate is only used to recover from a crash of the PC or emulator, never to undo something that happened in the game.

### What happens if a shiny runs away or faints?

It's gone, like it would be for you. The bot doesn't reset, and the hunt for that Pokémon goes on.

### Why is it so slow?

Shinies are 1 in 8,192, and the game runs at normal speed: about 2 to 3 encounters a minute. A common Pokémon's shiny takes days, a rare one weeks to months. That's the point of the challenge.

### How long will it take?

A long time, and that's the challenge. The first section alone has a 1% Dunsparce and a 5% Teddiursa that only comes out in the morning, and every section after it has its own rare ones. Expect years for the whole game.

### Why does it go back to the same route so often?

The bot plans where to hunt for the whole section and spends the most time where the Pokémon it still needs are most likely. Some Pokémon only appear on one route, or only at one time of day, so that's where it has to be. Where it goes next is a weighted dice roll, so it isn't always the same.

### Why does it run from some wild Pokémon?

When it isn't catching, it runs from anything that's a bad fight: a super-effective move, a move that can poison, paralyse or put to sleep, or nothing it can hurt. A fainted or poisoned teammate costs a walk to the Pokémon Center.

### Why does it keep fighting Youngster Joey?

He's its job. Joey's rematch is the only money that keeps coming before the first badge ($64 a win), and Poké Balls cost money. The bot takes his phone number, and fights him every time he calls.

### Why does a regular Caterpie or Zubat have a job?

They're the catching crew: Butterfree's Sleep Powder puts a shiny to sleep, Zubat weakens it without risking a knockout. They're the only Pokémon allowed to be regular, and a shiny one replaces them as soon as the bot catches it. Every other team member is a shiny the bot caught itself.

### Why no Gengar, Machamp or Alakazam?

They evolve by trading. The bot plays alone, so trade evolutions are left out of the living dex.

### What are DVs?

Hidden values from 0 to 15 for Attack, Defense, Speed and Special that make each Pokémon a bit different. In Gen 2 they also decide whether a Pokémon is shiny: Defense, Speed and Special must be 10, and Attack one of 2, 3, 6, 7, 10, 11, 14 or 15. That's why the stream calls out "almost shiny" ones, where only the Attack was off.

### Can I run the bot myself?

The shiny hunting toolkit, yes: [autocrystal](https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit) hunts wild, fishing, headbutt, egg and static shinies for you in BizHawk, on Gold, Silver and Crystal. The stream bot that plays the whole game isn't public yet.

### Where do I get notified about shinies?

On the Discord server: pick **Shinies** in Channels & Roles and you're pinged for every shiny the stream finds, in #shinies.
