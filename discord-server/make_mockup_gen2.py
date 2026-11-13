# Mockup of the server with Gen 2 artwork: the pictures the bot would post
# (text boxes and Pokegear cards drawn with the overlay's gsc.js from the
# game's own tiles and font), the custom emoji, Delibird as the bot, and the
# README as forum posts (readme_to_discord.py). Served over http (gsc.js
# fetches its tiles):
#   python make_mockup_gen2.py <tmp_discord_caught.json> <readme_posts.json>
import html, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "mockups", "discord_server_gen2.html")
CAUGHT, POSTS = sys.argv[1], sys.argv[2]
e = html.escape

ANSI = {"30": "a0", "31": "ar", "32": "ag", "33": "ay", "34": "ab", "35": "ap", "36": "ac", "37": "aw", "1;37": "aw"}
def ansi(text):
    out, cls = [], None
    for part in re.split(r"(\x1b\[[\d;]*m)", text):
        m = re.match(r"\x1b\[([\d;]*)m", part)
        if m:
            cls = ANSI.get(m.group(1)) if m.group(1) != "0" else None
            continue
        if part:
            out.append('<span class="%s">%s</span>' % (cls, e(part)) if cls else e(part))
    return "".join(out)

p = json.load(open(CAUGHT, encoding="utf-8"))
panel = "<pre>%s</pre>" % ansi(re.match(r"```ansi\n(.*)\n```", p["embeds"][1]["description"], re.S).group(1))

EMO = "../bot/bot%20emojies/"
ART = "../discord-server/art/"
EMOJI = [("info", ART + "info_standin.png", "stand-in - drop your \"!\" picture into bot emojies"),
         ("ball", ART + "ball_emoji.gif", "animated · trimmed to the ball"),
         ("rotating_bear", EMO + "Rotating_Green_Bear.gif", "animated"),
         ("perfect", EMO + "15151515.png", ""), ("yes", EMO + "yes.PNG", ""), ("no", EMO + "no.PNG", ""),
         ("joey_sad", EMO + "joey%20sad.png", ""), ("joey_paying", EMO + "joeypaying.png", "shrunk: 714 KB is over the 256 KB limit"),
         ("shiny_rock", EMO + "shinyrock.png", ""), ("shiny_teddy", EMO + "ShinyTeddy.PNG", ""),
         ("wormking", EMO + "wormking.gif", "animated · shrunk: 262 KB"), ("phanpy_rotating", EMO + "pahnpy_rotating.gif", "animated")]
def emo(name, big=False):
    f = next(x[1] for x in EMOJI if x[0] == name)
    return '<img class="emo%s" src="%s" alt=":%s:">' % (" big" if big else "", f, name)

AV = '<img class="av" src="%sdelibird.png" alt="">' % ART
def who(clock, chan):
    return '<div class="who">%s<b>autocrystal</b><span class="botb">APP</span><span class="time">Today at %s · #%s</span></div>' % (AV, clock, chan)

# ---- Discord markdown -> html (enough for the README posts) ---------------
def inline(s):
    s = e(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\[([^\]]+)\]\(&lt;(.+?)&gt;\)", r'<a>\1</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", s)
    return s
def md(text):
    out, code, buf = [], False, []
    for line in text.split("\n"):
        if line.startswith("```"):
            if code: out.append("<pre class='cb'>%s</pre>" % e("\n".join(buf))); buf = []
            code = not code; continue
        if code: buf.append(line); continue
        if line.startswith("## "): out.append("<h3>%s</h3>" % inline(line[3:]))
        elif line.startswith("### "): out.append("<h4>%s</h4>" % inline(line[4:]))
        elif re.match(r"^\s*[-*] ", line):
            ind = len(line) - len(line.lstrip())
            out.append('<div class="li" style="margin-left:%dpx">• %s</div>' % (8 + ind * 8, inline(line.strip()[2:])))
        elif line.strip() == "": out.append('<div class="gap"></div>')
        else: out.append("<div>%s</div>" % inline(line))
    return "".join(out)

# ---- sidebar ---------------------------------------------------------------
SIDEBAR = [("INFO", [("#", "welcome", "ro"), ("#", "rules", "ro"), ("📢", "announcements", "ro"), ("#", "stream-links", "ro"), ("#", "faq", "ro")]),
           ("LIVE HUNTING NOTIFICATIONS", [("#", "shinies", "ro"), ("#", "shiny-clips", "ro"), ("#", "daily-log", "ro")]),
           ("AUTOCRYSTAL USER BOT", [("📢", "releases", "ro"), ("#", "patch-notes", "ro"), ("#", "bot-help", "")]),
           ("AUTOCRYSTAL README", [("🗂️", "readme", "forum")]),
           ("COMMUNITY", [("#", "general", ""), ("#", "shiny-talk", ""), ("#", "screenshots", ""), ("#", "suggestions", ""), ("#", "off-topic", "")]),
           ("STAFF", [("#", "mod-chat", "staffwrite"), ("🔒", "mod-log", "staff")])]
