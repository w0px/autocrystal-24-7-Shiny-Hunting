# Posts to the server's bot channels through their webhooks (webhooks.txt):
#   python discord_posts.py release [v1.2.0] [--ping]
#       #releases: one post - the rotating shiny Teddiursa centred over the version,
#                  the GitHub release's notes under it, Download / Release page
#                  buttons; pings Release Ping only with --ping (the user, 2026-11-13:
#                  the Pokegear card was too playful, patch notes go with the release)
#   python discord_posts.py daily-test
#       #daily-log:   the spinning shiny Teddiursa on top, then a placeholder box
#                     (the real 24h text comes from the bot later)
import argparse, datetime, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sync_readme import call, say, Fail
import readme_to_discord as R2D

REPO = "w0px/autocrystal-Shiny-Hunting-Toolkit"
GH = r"C:\Program Files\GitHub CLI\gh.exe"
SPACER = os.path.join(HERE, "..", "bot", "data", "sprites", "spacer_360.png")
hooks = dict(l.strip().split("=", 1) for l in open(os.path.join(HERE, "webhooks.txt"), encoding="utf-8") if "=" in l)
state = json.load(open(os.path.join(HERE, "server_state.json"), encoding="utf-8"))

# ---- the box, as the shiny card draws it (37 letters wide) -----------------
ESC = "\u001b"
COL = {"grey": "30", "red": "31", "green": "32", "yellow": "33", "blue": "34", "pink": "35", "cyan": "36", "white": "37"}
c = lambda col, s: "%s[%sm%s%s[0m" % (ESC, COL[col], s, ESC)
vis = lambda s: len(re.sub(ESC + r"\[[\d;]*m", "", s))
BOX = 35
def rule(l, title, r):
    if not title: return c("grey", l + "─" * BOX + r)
    return c("grey", l + "─ ") + c("white", title) + c("grey", " " + "─" * (BOX - len(title) - 3) + r)
def boxed(sections):
    out = []
    for i, (title, rows) in enumerate(sections):
        if i: out.append(c("grey", "│") + " " * BOX + c("grey", "│"))
        out.append(rule("┌" if i == 0 else "├", title, "┐" if i == 0 else "┤"))
        for r in rows: out.append(c("grey", "│") + " " + r + " " * max(0, BOX - 1 - vis(r)) + c("grey", "│"))
    out.append(rule("└", None, "┘"))
    return "```ansi\n" + "\n".join(out) + "\n```"
def lr(label, value, col=None):
    return label + " " * max(1, BOX - 2 - len(label) - len(value)) + (c(col, value) if col else value)


def post(channel, body, files=(), components=False):
    url = hooks[channel] + "?wait=true" + ("&with_components=true" if components else "")
    body.setdefault("allowed_mentions", {"parse": []})
    if files: body["attachments"] = [{"id": i, "filename": f[0]} for i, f in enumerate(files)]
    x = call("POST", url, body, list(files))
    say(" posted to #%s" % channel)
    return x


def release(tag, ping):
    args = [GH, "release", "view", "--repo", REPO, "--json", "tagName,name,url,body,assets,publishedAt"] + ([tag] if tag else [])
    r = json.loads(subprocess.run(args, capture_output=True, check=True).stdout.decode("utf-8"))
    tag = r["tagName"]
    zipurl = next((a["url"] for a in r.get("assets", []) if a["name"].endswith(".zip")), r["url"])
    role = state["roles"]["Release Ping"]
    notes = "\n\n".join(m["content"] for m in R2D.convert(r["body"], 0))
    # (one card can hold 4,096 letters; longer notes go on in more cards, up to
    # Discord's 6,000 for the whole post - past that, a link to the rest)
    chunks, rest = [], notes
    while rest and len(chunks) < 3:
        cut = len(rest) if len(rest) <= 4000 else rest.rfind("\n", 0, 4000)
        chunks.append(rest[:cut].strip()); rest = rest[cut:].strip()
    if rest or sum(map(len, chunks)) > 5400:
        chunks = [notes[:5000].rsplit("\n", 1)[0] + "\n\n…the rest on the [release page](<%s>)." % r["url"]]
        if len(chunks[0]) > 4096: chunks = [chunks[0][:3900].rsplit("\n", 1)[0] + "\n\n…the rest on the [release page](<%s>)." % r["url"]]
    GREEN = 0x8BC34A
    embeds = [{"color": GREEN, "title": "autocrystal %s" % tag, "url": r["url"], "image": {"url": "attachment://release_teddy.gif"}}]
    for i, ch in enumerate(chunks):
        e = {"color": GREEN, "description": ch, "image": {"url": "attachment://spacer_400.png"}}
        if i == len(chunks) - 1:
            e["footer"] = {"text": "autocrystal · Windows · Gold, Silver & Crystal"}
            if r.get("publishedAt"): e["timestamp"] = r["publishedAt"]
        embeds.append(e)
    body = {"content": "<@&%s>" % role, "embeds": embeds,
            "components": [{"type": 1, "components": [
                {"type": 2, "style": 5, "label": "Download " + tag, "url": zipurl},
                {"type": 2, "style": 5, "label": "Release page", "url": r["url"]}]}]}
    if ping: body["allowed_mentions"] = {"roles": [role]}
    files = [("release_teddy.gif", open(os.path.join(HERE, "art", "release_teddy_400.gif"), "rb").read()),
             ("spacer_400.png", open(os.path.join(HERE, "art", "spacer_400.png"), "rb").read())]
    try:
        post("releases", body, files, components=True)
    except Fail as e:
        say(" (buttons refused: %s - the links go in the text)" % str(e)[:120])
        body.pop("components")
        body["content"] += " [Download %s](<%s>) · [Release page](<%s>)" % (tag, zipurl, r["url"])
        post("releases", body, files)


