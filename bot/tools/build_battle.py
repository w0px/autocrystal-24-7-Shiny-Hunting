"""build_battle.py - writes modules/data/battle_data.lua from the pokecrystal
disassembly: every move (name, effect, power, type, accuracy, PP), the type
chart, each species' types and base stats, the text charmap (for reading
the screen) and the HM moves, item names, the status each healing item cures, the HP each gives back and item prices. The fighter (modules/data/fighter.lua) picks
moves and matchups from it.

    python -I tools/build_battle.py <pokecrystal dir> modules/data/battle_data.lua

Regenerate, don't hand-edit.
"""
import os
import re
import sys


def num(v):
    return int(v[1:], 16) if v.startswith("$") else int(v, 0)


def consts(path, first=0):
    """name -> value for a const_def / const / const_skip / const_next file."""
    out, n = {}, first
    for line in open(path, encoding="utf-8"):
        t = line.split(";")[0].strip()
        if not t:
            continue
        parts = t.replace(",", " ").split()
        op = parts[0]
        if op == "const_def":
            n = num(parts[1]) if len(parts) > 1 else 0
        elif op == "const":
            out[parts[1]] = n
            n += 1
        elif op == "const_skip":
            n += num(parts[1]) if len(parts) > 1 else 1
        elif op == "const_next":
            n = num(parts[1])
    return out


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(root, out_path):
    types = consts(os.path.join(root, "constants/type_constants.asm"))
    move_ids = consts(os.path.join(root, "constants/move_constants.asm"))
    species_ids = consts(os.path.join(root, "constants/pokemon_constants.asm"))

    # Moves, in move id order (moves.asm starts at id 1).
    moves = {}
    rx = re.compile(r"^\s*move\s+(\w+),\s*(\w+),\s*(\d+),\s*(\w+),\s*(\d+),\s*(\d+),\s*(\d+)")
    for line in open(os.path.join(root, "data/moves/moves.asm"), encoding="utf-8"):
        m = rx.match(line)
        if m:
            name, eff, power, typ, acc, pp, chance = m.groups()
            moves[move_ids[name]] = (name, eff, int(power), types[typ], int(acc), int(pp))
    assert len(moves) == 251, len(moves)

    # Type chart: attacker -> defender -> x10 (20 super, 5 not very, 0 none).
    chart, foresight = [], False
    mult = {"SUPER_EFFECTIVE": 20, "NOT_VERY_EFFECTIVE": 5, "NO_EFFECT": 0, "EFFECTIVE": 10}
    for line in open(os.path.join(root, "data/types/type_matchups.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        if t.startswith("db -2"):
            foresight = True
            continue
        if t.startswith("db -1"):
            break
        m = re.match(r"db\s+(\w+),\s*(\w+),\s*(\w+)", t)
        if m:
            a, d, e = m.groups()
            chart.append((types[a], types[d], mult[e], foresight))

    # Species: types and base stats, by species id (from each base_stats file).
    species = {}
    bs_dir = os.path.join(root, "data/pokemon/base_stats")
    for fn in sorted(os.listdir(bs_dir)):
        text = open(os.path.join(bs_dir, fn), encoding="utf-8").read()
        sp = re.search(r"db\s+(\w+)\s*;\s*\d+", text)
        st = re.search(r"db\s+(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\s*\n\s*;\s*hp", text)
        ty = re.search(r"db\s+(\w+),\s*(\w+)\s*;\s*type", text)
        if sp and st and ty and sp.group(1) in species_ids:
            species[species_ids[sp.group(1)]] = ([int(v) for v in st.groups()], types[ty.group(1)], types[ty.group(2)])
    assert len(species) == 251, len(species)

    # Text: byte -> character (only the single printable ones).
    charmap = {}
    for line in open(os.path.join(root, "constants/charmap.asm"), encoding="utf-8"):
        m = re.match(r'\s*charmap\s+"(.*?)",\s*\$([0-9a-fA-F]+)', line)
        if m:
            ch, val = m.group(1), int(m.group(2), 16)
            ascii_ok = len(ch) == 1 and (32 <= ord(ch) < 127 or ch == "é")
            if val >= 0x7F and val not in charmap and (ascii_ok or ch in ("'s", "'t", "'v", "'r", "'m", "'l", "'d", "<PK>", "<MN>", "<PO>", "<KE>", "é")):
                charmap[val] = {"<PK>": "PK", "<MN>": "MN", "<PO>": "PO", "<KE>": "KE"}.get(ch, ch)
    charmap[0x7F] = " "

    hms = ["CUT", "FLY", "SURF", "STRENGTH", "FLASH", "WATERFALL", "WHIRLPOOL"]

    # Level-up moves and evolutions, by species (evos_attacks.asm, in the
    # order of evos_attacks_pointers.asm = species order).
    order = []
    for line in open(os.path.join(root, "data/pokemon/evos_attacks_pointers.asm"), encoding="utf-8"):
        m = re.match(r"\s*dw\s+(\w+)EvosAttacks", line)
        if m:
            order.append(m.group(1))
    assert len(order) == 251, len(order)
    label_species = {lab: i + 1 for i, lab in enumerate(order)}
    learn, evos = {}, {}
    cur, part = None, None
    for line in open(os.path.join(root, "data/pokemon/evos_attacks.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        m = re.match(r"^(\w+)EvosAttacks:", t)
        if m and m.group(1) in label_species:
            cur, part = label_species[m.group(1)], "evo"
            learn[cur], evos[cur] = [], []
            continue
        if cur is None or not t.startswith("db"):
            continue
        args = [a.strip() for a in t[2:].split(",")]
        if args == ["0"]:
            part = "learn" if part == "evo" else None
            continue
        if part == "evo":
            kind = args[0].replace("EVOLVE_", "").lower()
            into = species_ids[args[-1]]
            param = args[1] if len(args) > 2 else ""
            evos[cur].append((kind, param, into))
        elif part == "learn":
            learn[cur].append((int(args[0]), move_ids[args[1]]))
    assert len(learn) == 251

    # HM compatibility: each base_stats file's tmhm list.
    hm_ids = {move_ids[h] for h in hms}
    hmcompat = {}
    for fn in sorted(os.listdir(bs_dir)):
        text = open(os.path.join(bs_dir, fn), encoding="utf-8").read()
        sp = re.search(r"db\s+(\w+)\s*;\s*\d+", text)
        tm = re.search(r"tmhm\s+(.*)", text)
        if sp and sp.group(1) in species_ids:
            got = [move_ids[n.strip()] for n in (tm.group(1).split(",") if tm else []) if n.strip() in move_ids]
            hmcompat[species_ids[sp.group(1)]] = sorted(i for i in got if i in hm_ids)

    # Trainers' top level: "CLASS:NAME" (trainer_constants.asm) -> the
    # highest level in its party (parties.asm, via party_pointers.asm).
    classes = []          # [(class, [consts...])] in class order, TRAINER_NONE first
    for line in open(os.path.join(root, "constants/trainer_constants.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        m = re.match(r"trainerclass\s+(\w+)", t)
        if m:
            classes.append((m.group(1), []))
            continue
        m = re.match(r"const\s+(\w+)$", t)
        if m and classes:
            classes[-1][1].append(m.group(1))
    groups = []
    for line in open(os.path.join(root, "data/trainers/party_pointers.asm"), encoding="utf-8"):
        m = re.match(r"\s*dw\s+(\w+Group)", line)
        if m:
            groups.append(m.group(1))
    parties, cur = {}, None
    for line in open(os.path.join(root, "data/trainers/parties.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        m = re.match(r"^(\w+Group):", t)
        if m:
            cur = m.group(1)
            parties[cur] = []
            continue
        if cur is None:
            continue
        if re.match(r'db\s+".*@"', t):
            parties[cur].append(0)
            continue
        m = re.match(r"db\s+(\d+),\s*[A-Z]", t)
        if m and parties[cur]:
            parties[cur][-1] = max(parties[cur][-1], int(m.group(1)))
    trainers = {}
    for i, (cls, consts_) in enumerate(classes[1:], start=0):
        if i >= len(groups):
            break
        levels = parties.get(groups[i], [])
        for j, c in enumerate(consts_):
            if j < len(levels):
                trainers[cls + ":" + c] = levels[j]
    assert trainers.get("FALKNER:FALKNER1") == 9 and trainers.get("SAGE:LI") == 10, (trainers.get("FALKNER:FALKNER1"), trainers.get("SAGE:LI"))

    # The wild tables as they are, per map: grass {rates {morn, day, nite},
    # morn/day/nite = 7 x {level, species}} (slots 30/30/20/10/5/4/1%) and
    # water {rate, 3 x {level, species}} (60/30/10%). Johto and Kanto; not
    # swarms (they come and go).
    wild_grass, wild_water = {}, {}
    for fname, kind in (("johto_grass.asm", "grass"), ("kanto_grass.asm", "grass"),
                        ("johto_water.asm", "water"), ("kanto_water.asm", "water")):
        mapname, mons, rates = None, [], []
        for line in open(os.path.join(root, "data/wild", fname), encoding="utf-8"):
            t = line.split(";")[0].strip()
            m = re.match(r"def_(grass|water)_wildmons\s+(\w+)", t)
            if m:
                mapname, mons, rates = m.group(2), [], []
                continue
            m = re.match(r"db\s+(\d+)\s*percent(?:,\s*(\d+)\s*percent,\s*(\d+)\s*percent)?", t)
            if m and mapname and not rates:
                rates = [int(x) for x in m.groups() if x is not None]
                continue
            m = re.match(r"db\s+(\d+),\s*(\w+)$", t)
            if m and mapname and m.group(2) in species_ids:
                mons.append((int(m.group(1)), species_ids[m.group(2)]))
            if t.startswith("end_") and mapname:
                if kind == "grass" and len(mons) == 21:
                    wild_grass[mapname] = (rates, mons[0:7], mons[7:14], mons[14:21])
                elif kind == "water" and len(mons) == 3:
                    wild_water[mapname] = (rates[0] if rates else 0, mons)
                mapname = None
    assert "ROUTE_29" in wild_grass and "DARK_CAVE_VIOLET_ENTRANCE" in wild_grass, sorted(wild_grass)[:5]

    # Rarity: each species' best chance per encounter at any one spot -
    # grass (per map and time of day), water, fishing (per group and rod),
    # headbutt trees (per set, common/rare). Percent; where, for the log.
    best = {}

    def seen(spname, pct, where):
        if spname not in species_ids:
            return
        sid = species_ids[spname]
        if sid not in best or pct > best[sid][0]:
            best[sid] = (pct, where)

    grass_slots = [30, 30, 20, 10, 5, 4, 1]
    water_slots = [60, 30, 10]
    for fname, slots, timed in (("johto_grass.asm", grass_slots, True), ("kanto_grass.asm", grass_slots, True),
                                ("johto_water.asm", water_slots, False), ("kanto_water.asm", water_slots, False),
                                ("swarm_grass.asm", grass_slots, True), ("swarm_water.asm", water_slots, False)):
        mapname, mons = None, []
        for line in open(os.path.join(root, "data/wild", fname), encoding="utf-8"):
            t = line.split(";")[0].strip()
            m = re.match(r"def_(grass|water)_wildmons\s+(\w+)", t)
            if m:
                mapname, mons = m.group(2), []
                continue
            m = re.match(r"db\s+(\d+),\s*(\w+)$", t)
            if m and mapname:
                mons.append(m.group(2))
            if t.startswith("end_") and mapname:
                n = len(slots)
                groups = [mons[i:i + n] for i in range(0, len(mons), n)]
                times = ["morn", "day", "nite"] if timed else [""]
                for g, tname in zip(groups, times):
                    tally = {}
                    for spname, pct in zip(g, slots):
                        tally[spname] = tally.get(spname, 0) + pct
                    for spname, pct in tally.items():
                        seen(spname, pct, (mapname + " " + tname).strip() + (" (swarm)" if "swarm" in fname else ""))
                mapname = None

    # Fishing: cumulative percents per group/rod.
    group, prev, tally = None, 0, {}
    def flush_fish():
        for spname, pct in tally.items():
            seen(spname, pct, "fishing " + group)
    for line in open(os.path.join(root, "data/wild/fish.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        m = re.match(r"^\.(\w+):", t)
        if m:
            if group:
                flush_fish()
            group, prev, tally = m.group(1), 0, {}
            continue
        m = re.match(r"db\s+(\d+)\s*percent(?:\s*\+\s*1)?,\s*(\w+)", t)
        if m and group:
            cum = int(m.group(1))
            if m.group(2) != "time_group":
                tally[m.group(2)] = tally.get(m.group(2), 0) + (cum - prev)
            prev = cum
    if group:
        flush_fish()

    # Headbutt trees: plain percents, common and rare tables.
    tset, part, tally = None, 0, {}
    def flush_tree():
        for spname, pct in tally.items():
            seen(spname, pct, "headbutt " + tset + (" rare" if part else ""))
    for line in open(os.path.join(root, "data/wild/treemons.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        m = re.match(r"^TreeMonSet_(\w+):", t)
        if m:
            if tally and tset:
                flush_tree()
            tset, part, tally = m.group(1), 0, {}
            continue
        if t == "db -1":
            if tset:
                flush_tree()
            part, tally = part + 1, {}
            continue
        m = re.match(r"db\s+(\d+),\s*(\w+),", t)
        if m and tset:
            tally[m.group(2)] = tally.get(m.group(2), 0) + int(m.group(1))

    # Items: id -> constant name (the ones before the TMs), and which status
    # each healing item cures (the game's own StatusHealingActions table).
    items, n = {}, 0
    for line in open(os.path.join(root, "constants/item_constants.asm"), encoding="utf-8"):
        t = line.split(";")[0].strip()
        if t.startswith("DEF NUM_ITEMS"):
            break
        if t == "const_def":
            n = 0
        elif t.startswith("const "):
            items[n] = t.split()[1]
            n += 1
    item_ids = {v: k for k, v in items.items()}
    status_bits = {"PSN": 3, "BRN": 4, "FRZ": 5, "PAR": 6}
    cures = []
    for line in open(os.path.join(root, "data/items/heal_status.asm"), encoding="utf-8"):
        m = re.match(r"\s*db\s+(\w+),\s*\w+,\s*(.+?)\s*(;.*)?$", line)
        if not m or m.group(1) not in item_ids:
            continue
        v = m.group(2)
        mb = re.match(r"1 << (\w+)", v)
        mask = (1 << status_bits[mb.group(1)]) if mb else 0x07 if v == "SLP_MASK" else int(v[1:], 2) if v.startswith("%") else num(v)
        cures.append((item_ids[m.group(1)], mask))
    assert len(cures) >= 14, cures
    # ...and how much HP each healing item gives back (HealingHPAmounts; a
    # full heal is MAX_STAT_VALUE, 999).
    heals = []
    for line in open(os.path.join(root, "data/items/heal_hp.asm"), encoding="utf-8"):
        m = re.match(r"\s*dbw\s+(\w+),\s*(\w+)", line)
        if m and m.group(1) in item_ids:
            heals.append((item_ids[m.group(1)], 999 if m.group(2) == "MAX_STAT_VALUE" else num(m.group(2))))
    assert len(heals) >= 14, heals
    # ...and each item's price and pocket (ItemAttributes: "; NAME" then
    # "item_attribute price, held, param, property, pocket, ...").
    prices, cur = {}, None
    for line in open(os.path.join(root, "data/items/attributes.asm"), encoding="utf-8"):
        c = re.match(r"\s*;\s*([A-Z0-9_]+)\s*$", line)
        if c:
            cur = c.group(1)
            continue
        m = re.match(r"\s*item_attribute\s+([$\w]+),\s*\w+,\s*\w+,\s*\w+,\s*(\w+)", line)
        if m and cur in item_ids:
            prices[item_ids[cur]] = (num(m.group(1)), m.group(2))
            cur = None
    assert prices.get(item_ids["POTION"], (0,))[0] == 300 and prices[item_ids["POKE_BALL"]] == (200, "BALL"), prices.get(item_ids["POTION"])

    o = []
    o.append("-- battle_data.lua - generated by tools/build_battle.py from the pokecrystal")
    o.append("-- disassembly. Don't hand-edit: regenerate.")
    o.append("return {")
    o.append("  -- types[id] = name; physical below 20 (FIRE and up are special)")
    o.append("  types = {" + ", ".join("[%d] = %s" % (v, lua_str(k)) for k, v in sorted(types.items(), key=lambda kv: kv[1])
                                    if not k.startswith("DEF") and k not in ("PHYSICAL", "SPECIAL")) + "},")
    o.append("  -- moves[id] = {name, effect, power, type, accuracy %, pp}")
    o.append("  moves = {")
    for i in sorted(moves):
        n, e, p, t, a, pp = moves[i]
        o.append("    [%d] = {%s, %s, %d, %d, %d, %d}," % (i, lua_str(n), lua_str(e), p, t, a, pp))
    o.append("  },")
    o.append("  -- chart: {attacker, defender, x10, only without Foresight}")
    o.append("  chart = {" + ", ".join("{%d, %d, %d, %s}" % (a, d, e, "true" if f else "false") for a, d, e, f in chart) + "},")
    o.append("  -- species[id] = {{hp, atk, def, spd, sat, sdf}, type1, type2}")
    o.append("  species = {")
    for i in sorted(species):
        s, t1, t2 = species[i]
        o.append("    [%d] = {{%s}, %d, %d}," % (i, ", ".join(map(str, s)), t1, t2))
    o.append("  },")
    o.append("  charmap = {" + ", ".join("[%d] = %s" % (k, lua_str(v)) for k, v in sorted(charmap.items())) + "},")
    o.append("  hm = {" + ", ".join("[%d] = true" % move_ids[h] for h in hms) + "},")
    o.append("  -- items[id] = constant name")
    o.append("  items = {" + ", ".join("[%d] = %s" % (k, lua_str(v)) for k, v in sorted(items.items()) if k > 0) + "},")
    o.append("  -- cures: {item, status bits it clears} (StatusHealingActions, in the game's order)")
    o.append("  cures = {" + ", ".join("{%d, %d}" % c for c in cures) + "},")
    o.append("  -- heals: {item, HP it gives back} (HealingHPAmounts; 999 = all of it)")
    o.append("  heals = {" + ", ".join("{%d, %d}" % h for h in heals) + "},")
    o.append("  -- learn[species] = {{level, move}, ...} (level-up moves)")
    o.append("  learn = {")
    for i in sorted(learn):
        o.append("    [%d] = {%s}," % (i, ", ".join("{%d, %d}" % lm for lm in learn[i])))
    o.append("  },")
    o.append("  -- evos[species] = {{kind, param, into}, ...} (kind: level, item, trade, happiness, stat)")
    o.append("  evos = {" + ", ".join("[%d] = {%s}" % (i, ", ".join("{%s, %s, %d}" % (lua_str(k), lua_str(pp), into) for k, pp, into in evos[i]))
                                     for i in sorted(evos) if evos[i]) + "},")
    o.append("  -- hmcompat[species] = {hm move ids it can learn}")
    o.append("  hmcompat = {" + ", ".join("[%d] = {%s}" % (i, ", ".join(map(str, v))) for i, v in sorted(hmcompat.items()) if v) + "},")
    o.append("  -- rarity[species] = {best % per encounter at any one spot, where} (grass/water/fishing/headbutt; not gifts, eggs or statics)")
    o.append("  rarity = {" + ", ".join("[%d] = {%d, %s}" % (i, v[0], lua_str(v[1])) for i, v in sorted(best.items())) + "},")
    def slots(lst):
        return "{" + ", ".join("{%d, %d}" % lv for lv in lst) + "}"
    o.append("  -- wild_grass[MAP_CONST] = {rates = {morn, day, nite}, morn = 7 x {level, species}, day, nite} (slots 30/30/20/10/5/4/1%)")
    o.append("  wild_grass = {")
    for k in sorted(wild_grass):
        rates, mo, da, ni = wild_grass[k]
        o.append("    [%s] = {rates = {%s}, morn = %s, day = %s, nite = %s}," % (lua_str(k), ", ".join(map(str, rates)), slots(mo), slots(da), slots(ni)))
    o.append("  },")
    o.append("  -- wild_water[MAP_CONST] = {rate, 3 x {level, species}} (60/30/10%)")
    o.append("  wild_water = {" + ", ".join("[%s] = {rate = %d, mons = %s}" % (lua_str(k), v[0], slots(v[1])) for k, v in sorted(wild_water.items())) + "},")
    o.append("  -- trainers[\"CLASS:NAME\"] = the highest level in its party")
    o.append("  trainers = {" + ", ".join("[%s] = %d" % (lua_str(k), v) for k, v in sorted(trainers.items())) + "},")
    o.append("  -- prices[id] = {price, pocket} (ItemAttributes)")
    o.append("  prices = {" + ", ".join("[%d] = {%d, %s}" % (k, v[0], lua_str(v[1])) for k, v in sorted(prices.items())) + "},")
    o.append("}")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(o) + "\n")
    print("wrote %s: %d moves, %d chart entries, %d species, %d chars" % (out_path, len(moves), len(chart), len(species), len(charmap)))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