TAGS = {"ro": '<span class="tag ro">read-only</span>', "staffwrite": '<span class="tag sw">staff writes</span>',
        "staff": '<span class="tag st">hidden</span>', "forum": '<span class="tag ro">forum · read-only</span>', "": ""}
side = ['<div class="side"><div class="sname"><span class="sicon">?</span>24/7 Shiny Hunting</div>',
        '<div class="nav">🗂️ Channels &amp; Roles</div>']
for cat, chans in SIDEBAR:
    side.append('<div class="cat">⌄ %s</div>' % e(cat))
    for ic, name, t in chans:
        side.append('<div class="ch"><span class="ic">%s</span>%s %s</div>' % (ic, name, TAGS[t]))
side.append('<div class="sidenote">The server icon stays as it is ("?" here).</div></div>')

# ---- right column ----------------------------------------------------------
opts = [("rotating_bear", "Shinies", "Every shiny the stream finds"), ("perfect", "Perfect & 0/0/0/0 DVs", "The rare DV hits"),
        ("ball", "autocrystal releases", "New versions of the bot"), ("no", "No pings", "Just here to hang out")]
onboard = ['<div class="card"><div class="ct">Join question · Discord\'s own screen</div><div class="obq">Which pings do you want?</div><div class="opts">']
for em, t, d in opts:
    onboard.append('<div class="opt">%s<div><b>%s</b><div class="od">%s</div></div></div>' % (emo(em, True), e(t), e(d)))
onboard.append("</div></div>")

emolist = ['<div class="card"><div class="ct">Server emoji</div><div class="emogrid">']
for name, f, note in EMOJI:
    emolist.append('<div class="eg">%s<div><code>:%s:</code><div class="od">%s</div></div></div>' % (emo(name, True), name, e(note)))
emolist.append('</div><div class="ct" style="margin-top:14px">+ Gen 2 sprite emoji from the game\'s pictures</div><div class="spr" id="sprites"></div></div>')

avatar = ('<div class="card"><div class="ct">The bot</div><div class="avrow">'
          '<div class="bigav"><img src="%sdelibird.png"></div><div><b class="nm">autocrystal</b><span class="botb">APP</span>'
          '<div class="od">Delibird. The webhooks post with the same name and picture.</div></div></div></div>' % ART)

def chan(name, topic, inner, icon="#"):
    return '<div class="chan"><div class="chh">%s %s<span>%s</span></div>%s</div>' % (icon, name, e(topic), inner)

faq = chan("faq", "read-only · reactions ok", who("12:00", "faq") + '<div class="body md">'
    + md("## %s Is the stream really live?\nYes. What you see is the game running right now, at normal speed. Nothing is sped up or cut.\n\n"
         "## %s Is the game modified?\nNo. It's vanilla Pokémon Crystal - the bot only presses buttons, like a player would.\n\n"
         "## %s Can I run the bot myself?\nYes, it's free. Everything is in #readme, downloads in #releases, questions in #bot-help.") % (emo("info"), emo("info"), emo("ball"))
    + '<div class="note">Draft questions - you write the real ones.</div></div>')
links_c = chan("stream-links", "read-only · reactions ok", who("12:00", "stream-links") + '<div class="body md">'
    + md("## Watch live\n**YouTube** - [24/7 Shiny Hunting](<https://youtube.com/>)\n**GitHub** - [autocrystal](<https://github.com/>)") + "</div>")
daily = chan("daily-log", "read-only · reactions ok", '<div class="empty">Empty for now - your bot posts here later.</div>')
clips = chan("shiny-clips", "read-only · reactions ok", '<div class="empty">Clips of the shinies (you or the mods post them; everyone can react).</div>')