def daily_test(icon="teddy"):
    # (placeholder numbers - the real ones come from the dev bot's day recap and
    # its rare-event lines: almost shiny, four of a kind, DV records, streaks)
    now = datetime.datetime.now()
    day = [lr("ENCOUNTERS", "4,812"), lr("SHINIES", "1 · GASTLY", "yellow"),
           lr("NEAR MISSES", "2", "cyan"), lr("PERFECT / 0-0-0-0 DVS", "0"),
           lr("FOUR OF A KIND", "1"), lr("LONGEST STREAK", "9 PIDGEY"),
           lr("BEST DVS", "56/60 HOOTHOOT"), lr("WORST DVS", "3/60 ZUBAT"),
           lr("MONEY FROM JOEY", "+¥3,240", "green"), lr("HOURS HUNTED", "24.0")]
    rare = [c("cyan", "ALMOST SHINY") + "  SENTRET 3/10/10/10",
            c("cyan", "ALMOST SHINY") + "  RATTATA 12/10/10/10",
            c("yellow", "FOUR OF A KIND") + "  GEODUDE 7/7/7/7",
            "  " + c("grey", "1 IN 4,681"),
            c("yellow", "9 PIDGEY IN A ROW") + "  " + c("grey", "1 IN 2,300")]
    tot = [lr("TOTAL ENCOUNTERS", "72,502"), lr("TOTAL SHINIES", "9"), lr("UNIQUE SHINIES", "7"),
           lr("SINCE LAST SHINY", "8,424", "yellow"), c("grey", "36% OF HUNTS GO THIS LONG")]
    stamp = now.astimezone().isoformat(timespec="seconds")
    pic = {"teddy": "daily_teddy_360.gif", "ball": "daily_ball_360.gif"}[icon]
    body = {"embeds": [
        {"color": 0x8BC34A, "author": {"name": "📊 Daily log · %s" % now.strftime("%a %d %b %Y")},
         "image": {"url": "attachment://daily_icon.gif"}},
        {"color": 0x8BC34A, "description": boxed([("LAST 24 HOURS", day), ("RARE MOMENTS", rare), ("ALL TIME", tot)]),
         "image": {"url": "attachment://spacer_360.png"},
         "footer": {"text": "autocrystal · TEST daily log (%s) - placeholder numbers" % icon}, "timestamp": stamp}]}
    files = [("daily_icon.gif", open(os.path.join(HERE, "art", pic), "rb").read()),
             ("spacer_360.png", open(SPACER, "rb").read())]
    post("daily-log", body, files)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["release", "daily-test"])
    ap.add_argument("tag", nargs="?")
    ap.add_argument("--ping", action="store_true", help="release: really ping Release Ping")
    ap.add_argument("--icon", default="teddy", choices=["teddy", "ball"], help="daily-test: the picture on top")
    a = ap.parse_args()
    try:
        release(a.tag, a.ping) if a.what == "release" else daily_test(a.icon)
    except Fail as e:
        raise SystemExit(str(e))
