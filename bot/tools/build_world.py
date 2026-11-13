"""Build modules/data/world_data.lua - every Crystal map, for the walker.

Usage:  python -I build_world.py <pokecrystal folder> <output .lua>

Read from the pokecrystal disassembly (the same data as the ROM, Crystal
1.0 and 1.1 alike):
  constants/map_constants.asm   map group/number (as wMapGroup/wMapNumber
                                hold them) and size in blocks
  data/maps/maps.asm            each map's name, tileset, environment
  data/maps/attributes.asm      connections to the maps around it
  data/maps/blocks.asm          which .blk holds its blocks
  data/tilesets.asm, gfx/tilesets.asm, data/tilesets/*_collision.asm
                                a block's 4 collision bytes (2x2 steps)
  maps/<Name>.asm               warps, scene triggers, people and things

Each map in the output: its collision, one byte per step (16x16 pixels -
the unit wXCoord/wYCoord count in), row by row, as hex; its warps, its
connections and its objects. Nothing here decides anything - world.lua
walks it with the game's own movement rules.
"""
import os, re, sys

ROOT, OUT = sys.argv[1], sys.argv[2]


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


# ---- collision constants: COLL_NAME -> value
COLL = {}
for m in re.finditer(r"DEF COLL_(\w+)\s+EQU \$([0-9a-fA-F]+)", read("constants/collision_constants.asm")):
    COLL[m.group(1)] = int(m.group(2), 16)

# ---- tilesets: index -> collision file (TilesetJohto -> TilesetJohtoColl -> johto_collision.asm)
tileset_names = re.findall(r"^\s*tileset (\w+)", read("data/tilesets.asm"), re.M)
coll_file = {}
pending = []
for line in read("gfx/tilesets.asm").splitlines():
    m = re.match(r"(\w+)Coll::", line)
    if m:
        pending.append(m.group(1))
        continue
    m = re.match(r'INCLUDE "(data/tilesets/\w+_collision\.asm)"', line)
    if m:
        for p in pending:
            coll_file[p] = m.group(1)
        pending = []
    elif line.strip() and not line.startswith(";"):
        pending = []


def tileset_collision(path):
    out = []
    for line in read(path).splitlines():
        m = re.match(r"\s*tilecoll (.*?)(;|$)", line)
        if m:
            out.append([COLL[s.strip()] for s in m.group(1).split(",")])
    return out


tileset_coll = {i: tileset_collision(coll_file[n]) for i, n in enumerate(tileset_names)}
tc = read("constants/tileset_constants.asm")
start = re.search(r"const_def\s*(\d*)", tc)
first = int(start.group(1)) if start and start.group(1) else 0
tileset_const = {name: first + i for i, name in enumerate(re.findall(r"^\s*const (TILESET_\w+)", tc, re.M))}

# ---- map constants: group/number/size, in order
groups = []       # [(group_name, [(CONST, w, h), ...])]
for line in read("constants/map_constants.asm").splitlines():
    m = re.match(r"\s*newgroup (\w+)", line)
    if m:
        groups.append((m.group(1), []))
        continue
    m = re.match(r"\s*map_const (\w+),\s*(\d+),\s*(\d+)", line)
    if m and groups:
        groups[-1][1].append((m.group(1), int(m.group(2)), int(m.group(3))))

# ---- maps.asm: name, tileset, environment, in the same order per group
maps_asm = read("data/maps/maps.asm")
group_tables = re.findall(r"^MapGroup_(\w+):\n(.*?)assert_table_length", maps_asm, re.M | re.S)
assert len(group_tables) == len(groups), (len(group_tables), len(groups))

# ---- blocks: label -> .blk file
blk_of = {}
labels = []
for line in read("data/maps/blocks.asm").splitlines():
    m = re.match(r"(\w+)_Blocks:", line)
    if m:
        labels.append(m.group(1))
        continue
    m = re.match(r'\s*INCBIN "(maps/\w+\.blk)"', line)
    if m:
        for l in labels:
            blk_of[l] = m.group(1)
        labels = []

# ---- attributes: connections
connections = {}
cur = None
for line in read("data/maps/attributes.asm").splitlines():
    m = re.match(r"\s*map_attributes (\w+), (\w+),", line)
    if m:
        cur = m.group(2)
        connections[cur] = {}
        continue
    m = re.match(r"\s*connection (\w+), \w+, (\w+), (-?\d+)", line)
    if m and cur:
        connections[cur][m.group(1)] = (m.group(2), int(m.group(3)))

# ---- event flags: EVENT_NAME -> number (bit in wEventFlags)
flags, value = {}, 0
for line in read("constants/event_flags.asm").splitlines():
    m = re.match(r"\s*(const_def|const_skip|const_next|const)(?:\s+(\w+))?\s*(?:;|$)", line)
    if not m:
        continue
    op, arg = m.group(1), m.group(2) or ""
    if op == "const_def":
        value = int(arg) if arg.isdigit() else 0
    elif op == "const_skip":
        value += int(arg) if arg.isdigit() else 1
    elif op == "const_next":
        value = int(arg)
    else:
        flags[arg] = value
        value += 1

maps = {}           # CONST -> dict
for gi, ((gname, consts), (tname, body)) in enumerate(zip(groups, group_tables), start=1):
    entries = re.findall(r"^\s*map (\w+), (TILESET_\w+), (\w+),", body, re.M)
    assert len(entries) == len(consts), (gname, len(entries), len(consts))
    for ni, ((const, w, h), (name, tileset, env)) in enumerate(zip(consts, entries), start=1):
        maps[const] = dict(const=const, name=name, group=gi, number=ni, w=w, h=h,
                           tileset=tileset_const[tileset], env=env)