# ---- middle column ---------------------------------------------------------
welcome = chan("welcome", "read-only · reactions ok", who("12:00", "welcome") + '<div class="body md"><canvas class="gb" id="g_welcome"></canvas>'
    + md("## %s What this is\n24/7 Shiny Hunting is a YouTube stream that never stops: **Pokémon Crystal**, played by **autocrystal**, a bot. "
         "The game is vanilla, it runs at normal speed, and there are no resets - every shiny you see happened live.\n\n"
         "## %s Where things are\n- @@stream-links - watch the stream\n- @@shinies - every shiny, perfect DV and 0/0/0/0, the moment it shows up\n"
         "- @@shiny-clips - the best moments\n- @@readme - how to run autocrystal yourself\n- @@bot-help - questions about the bot\n- @@general - chat\n\n"
         "## %s Pings\nNobody gets pinged unless they ask for it. Pick yours in **Channels & Roles**, and change them any time.") % (emo("info"), emo("ball"), emo("info"))
    + '<div class="react"><span>%s 31</span><span class="off">%s 12</span></div></div>' % (emo("ball"), emo("rotating_bear")))
welcome = re.sub(r"@@([\w-]+)", r'<span class="lnk">#\1</span>', welcome)
rules = chan("rules", "read-only · reactions ok", who("12:00", "rules") + '<div class="body"><canvas class="gb" id="g_rules"></canvas>'
    '<div class="note">The same rules are in the message text too, so they can be searched and translated.</div></div>')
shinies = chan("shinies", "read-only · reactions ok", who("23:42", "shinies") + '<div class="body"><div class="txt"><span class="lnk">@Shiny Ping</span></div>'
    '<div class="embed"><div class="au">✨ Shiny Gastly! · No.092 · LV 4</div><img class="sp" src="../bot/data/sprites/animated_discord_big/shiny/92.gif"></div>'
    '<div class="embed">%s</div><div class="react"><span>%s 12</span><span class="off">%s 5</span><span class="off">%s 3</span></div></div>'
    % (panel, emo("rotating_bear"), emo("ball"), emo("perfect")))
releases = chan("releases", "read-only · reactions ok", who("18:30", "releases") + '<div class="body"><div class="txt"><span class="lnk">@Release Ping</span></div><canvas class="gb" id="g_radio"></canvas>'
    '<div class="txt"><b>autocrystal v1.3.0</b> · download: github.com/…/releases</div>'
    '<div class="react"><span>%s 9</span><span class="off">%s 4</span></div></div>' % (emo("ball"), emo("yes")), "📢")

P = json.load(open(POSTS, encoding="utf-8"))
TAGC = {"Getting Started": "#3ba55d", "Launcher": "#5865f2", "Modules": "#f1c40f", "FAQ": "#9b59b6", "Deep Dive": "#e67e22"}
flist = ['<div class="forum"><div class="ftags">%s</div>' % "".join('<span class="ftag" style="--c:%s">%s</span>' % (c, t) for t, c in TAGC.items())]
for i, post in enumerate(P[:8]):
    first = re.sub(r"[#*`\[\]]|\(<[^>]*>\)", "", post["messages"][0]["content"] or (post["messages"][1]["content"] if len(post["messages"]) > 1 else ""))[:150]
    flist.append('<div class="fpost"><div class="ft">%s%s</div><div class="fx">%s…</div><div class="fm"><span class="ftag" style="--c:%s">%s</span> %d messages%s</div></div>'
                 % ("📌 " if i == 0 else "", e(post["title"]), e(first), TAGC.get(post["tag"], "#888"), e(post["tag"]), len(post["messages"]), " · pinned" if i == 0 else ""))
flist.append('<div class="fmore">… %d posts in all, %d messages, %d pictures</div></div>' % (len(P), sum(len(x["messages"]) for x in P), sum(len(m["images"]) for x in P for m in x["messages"])))
ga = next(x for x in P if x["title"] == "Game Assistant")
opened = ['<div class="thread"><div class="tht">Game Assistant <span class="ftag" style="--c:%s">%s</span></div>' % (TAGC["Launcher"], "Launcher")]
for m in ga["messages"][:4]:
    opened.append(who("12:00", "readme").replace("· #readme", "· readme") + '<div class="body md">' + md(m["content"]))
    for im in m["images"]:
        if im["src"].startswith("images/"):
            opened.append('<img class="rimg" src="readme_img/%s" alt="">' % os.path.basename(im["src"]))
    opened.append("</div>")
opened.append('<div class="note">…%d more messages. Links to other sections go to GitHub; the table became one line per row.</div></div>' % (len(ga["messages"]) - 4))
readme = chan("readme", "forum · read-only · reactions ok · always the newest README", "".join(flist) + "".join(opened), "🗂️")

