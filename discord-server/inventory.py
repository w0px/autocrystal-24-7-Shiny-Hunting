# Read-only look at the server the setup bot is in: roles, channels (and
# who can see them), emoji, features. Changes nothing. The token is never printed.
#   python inventory.py [--token-file PATH]
import argparse, json, os, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--token-file", default=os.path.join(HERE, "bot_token.txt"))
ap.add_argument("--api", default="https://discord.com/api/v10")
a = ap.parse_args()
tok = open(a.token_file, encoding="utf-8").read().strip()
if tok.lower().startswith("bot "): tok = tok[4:].strip()


def get(path):
    req = urllib.request.Request(a.api + path, headers={"Authorization": "Bot " + tok, "User-Agent": "DiscordBot (https://github.com, 1.0) setup"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"_error": e.code, "_body": e.read().decode("utf-8", "replace")[:200]}


me = get("/users/@me")
if "_error" in me: raise SystemExit("Discord refused the token (%s)." % me["_error"])
print("Bot: %s (id %s)" % (me["username"], me["id"]))
guilds = get("/users/@me/guilds")
print("Servers the bot is in: %d" % len(guilds))
for g0 in guilds:
    g = get("/guilds/%s?with_counts=true" % g0["id"])
    print("\n=== %s (id %s) - %s members, owner id %s" % (g["name"], g["id"], g.get("approximate_member_count"), g.get("owner_id")))
    print("features: %s" % (", ".join(sorted(g.get("features") or [])) or "none"))
    print("verification %s, content filter %s, default notifications %s, icon %s" % (
        g.get("verification_level"), g.get("explicit_content_filter"), "only mentions" if g.get("default_message_notifications") else "all messages", "yes" if g.get("icon") else "no"))
    roles = sorted(get("/guilds/%s/roles" % g["id"]), key=lambda r: -r["position"])
    print("\nRoles (top first):")
    for r in roles:
        p = int(r["permissions"])
        flags = [f for f, b in (("ADMIN", 3), ("manage server", 5), ("manage channels", 4), ("manage roles", 28), ("ping everyone", 17)) if p >> b & 1]
        print("  %-28s pos %-3s %s%s%s" % (r["name"], r["position"], "managed " if r.get("managed") else "",
              "hoisted " if r.get("hoist") else "", ("[" + ", ".join(flags) + "]") if flags else ""))
    chans = get("/guilds/%s/channels" % g["id"])
    TYPES = {0: "#", 2: "voice", 4: "CATEGORY", 5: "news", 13: "stage", 15: "forum"}
    def hidden(c):
        for o in c.get("permission_overwrites", []):
            if o["id"] == g["id"] and int(o["deny"]) >> 10 & 1: return True
        return False
    cats = sorted([c for c in chans if c["type"] == 4], key=lambda c: c["position"])
    print("\nChannels:")
    loose = sorted([c for c in chans if c["type"] != 4 and not c.get("parent_id")], key=lambda c: c["position"])
    for c in loose: print("  %s %s%s" % (TYPES.get(c["type"], c["type"]), c["name"], "  (hidden from @everyone)" if hidden(c) else ""))
    for cat in cats:
        print("  [%s]%s" % (cat["name"], "  (hidden from @everyone)" if hidden(cat) else ""))
        for c in sorted([c for c in chans if c.get("parent_id") == cat["id"]], key=lambda c: c["position"]):
            print("     %s %s%s" % (TYPES.get(c["type"], c["type"]), c["name"], "  (hidden from @everyone)" if hidden(c) else ""))
    em = get("/guilds/%s/emojis" % g["id"])
    if isinstance(em, list):
        print("\nEmoji: %d (%s)" % (len(em), ", ".join(x["name"] for x in em[:30])))
    ob = get("/guilds/%s/onboarding" % g["id"])
    if "_error" not in ob: print("Onboarding: %s, %d question(s)" % ("on" if ob.get("enabled") else "off", len(ob.get("prompts", []))))