# ---- per map: collision grid, warps, coord events, objects
def events(name):
    path = "maps/%s.asm" % name
    if not os.path.exists(os.path.join(ROOT, path)):
        return [], [], []
    src = read(path)
    warps = [(int(a), int(b), c, int(d)) for a, b, c, d in
             re.findall(r"^\s*warp_event\s+(\d+),\s*(\d+),\s*(\w+),\s*(-?\d+)", src, re.M)]
    coords = [(int(a), int(b), c) for a, b, c in
              re.findall(r"^\s*coord_event\s+(\d+),\s*(\d+),\s*(\w+),", src, re.M)]
    objs = []
    for m in re.finditer(r"^\s*object_event\s+(\d+),\s*(\d+),\s*(\w+),\s*(\w+),\s*(\d+),\s*(\d+),"
                         r"\s*(-?\d+),\s*(-?\d+),\s*\w+,\s*(\w+),\s*(\d+),\s*(\w+),\s*(-?\w+)", src, re.M):
        x, y, sprite, move, rx, ry, h1, h2, otype, sight, script, flag = m.groups()
        # A trainer's script is its header: `trainer CLASS, ID, EVENT_BEAT_..., ...` -
        # that flag is set once it's beaten (it won't stop you any more).
        beat = re.search(r"^%s:\s*\n\s*trainer \w+, \w+, (EVENT_\w+)" % re.escape(script), src, re.M)
        objs.append(dict(x=int(x), y=int(y), sprite=sprite.replace("SPRITE_", ""),
                         move=move.replace("SPRITEMOVEDATA_", ""), rx=int(rx), ry=int(ry),
                         type=otype.replace("OBJECTTYPE_", ""), sight=int(sight), script=script, flag=flag,
                         beat=beat.group(1) if beat else ""))
    return warps, coords, objs


for const, mp in maps.items():
    w, h = mp["w"], mp["h"]
    blk_path = blk_of.get(mp["name"])
    coll = tileset_coll[mp["tileset"]]
    grid = bytearray(4 * w * h)
    if blk_path:
        blk = open(os.path.join(ROOT, blk_path), "rb").read()
        for y in range(2 * h):
            for x in range(2 * w):
                b = blk[(y // 2) * w + x // 2]
                grid[y * 2 * w + x] = coll[b][(y % 2) * 2 + x % 2] if b < len(coll) else 0xFF
    mp["coll"] = grid.hex()
    mp["warps"], mp["coords"], mp["objs"] = events(mp["name"])
    mp["conn"] = connections.get(const, {})


# ---- write Lua
def q(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def key(const):
    m = maps[const]
    return "%d:%d" % (m["group"], m["number"])


out = ["-- world_data.lua (lives in modules/data/) - GENERATED by tools/build_world.py",
       "-- from the pokecrystal disassembly; don't edit by hand, run the tool again.",
       "-- maps[\"group:number\"] (wMapGroup:wMapNumber): name, w/h in blocks, env,",
       "-- coll (hex, a byte per step, 2w x 2h, row by row), warps {x, y, to, n}",
       "-- (n: the warp in `to` you arrive on, -1 = back where you came from),",
       "-- conn {north/south/west/east = {to, offset}}, coords {x, y, scene},",
       "-- objs {x, y, sprite, move, rx, ry, type, sight, script, flag (hidden while set),",
       "-- beat (a trainer's beaten flag)}; flags {EVENT_ = bit}.",
       "return {", "  maps = {"]
for const, m in maps.items():
    warps = ", ".join("{%d, %d, %s, %d}" % (x, y, q(key(to)) if to in maps else q(to), n) for x, y, to, n in m["warps"])
    conn = ", ".join("%s = {%s, %d}" % (d, q(key(to)), off) for d, (to, off) in m["conn"].items() if to in maps)
    coords = ", ".join("{%d, %d, %s}" % c for c in [(x, y, q(s)) for x, y, s in m["coords"]])
    objs = ", ".join("{%d, %d, %s, %s, %d, %d, %s, %d, %s, %s, %s}" % (
        o["x"], o["y"], q(o["sprite"]), q(o["move"]), o["rx"], o["ry"], q(o["type"]), o["sight"], q(o["script"]), q(o["flag"]),
        q(o["beat"])) for o in m["objs"])
    out.append('    [%s] = {name = %s, const = %s, w = %d, h = %d, env = %s, tileset = %d,' % (
        q(key(const)), q(m["name"]), q(const), m["w"], m["h"], q(m["env"]), m["tileset"]))
    out.append('      warps = {%s}, conn = {%s}, coords = {%s},' % (warps, conn, coords))
    out.append('      objs = {%s},' % objs)
    out.append('      coll = "%s"},' % m["coll"])
out.append("  },")
out.append("  -- wEventFlags bit of each EVENT_ flag (an object with one is hidden while it's set).")
out.append("  flags = {")
for name, n in sorted(flags.items(), key=lambda kv: kv[1]):
    out.append("    %s = %d," % (name, n))
out.append("  },")
out.append("}")
with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out) + "\n")
print("maps:", len(maps), "bytes:", os.path.getsize(OUT))