CSS = """
:root{--bg:#313338;--side:#2b2d31;--card:#2b2d31;--text:#dbdee1;--mut:#949ba4;--line:#3f4147}
*{box-sizing:border-box}body{margin:0;background:#1e1f22;color:var(--text);font:15px/1.4 'gg sans','Segoe UI',sans-serif}
header{padding:18px 24px}h1{margin:0 0 4px;font-size:22px}header p{margin:0;color:var(--mut)}
.wrap{display:flex;gap:16px;padding:0 24px 24px;align-items:flex-start}
.side{background:var(--side);border-radius:8px;width:240px;flex:none;padding-bottom:10px}
.sname{font-weight:700;padding:12px;border-bottom:1px solid #1f2023;display:flex;align-items:center;gap:8px}
.sicon{width:28px;height:28px;border-radius:50%;background:#4e5058;display:grid;place-items:center;color:#aaa;font-size:13px}
.nav{padding:8px 12px;color:var(--mut)}
.cat{font-size:12px;font-weight:700;color:var(--mut);padding:16px 8px 4px;letter-spacing:.2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch{padding:3px 8px 3px 14px;color:#b5bac1;display:flex;align-items:center;gap:5px;white-space:nowrap}
.ic{width:18px;text-align:center;color:#80848e}
.tag{font-size:10px;border-radius:4px;padding:0 4px;font-weight:600}
.ro{background:#3b3d44;color:#c9ccd1}.st{background:#5a2b2b;color:#f0b3b3}.sw{background:#2b3f5a;color:#b3d0f0}
.sidenote{color:var(--mut);font-size:11.5px;padding:10px 12px 0}
.col{display:flex;flex-direction:column;gap:16px;flex:1;min-width:0}
.colr{display:flex;flex-direction:column;gap:16px;width:430px;flex:none}
.chan{background:var(--bg);border-radius:8px;padding:12px 16px 16px}
.chh{font-weight:700;color:#f2f3f5;border-bottom:1px solid var(--line);padding-bottom:8px;margin-bottom:12px}
.chh span{color:var(--mut);font-weight:400;font-size:13px;margin-left:8px}
.card{background:var(--card);border-radius:8px;padding:14px 16px}
.ct{font-size:12px;font-weight:700;color:var(--mut);letter-spacing:.3px;margin-bottom:10px;text-transform:uppercase}
.who{display:flex;align-items:center;gap:8px;margin:10px 0 2px}
.av{width:40px;height:40px;border-radius:50%;background:#f8f8f0;object-fit:contain;image-rendering:pixelated;padding:3px}
.botb{background:#5865f2;color:#fff;font-size:10px;border-radius:3px;padding:0 4px;margin-left:4px}.time{color:var(--mut);font-size:12px}
.body{padding-left:48px}
.md h3{font-size:20px;margin:10px 0 4px;display:flex;align-items:center;gap:6px}.md h4{font-size:16px;margin:8px 0 2px}.md .gap{height:6px}.md .li{margin:1px 0}
.md a{color:#00a8fc}.md code{background:#1e1f22;border-radius:3px;padding:0 3px;font-size:13px}
.gb{image-rendering:pixelated;display:block;margin:6px 0;border-radius:4px}
.emo{width:22px;height:22px;object-fit:contain;vertical-align:-5px;image-rendering:pixelated}.emo.big{width:36px;height:36px;flex:none}
.md h3 .emo{width:28px;height:28px}
.react{display:flex;gap:6px;margin-top:6px}.react span{background:#2f3a6b;border:1px solid #5865f2;border-radius:8px;padding:2px 7px;font-size:13px;display:flex;align-items:center;gap:5px}
.react span.off{background:#2b2d31;border-color:#2b2d31}
.obq{font-size:18px;font-weight:700}.opts{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:10px}
.opt,.eg{display:flex;gap:10px;align-items:center;background:#383a40;border-radius:8px;padding:8px 10px}
.od{color:var(--mut);font-size:12.5px}
.emogrid{display:grid;grid-template-columns:1fr 1fr;gap:6px}.eg code{color:#e3e5e8;font-size:13px}
.spr{display:flex;flex-wrap:wrap;gap:6px}.spr canvas{width:48px;height:48px;image-rendering:pixelated;background:#383a40;border-radius:6px}
.avrow{display:flex;gap:14px;align-items:center}.bigav{width:80px;height:80px;border-radius:50%;background:#f8f8f0;display:grid;place-items:center;flex:none;overflow:hidden}
.bigav img{width:64px;image-rendering:pixelated}.nm{font-size:17px}
.embed{background:#2b2d31;border-left:4px solid #3ba55d;border-radius:4px;padding:8px 14px 12px 12px;width:392px;margin-top:4px}
.embed .au{font-weight:600;font-size:14px;margin-bottom:6px}.embed img.sp{width:360px;display:block}
pre{background:#1e1f22;border:1px solid #2a2a30;border-radius:4px;font:14.9px/1.3 Consolas,monospace;padding:8px 11px;margin:6px 0 0;white-space:pre;overflow:hidden}
.a0{color:#4f545c}.ar{color:#dc322f}.ag{color:#859900}.ay{color:#b58900}.ab{color:#268bd2}.ap{color:#d33682}.ac{color:#2aa198}.aw{color:#fff}
.txt{margin:6px 0 0}.lnk{background:#3c4270;color:#c9cdfb;border-radius:3px;padding:0 2px}
.note{color:var(--mut);font-size:12.5px;margin-top:6px}.empty{color:var(--mut);font-size:13px;padding:6px 0}
.forum{display:flex;flex-direction:column;gap:6px}.ftags{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:4px}
.ftag{border:1px solid var(--c);color:var(--c);border-radius:10px;padding:0 8px;font-size:11.5px;font-weight:600}
.fpost{background:#2b2d31;border-radius:8px;padding:8px 12px}.ft{font-weight:700}.fx{color:var(--mut);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fm{color:var(--mut);font-size:12px;margin-top:3px}.fmore{color:var(--mut);font-size:12.5px;padding:2px 4px}
.thread{margin-top:14px;border-top:1px solid var(--line);padding-top:10px}.tht{font-size:18px;font-weight:700;display:flex;gap:8px;align-items:center}
.rimg{max-width:400px;max-height:350px;border-radius:6px;display:block;margin:6px 0}
"""

