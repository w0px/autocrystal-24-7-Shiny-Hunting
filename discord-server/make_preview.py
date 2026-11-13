# Draws server_layout.json the way Discord will show it: the channel list,
# the roles, the join question and the welcome / rules posts.
#   python make_preview.py [out.html]
import html, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = json.load(open(os.path.join(HERE, "server_layout.json"), encoding="utf-8"))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "mockups", "discord_server_preview.html")
e = html.escape

ICON = {"text": "#", "news": "📢", "voice": "🔊"}
TAG = {"readonly": '<span class="tag ro">read-only · reactions ok</span>',
       "staff": '<span class="tag st">staff only</span>', "chat": ""}


def md(line):
    s = e(line)
    s = re.sub(r"&lt;#([\w-]+)&gt;", r'<span class="chan">#\1</span>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    if s.startswith("# "):
        return "<h2>%s</h2>" % s[2:]
    return (s or "&nbsp;") + "<br>"


def sidebar():
    s = ['<div class="side"><div class="sname">Shiny Oak</div>',
         '<div class="nav">🗂️ Channels &amp; Roles</div><div class="nav">🔎 Browse Channels</div>']
    for cat in L["categories"]:
        s.append('<div class="cat">⌄ %s</div>' % e(cat["name"]))
        for ch in cat["channels"]:
            extra = ""
            if ch.get("webhook"):
                extra += '<span class="tag bot">bot posts</span>'
            s.append('<div class="ch"><span class="ic">%s</span>%s %s%s</div>' % (ICON[ch["kind"]], e(ch["name"]), TAG[ch["access"]], extra))
    s.append("</div>")
    return "".join(s)


def roles():
    s = ['<div class="card"><div class="ct">Roles</div>']
    for r in L["roles"]:
        perms = ", ".join(p.replace("_", " ").lower() for p in r["perms"] if p != "member")
        what = r.get("note") or ("all permissions" if "ADMINISTRATOR" in r["perms"] else perms)
        if r["perms"] == ["member"] and not r.get("note"):
            what = "normal member"
        s.append('<div class="role"><span class="dot" style="background:%s"></span><b style="color:%s">%s</b><span class="rn">%s%s</span></div>'
                 % (r["color"], r["color"], e(r["name"]), e(what), " · shown separately" if r["hoist"] else ""))
    s.append('<div class="small">Ping roles can\'t be pinged by members - only the bot\'s posts ping them.</div></div>')
    return "".join(s)


def onboarding():
    q = L["onboarding"]["questions"][0]
    s = ['<div class="card ob"><div class="ct">When someone joins</div><div class="obq">%s</div><div class="small">%s</div><div class="opts">'
         % (e(q["title"]), "pick one or more · required" if q["multiple"] and q["required"] else "")]
    for o in q["options"]:
        s.append('<div class="opt"><span class="em">%s</span><div><b>%s</b><div class="od">%s</div><div class="or">gives: %s</div></div></div>'
                 % (o["emoji"], e(o["title"]), e(o["description"]), e(", ".join(o["roles"]))))
    s.append('</div><div class="small">Everyone ends up with <b>Trainer</b>, whatever they pick. Existing members change their pings any time in <b>Channels &amp; Roles</b>.</div></div>')
    return "".join(s)


def post(name):
    return '<div class="card msg"><div class="who"><span class="av">✨</span><b>Shiny Oak Setup</b><span class="botb">APP</span><span class="time">in #%s</span></div><div class="body">%s</div></div>' % (
        name, "".join(md(l) for l in L["messages"][name]))


def server_settings():
    rows = [("Default notifications", "only @mentions (nobody gets a ping for every message)"),
            ("Join messages", "#general"),
            ("Verification", "members need a verified email and a 5 minute old account"),
            ("Media filter", "scans media from all members"),
            ("Community mode", "on (needed for Channels & Roles and the join question)"),
            ("Bot posts", "webhooks in #shinies, #daily-log, #releases, #patch-notes; #shinies and #releases can ping their role")]
    return '<div class="card"><div class="ct">Server settings</div>%s</div>' % "".join(
        '<div class="kv"><span>%s</span><span>%s</span></div>' % (e(k), e(v)) for k, v in rows)


CSS = """
:root{--bg:#313338;--side:#2b2d31;--card:#2b2d31;--text:#dbdee1;--mut:#949ba4;--line:#3f4147}
*{box-sizing:border-box}body{margin:0;background:#1e1f22;color:var(--text);font:15px/1.4 'gg sans','Segoe UI',sans-serif}
header{padding:18px 24px}h1{margin:0 0 4px;font-size:22px}header p{margin:0;color:var(--mut)}
.wrap{display:flex;gap:16px;padding:0 24px 24px;align-items:flex-start}
.side{background:var(--side);border-radius:8px;width:330px;flex:none;padding-bottom:10px}
.sname{font-weight:700;padding:14px 16px;border-bottom:1px solid #1f2023}
.nav{padding:6px 16px;color:var(--mut)}
.cat{font-size:12px;font-weight:700;color:var(--mut);padding:16px 16px 4px;letter-spacing:.3px}
.ch{padding:4px 16px 4px 22px;color:#b5bac1;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.ic{width:20px;text-align:center;color:#80848e;font-size:17px}
.tag{font-size:10.5px;border-radius:4px;padding:1px 5px;font-weight:600}
.ro{background:#3b3d44;color:#c9ccd1}.st{background:#5a2b2b;color:#f0b3b3}.bot{background:#36397a;color:#c9cdfb}
.col{display:flex;flex-direction:column;gap:16px;flex:1;min-width:0}
.card{background:var(--card);border-radius:8px;padding:14px 16px}
.ct{font-size:12px;font-weight:700;color:var(--mut);letter-spacing:.3px;margin-bottom:10px;text-transform:uppercase}
.role{display:flex;align-items:center;gap:8px;padding:4px 0}.dot{width:12px;height:12px;border-radius:50%;flex:none}
.rn{color:var(--mut);font-size:13px}.small{color:var(--mut);font-size:13px;margin-top:8px}
.obq{font-size:18px;font-weight:700}
.opts{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:10px}
.opt{display:flex;gap:10px;background:#383a40;border-radius:8px;padding:10px 12px}.em{font-size:22px}
.od{color:var(--mut);font-size:13px}.or{color:#8ea1e1;font-size:12px;margin-top:2px}
.who{display:flex;align-items:center;gap:8px;margin-bottom:6px}.av{width:34px;height:34px;border-radius:50%;background:#5865f2;display:grid;place-items:center}
.botb{background:#5865f2;color:#fff;font-size:10px;border-radius:3px;padding:0 4px}.time{color:var(--mut);font-size:12px}
.body{padding-left:42px}.body h2{font-size:20px;margin:0 0 6px}.chan{background:#3c4270;color:#c9cdfb;border-radius:3px;padding:0 2px}
.kv{display:flex;gap:12px;padding:4px 0;border-top:1px solid var(--line)}.kv span:first-child{width:170px;flex:none;color:var(--mut)}
.two{display:flex;gap:16px}.two>.card{flex:1}
"""

page = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>Shiny Oak Server</title><style>%s</style></head><body>" % CSS,
        "<header><h1>Shiny Oak Discord - what the setup builds</h1><p>Drawn from server_layout.json. Nothing has been created yet.</p></header>",
        '<div class="wrap">', sidebar(), '<div class="col">', onboarding(), '<div class="two">', roles(), server_settings(), "</div>",
        '<div class="two">', post("welcome"), post("rules"), "</div></div></div></body></html>"]
open(OUT, "w", encoding="utf-8").write("".join(page))
print("ok", os.path.abspath(OUT))