JS = r"""
<script src="../bot/overlay/gsc.js"></script>
<script>
(async () => {
  const B = "../bot/overlay/gfx/";
  const g = await GSC.load(B, { frame: 1 });
  const S = 2;
  const draw = (id, s) => { const c = document.getElementById(id); g.draw(c, s, S); return c; };
  const sprite = async (c, n, shiny, tx, ty) => { const p = await GSC.monPicture(B, n, shiny); if (p) { const x = c.getContext("2d"); x.imageSmoothingEnabled = false; x.drawImage(p, tx * 8 * S, ty * 8 * S, 56 * S, 56 * S); } };
  const blank = (w, h) => new g.Screen(w, h, null, 0);

  let s = blank(24, 9); s.textbox(0, 0, 7, 22);
  s.text(2, 2, "WELCOME TO"); s.text(2, 4, "24/7 SHINY"); s.text(2, 6, "HUNTING!");
  let c = draw("g_welcome", s); await sprite(c, 216, true, 15, 1);

  s = blank(24, 19); s.textbox(0, 0, 17, 22);
  s.text(2, 2, "RULES");
  ["1 BE KIND. NO HATE.", "2 NO NSFW OR GORE.", "3 NO SPAM OR ADS.", "4 NO ROM LINKS.", "5 RIGHT CHANNEL ONLY.",
   "6 ENGLISH, PLEASE.", "7 FOLLOW DISCORD TOS"].forEach((t, i) => s.text(2, 4 + i * 2, t));
  s.put(22, 17, GSC.CHARS["▼"]);
  draw("g_rules", s);

  s = g.pokegearScreen("radio");
  s.text(2, 9, "  AUTOCRYSTAL FM");
  s.text(1, 14, "v1.3.0 IS OUT!"); s.text(1, 16, "PATCH NOTES BELOW"); s.put(18, 17, GSC.CHARS["▼"]);
  draw("g_radio", s);

  const box = document.getElementById("sprites");
  for (const [n, sh] of [[92, true], [216, true], [225, false], [163, true], [41, true], [129, true], [175, false], [201, false]]) {
    const p = await GSC.monPicture(B, n, sh); if (!p) continue;
    const cv = document.createElement("canvas"); cv.width = 56; cv.height = 56; cv.getContext("2d").drawImage(p, 0, 0); box.appendChild(cv);
  }
})();
</script>
"""

page = ['<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>24/7 Shiny Hunting Server</title><style>%s</style></head><body>" % CSS,
        "<header><h1>24/7 Shiny Hunting - Gen 2 look (mockup 2)</h1><p>Nothing is built yet. Gen 2 pictures only where they help: the welcome heading, the rules, releases.</p></header>",
        '<div class="wrap">', "".join(side),
        '<div class="col">', welcome, readme, shinies, releases, "</div>",
        '<div class="colr">', avatar, "".join(onboard), rules, links_c, faq, clips, daily, "".join(emolist), "</div></div>", JS, "</body></html>"]
open(OUT, "w", encoding="utf-8").write("".join(page))
print("ok", OUT)
