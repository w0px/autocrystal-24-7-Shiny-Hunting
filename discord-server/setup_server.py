# Builds the 24/7 Shiny Hunting Discord server from server_layout.json, through
# the setup bot (Developer Portal -> your app -> Bot). Two phases:
#
#   python setup_server.py --dry-run            what it would do, changes nothing
#   python setup_server.py                      phase "hidden": creates the roles, channels,
#                                               emoji, webhooks and posts - every new channel
#                                               hidden from @everyone, so only you see them.
#                                               Nothing server-wide changes yet.
#     --test-pings                              ...and gives YOU Shiny Ping + DV Ping, to test pings
#     --write-settings                          ...and saves the #shinies webhook + ping roles into
#                                               the dev bot's gui_settings.txt
#   python setup_server.py --reveal             shows the new channels and switches on the
#                                               server-wide parts: name, Community, the join
#                                               question, only-@mentions, no pings for @everyone
#
# What it made is remembered in server_state.json (ids, webhook links - keep it
# private) so a re-run fixes instead of duplicating. Existing channels and roles
# with the same names are left alone unless --adopt. The bot token is read from
# --token-file and never printed; neither are webhook links. Nothing is deleted.
import argparse, base64, hashlib, io, json, mimetypes, os, re, sys, time, urllib.error, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://discord.com/api/v10"

P = {name: 1 << bit for name, bit in {
    "CREATE_INSTANT_INVITE": 0, "KICK_MEMBERS": 1, "BAN_MEMBERS": 2, "ADMINISTRATOR": 3, "MANAGE_CHANNELS": 4,
    "MANAGE_GUILD": 5, "ADD_REACTIONS": 6, "VIEW_AUDIT_LOG": 7, "PRIORITY_SPEAKER": 8, "STREAM": 9,
    "VIEW_CHANNEL": 10, "SEND_MESSAGES": 11, "MANAGE_MESSAGES": 13, "EMBED_LINKS": 14, "ATTACH_FILES": 15,
    "READ_MESSAGE_HISTORY": 16, "MENTION_EVERYONE": 17, "USE_EXTERNAL_EMOJIS": 18, "CONNECT": 20, "SPEAK": 21,
    "MUTE_MEMBERS": 22, "DEAFEN_MEMBERS": 23, "MOVE_MEMBERS": 24, "USE_VAD": 25, "CHANGE_NICKNAME": 26,
    "MANAGE_NICKNAMES": 27, "MANAGE_ROLES": 28, "MANAGE_WEBHOOKS": 29, "USE_APPLICATION_COMMANDS": 31,
    "MANAGE_THREADS": 34, "CREATE_PUBLIC_THREADS": 35, "CREATE_PRIVATE_THREADS": 36, "USE_EXTERNAL_STICKERS": 37,
    "SEND_MESSAGES_IN_THREADS": 38, "MODERATE_MEMBERS": 40, "SEND_VOICE_MESSAGES": 46}.items()}
# what a normal member may do (@everyone and Trainer) - not MENTION_EVERYONE:
# members can't ping @everyone or the ping roles
MEMBER = ["VIEW_CHANNEL", "CREATE_INSTANT_INVITE", "CHANGE_NICKNAME", "SEND_MESSAGES", "SEND_MESSAGES_IN_THREADS",
          "CREATE_PUBLIC_THREADS", "EMBED_LINKS", "ATTACH_FILES", "ADD_REACTIONS", "USE_EXTERNAL_EMOJIS",
          "USE_EXTERNAL_STICKERS", "READ_MESSAGE_HISTORY", "USE_APPLICATION_COMMANDS", "CONNECT", "SPEAK", "STREAM",
          "USE_VAD", "SEND_VOICE_MESSAGES"]
NO_POSTING = ["SEND_MESSAGES", "SEND_MESSAGES_IN_THREADS", "CREATE_PUBLIC_THREADS", "CREATE_PRIVATE_THREADS"]
TYPE = {"text": 0, "news": 5, "forum": 15}


def bits(names):
    out = 0
    for n in names:
        out |= bits(MEMBER) if n == "member" else P[n]
    return out


def say(s): print(s, flush=True)


class Api:
    def __init__(self, base, token, dry):
        self.base, self.token, self.dry, self.fake = base.rstrip("/"), token, dry, 0

    def call(self, method, path, body=None, files=None, auth=True, ok404=False):
        if self.dry and method != "GET":
            self.fake += 1
            say("   would %s %s" % (method, re.sub(r"/webhooks/(\d+)/[^/?]+", r"/webhooks/\1/<token>", path)))
            out = dict(body or {}) if isinstance(body, dict) else {}
            out.setdefault("id", "dry%d" % self.fake)
            out.setdefault("token", "dry")
            return out
        headers = {"User-Agent": "DiscordBot (https://github.com, 1.0) shiny-hunting-setup",
                   "X-Audit-Log-Reason": "24-7 Shiny Hunting server setup"}
        if auth: headers["Authorization"] = "Bot " + self.token
        if files:
            data, ctype = multipart(body, files)
            headers["Content-Type"] = ctype
        else:
            data = json.dumps(body).encode() if body is not None else None
            headers["Content-Type"] = "application/json"
        for _ in range(10):
            req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                raw = e.read().decode("utf-8", "replace")
                if e.code == 429:
                    try: wait = float(json.loads(raw).get("retry_after", 1))
                    except ValueError: wait = 1
                    time.sleep(min(wait, 60) + 0.2)
                    continue
                if e.code == 404 and ok404: return None
                safe = re.sub(r"/webhooks/(\d+)/[^/?]+", r"/webhooks/\1/<token>", path)
                raise ApiError("Discord said %d to %s %s: %s" % (e.code, method, safe, raw[:400]), e.code)
        raise ApiError("Discord kept rate limiting %s" % method, 429)

    def get(self, p, ok404=False): return self.call("GET", p, ok404=ok404)
    def post(self, p, b, files=None): return self.call("POST", p, b, files)
    def patch(self, p, b, files=None): return self.call("PATCH", p, b, files)
    def put(self, p, b): return self.call("PUT", p, b)


class ApiError(Exception):
    def __init__(self, msg, code): super().__init__(msg); self.code = code


def multipart(payload, files):
    b = uuid.uuid4().hex
    out = io.BytesIO()
    def part(headers, data):
        out.write(("--%s\r\n" % b).encode())
        for h in headers: out.write((h + "\r\n").encode())
        out.write(b"\r\n"); out.write(data); out.write(b"\r\n")
    part(['Content-Disposition: form-data; name="payload_json"', "Content-Type: application/json"], json.dumps(payload).encode())
    for i, (name, data) in enumerate(files):
        part(['Content-Disposition: form-data; name="files[%d]"; filename="%s"' % (i, name),
              "Content-Type: " + (mimetypes.guess_type(name)[0] or "application/octet-stream")], data)
    out.write(("--%s--\r\n" % b).encode())
    return out.getvalue(), "multipart/form-data; boundary=" + b


def data_uri(path):
    raw = open(path, "rb").read()
    return "data:%s;base64,%s" % (mimetypes.guess_type(path)[0] or "image/png", base64.b64encode(raw).decode())


def emoji_bytes(path, limit=256 * 1024):
    """The file as Discord takes it: as is when small enough, else made smaller
    (animated GIFs keep every frame and their timing)."""
    raw = open(path, "rb").read()
    if len(raw) <= limit: return raw, os.path.splitext(path)[1].lower().replace(".jpeg", ".jpg")
    from PIL import Image, ImageSequence
    im = Image.open(path)
    animated = getattr(im, "n_frames", 1) > 1
    scale = 1.0
    while True:
        scale *= 0.8
        w, h = max(1, int(im.width * scale)), max(1, int(im.height * scale))
        buf = io.BytesIO()
        if animated:
            frames, durs = [], []
            for f in ImageSequence.Iterator(im):
                frames.append(f.convert("RGBA").resize((w, h), Image.LANCZOS)); durs.append(f.info.get("duration", 60))
            frames[0].save(buf, "GIF", save_all=True, append_images=frames[1:], duration=durs, loop=0, disposal=2)
            ext = ".gif"
        else:
            im.convert("RGBA").resize((w, h), Image.LANCZOS).save(buf, "PNG", optimize=True)
            ext = ".png"
        if buf.tell() <= limit or w < 32: return buf.getvalue(), ext


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--reveal", action="store_true")
    ap.add_argument("--test-pings", action="store_true")
    ap.add_argument("--write-settings", action="store_true")
    ap.add_argument("--adopt", action="store_true", help="use existing channels/roles with the layout's names (a blank server)")
    ap.add_argument("--guild", help="server ID, when the bot is in more than one server")
    ap.add_argument("--layout", default=os.path.join(HERE, "server_layout.json"))
    ap.add_argument("--token-file", default=os.path.join(HERE, "bot_token.txt"))
    ap.add_argument("--state-file", default=os.path.join(HERE, "server_state.json"))
    ap.add_argument("--webhooks-file", default=os.path.join(HERE, "webhooks.txt"))
    ap.add_argument("--settings-file", help="(tests) instead of the layout's settings_file")
    ap.add_argument("--api", default=API, help="(tests) a stand-in Discord")
    a = ap.parse_args()

    L = json.load(open(a.layout, encoding="utf-8"))
    rel = lambda p: os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(a.layout)), p))
    try:
        token = open(a.token_file, encoding="utf-8").read().strip()
    except OSError:
        raise SystemExit("No bot token: put it in %s (one line)." % a.token_file)
    if token.lower().startswith("bot "): token = token[4:].strip()
    api = Api(a.api, token, a.dry_run)
    st = json.load(open(a.state_file, encoding="utf-8")) if os.path.exists(a.state_file) else {}
    for k in ("roles", "categories", "channels", "emoji", "webhooks", "posts", "done"): st.setdefault(k, {})
    def save_state():
        if not a.dry_run:
            json.dump(st, open(a.state_file, "w", encoding="utf-8"), indent=1)
    # (once revealed, a plain re-run keeps everything visible - only --reveal
    # touches the server-wide settings again)
    hidden = not (a.reveal or st["done"].get("revealed"))
    say("%sPhase: %s" % ("DRY RUN - nothing is changed. " if a.dry_run else "", "hidden (only you see the new channels)" if hidden else ("REVEAL" if a.reveal else "public (already revealed)")))

    me = api.get("/users/@me")
    guilds = api.get("/users/@me/guilds")
    if a.guild: guilds = [g for g in guilds if g["id"] == a.guild]
    if len(guilds) != 1:
        raise SystemExit("The bot is in %d servers%s - add it to the server, or pass --guild <server ID>."
                         % (len(guilds), "" if not guilds else " (" + ", ".join(g["name"] for g in guilds) + ")"))
    g = api.get("/guilds/%s" % guilds[0]["id"])
    gid = g["id"]
    if st.get("guild") and st["guild"] != gid:
        raise SystemExit("server_state.json belongs to another server (%s). Move it away to start fresh." % st["guild"])
    st["guild"] = gid
    community = "COMMUNITY" in (g.get("features") or [])
    say("Server: %s · bot: %s" % (g["name"], me["username"]))

    # ---- the bot's name and picture ----------------------------------------
    b = L.get("bot") or {}
    avatar_path = rel(b["avatar"]) if b.get("avatar") else None
    av_hash = hashlib.sha1(open(avatar_path, "rb").read()).hexdigest() if avatar_path and os.path.exists(avatar_path) else None
    want = {}
    if b.get("name") and me["username"] != b["name"]: want["username"] = b["name"]
    if av_hash and st["done"].get("avatar") != av_hash: want["avatar"] = data_uri(avatar_path)
    if want:
        say("Bot: %s" % " + ".join(("name " + b["name"]) if k == "username" else "picture" for k in want))
        try:
            api.patch("/users/@me", want)
            if "avatar" in want: st["done"]["avatar"] = av_hash
        except ApiError as e:
            say(" (couldn't change the bot: %s - set it in the Developer Portal instead)" % str(e)[:160])

    # ---- roles -------------------------------------------------------------
    say("Roles")
    roles = api.get("/guilds/%s/roles" % gid)
    by_id = {r["id"]: r for r in roles}
    by_name = {r["name"]: r for r in roles}
    R = {}
    for spec in L["roles"]:
        want = {"name": spec["name"], "color": int(spec["color"].lstrip("#"), 16), "hoist": spec["hoist"],
                "mentionable": False, "permissions": str(bits(spec["perms"]))}
        have = by_id.get(st["roles"].get(spec["name"], "")) or (by_name.get(spec["name"]) if a.adopt else None)
        if have is None:
            say(" + %s" % spec["name"])
            R[spec["name"]] = api.post("/guilds/%s/roles" % gid, want)["id"]
        else:
            R[spec["name"]] = have["id"]
            if any(str(have.get(k)) != str(v) for k, v in want.items()):
                say(" ~ %s" % spec["name"]); api.patch("/guilds/%s/roles/%s" % (gid, have["id"]), want)
            else:
                say(" = %s" % spec["name"])
        st["roles"][spec["name"]] = R[spec["name"]]
    save_state()
    # the layout's first role on top, all just under the setup bot's own role
    roles = api.get("/guilds/%s/roles" % gid)     # (new roles moved the bot's own role up)
    bot_top = max([r["position"] for r in roles if r.get("managed") and r.get("tags", {}).get("bot_id") == me["id"]] or [0])
    try:
        api.patch("/guilds/%s/roles" % gid, [{"id": R[s["name"]], "position": max(1, bot_top - 1 - i)} for i, s in enumerate(L["roles"])])
    except ApiError as e:
        say(" (couldn't sort the roles: %s)" % str(e)[:120])

    # ---- channels ----------------------------------------------------------
    say("Channels")
    chans = api.get("/guilds/%s/channels" % gid)
    cid_of = {c["id"]: c for c in chans}

    def find(kind_types, name, store):
        c = cid_of.get(st[store].get(name, ""))
        if c is None and a.adopt:
            c = next((x for x in chans if x["name"].lower() == name.lower() and x["type"] in kind_types), None)
        return c

    def overwrites(spec, hide):
        ev_allow, ev_deny, ow = [], [], []
        acc = spec.get("access", "chat")
        if acc in ("readonly", "staffwrite"):
            ev_allow = ["VIEW_CHANNEL", "READ_MESSAGE_HISTORY", "ADD_REACTIONS"]
            if spec.get("pings"): ev_allow.append("MENTION_EVERYONE")   # (webhooks ping with @everyone's rights)
            ev_deny = list(NO_POSTING)
            if spec.get("staff_post") or acc == "staffwrite":
                ow.append({"id": R["Moderator"], "type": 0, "allow": str(bits(["SEND_MESSAGES", "SEND_MESSAGES_IN_THREADS", "CREATE_PUBLIC_THREADS"])), "deny": "0"})
        elif acc == "staff":
            ev_deny = ["VIEW_CHANNEL"]
            ow.append({"id": R["Moderator"], "type": 0, "allow": str(bits(["VIEW_CHANNEL", "SEND_MESSAGES", "READ_MESSAGE_HISTORY"])), "deny": "0"})
        if hide:
            ev_allow = [x for x in ev_allow if x != "VIEW_CHANNEL"]
            if "VIEW_CHANNEL" not in ev_deny: ev_deny.append("VIEW_CHANNEL")
        if ev_allow or ev_deny:
            ow.insert(0, {"id": gid, "type": 0, "allow": str(bits(ev_allow)), "deny": str(bits(ev_deny))})
        return ow

    def same_ow(have, want):
        norm = lambda l: sorted((o["id"], int(o["type"]), str(o["allow"]), str(o["deny"])) for o in l)
        return norm(have or []) == norm(want)

    C, order, later = {}, [], []
    top = max([c.get("position", 0) for c in chans if c["type"] == 4] or [0]) + 1
    for ci, cat in enumerate(L["categories"]):
        want_ow = overwrites({"access": "chat"}, hidden)
        c = find([4], cat["name"], "categories")
        if c is None:
            say(" + category %s" % cat["name"])
            c = api.post("/guilds/%s/channels" % gid, {"name": cat["name"], "type": 4, "permission_overwrites": want_ow})
            chans.append(c)
        elif not same_ow(c.get("permission_overwrites"), want_ow) or c["name"] != cat["name"]:
            say(" ~ category %s" % cat["name"])
            api.patch("/channels/%s" % c["id"], {"name": cat["name"], "permission_overwrites": want_ow})
        st["categories"][cat["name"]] = c["id"]
        save_state()
        order.append({"id": c["id"], "position": top + ci})
        for pi, spec in enumerate(cat["channels"]):
            kind = spec["kind"]
            t = TYPE[kind]
            if kind == "news" and not community: t = 0      # becomes an announcement channel with Community (reveal)
            want = {"name": spec["name"], "type": t, "parent_id": c["id"], "permission_overwrites": overwrites(spec, hidden)}
            if spec.get("topic"): want["topic"] = spec["topic"]
            if kind == "forum":
                want["available_tags"] = [{"name": n} for n in spec.get("tags", [])]
                want["default_sort_order"] = 1           # newest post first; the README is posted last-section-first
            ch = find([0, 5, 15], spec["name"], "channels")
            if ch is None:
                say(" + #%s%s" % (spec["name"], " (forum)" if kind == "forum" else ""))
                try:
                    ch = api.post("/guilds/%s/channels" % gid, want)
                except ApiError as e:
                    if kind != "forum": raise
                    say("   (a forum isn't allowed yet: %s - it's made at the reveal)" % str(e)[:100])
                    continue
                chans.append(ch)
            else:
                fix = {k: v for k, v in want.items() if k not in ("type", "permission_overwrites", "available_tags") and ch.get(k) != v}
                if not same_ow(ch.get("permission_overwrites"), want["permission_overwrites"]):
                    fix["permission_overwrites"] = want["permission_overwrites"]
                if kind == "forum":
                    have_tags = {x["name"] for x in ch.get("available_tags", [])}
                    if have_tags != set(spec.get("tags", [])):
                        fix["available_tags"] = [x for x in ch.get("available_tags", []) if x["name"] in spec.get("tags", [])] + \
                                                [{"name": n} for n in spec.get("tags", []) if n not in have_tags]
                say(" %s #%s" % ("~" if fix else "=", spec["name"]))
                if fix:
                    res = api.patch("/channels/%s" % ch["id"], fix)
                    if res and not a.dry_run: ch = res
            C[spec["name"]] = ch["id"]
            st["channels"][spec["name"]] = ch["id"]
            save_state()
            # (positions only: Discord refuses more than one parent change per
            # sort - every channel already sits in its category from above)
            if ch.get("parent_id") not in (None, c["id"]):
                api.patch("/channels/%s" % ch["id"], {"parent_id": c["id"]})
            order.append({"id": ch["id"], "position": pi})
            if kind == "news" and ch.get("type") != 5: later.append(spec["name"])
    try:
        api.patch("/guilds/%s/channels" % gid, order)
    except ApiError as e:
        say(" (couldn't sort the channels: %s)" % str(e)[:120])

    # ---- emoji -------------------------------------------------------------
    say("Emoji")
    have_em = {e_["id"]: e_ for e_ in (api.get("/guilds/%s/emojis" % gid) or [])}
    E = {}
    for spec in L.get("emoji", []):
        path = rel(spec["file"])
        if not os.path.exists(path) and spec.get("fallback"): path = rel(spec["fallback"])
        if not os.path.exists(path):
            say(" ! %s: no file %s" % (spec["name"], spec["file"])); continue
        raw_hash = hashlib.sha1(open(path, "rb").read()).hexdigest()
        old = st["emoji"].get(spec["name"]) or {}
        cur = have_em.get(old.get("id", ""))
        if cur and old.get("hash") == raw_hash:
            say(" = :%s:" % spec["name"])
        else:
            if cur:
                say(" ~ :%s: (new picture)" % spec["name"])
                api.call("DELETE", "/guilds/%s/emojis/%s" % (gid, cur["id"]))
            else:
                say(" + :%s:" % spec["name"])
            data, ext = emoji_bytes(path)
            mime = {".gif": "image/gif", ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp"}.get(ext, "image/png")
            cur = api.post("/guilds/%s/emojis" % gid, {"name": spec["name"], "image": "data:%s;base64,%s" % (mime, base64.b64encode(data).decode()), "roles": []})
            st["emoji"][spec["name"]] = {"id": cur["id"], "hash": raw_hash, "animated": bool(cur.get("animated", ext == ".gif"))}
            save_state()
        E[spec["name"]] = st["emoji"][spec["name"]]
    def emoji_text(name):
        x = E.get(name)
        return "<%s:%s:%s>" % ("a" if x.get("animated") else "", name, x["id"]) if x else ""

    # ---- webhooks ----------------------------------------------------------
    say("Webhooks")
    hooks = {}
    for cat in L["categories"]:
        for spec in cat["channels"]:
            if not spec.get("webhook") or spec["name"] not in C: continue
            cid = C[spec["name"]]
            w = st["webhooks"].get(spec["name"])
            if w and not str(cid).startswith("dry"):
                if api.call("GET", "/webhooks/%s/%s" % (w["id"], w["token"]), auth=False, ok404=True) is None: w = None
            want_name = b.get("name") or "autocrystal"
            if w is None:
                say(" + %s in #%s" % (want_name, spec["name"]))
                body = {"name": want_name}
                if avatar_path and os.path.exists(avatar_path): body["avatar"] = data_uri(avatar_path)
                x = api.post("/channels/%s/webhooks" % cid, body)
                w = {"id": x["id"], "token": x.get("token"), "avatar": av_hash}
            elif w.get("avatar") != av_hash and avatar_path:
                say(" ~ #%s webhook picture" % spec["name"])
                api.patch("/webhooks/%s" % w["id"], {"name": want_name, "avatar": data_uri(avatar_path)})
                w["avatar"] = av_hash
            else:
                say(" = #%s" % spec["name"])
            st["webhooks"][spec["name"]] = w
            hooks[spec["name"]] = "https://discord.com/api/webhooks/%s/%s" % (w["id"], w["token"])
            save_state()

    # ---- welcome / rules posts ---------------------------------------------
    say("Posts")
    for cat in L["categories"]:
        for spec in cat["channels"]:
            if not spec.get("post") or spec["name"] not in C: continue
            m = L["messages"][spec["post"]]
            text = "\n".join(m["text"])
            text = re.sub(r"\{(\w+)\}", lambda x: emoji_text(x.group(1)), text)
            text = re.sub(r"<#([\w-]+)>", lambda x: "<#%s>" % C[x.group(1)] if x.group(1) in C else "#" + x.group(1), text)
            img = rel(m["image"]) if m.get("image") else None
            files = [(os.path.basename(img), open(img, "rb").read())] if img and os.path.exists(img) else []
            body = {"content": text[:2000], "allowed_mentions": {"parse": []}}
            if m.get("embed"):      # (a card holds 4,096 letters - long link lists)
                body = {"content": "", "embeds": [{"color": 0x8BC34A, "description": text[:4096]}], "allowed_mentions": {"parse": []}}
            if files: body["attachments"] = [{"id": 0, "filename": files[0][0]}]
            sig = hashlib.sha1((text + "".join(hashlib.sha1(f[1]).hexdigest() for f in files)).encode()).hexdigest()
            cid = C[spec["name"]]
            old = st["posts"].get(spec["name"]) or {}
            if old.get("id") and old.get("sig") == sig:
                say(" = #%s" % spec["name"]); continue
            if old.get("id") and api.get("/channels/%s/messages/%s" % (cid, old["id"]), ok404=True):
                say(" ~ #%s" % spec["name"]); api.patch("/channels/%s/messages/%s" % (cid, old["id"]), body, files)
                mid = old["id"]
            else:
                say(" + #%s" % spec["name"]); mid = api.post("/channels/%s/messages" % cid, body, files)["id"]
            st["posts"][spec["name"]] = {"id": mid, "sig": sig}
            save_state()

    # ---- test pings: only you get the ping roles --------------------------
    if a.test_pings:
        say("Test pings: Shiny Ping + DV Ping for the server owner")
        for rn in ("Shiny Ping", "DV Ping"):
            api.put("/guilds/%s/members/%s/roles/%s" % (gid, g["owner_id"], R[rn]), None)

    # ---- reveal: the server-wide part --------------------------------------
    if a.reveal:
        say("Server settings")
        S = L["server"]
        api.patch("/guilds/%s/roles/%s" % (gid, gid), {"permissions": str(bits(["member"]))})
        say(" @everyone: normal member rights, no @everyone / role pings")
        gp = {"name": S["name"], "default_message_notifications": 1 if S["default_notifications"] == "only_mentions" else 0,
              "verification_level": S["verification_level"], "explicit_content_filter": S["explicit_content_filter"],
              "system_channel_id": C.get(S["system_channel"]), "rules_channel_id": C[S["rules_channel"]],
              "public_updates_channel_id": C[S["updates_channel"]], "safety_alerts_channel_id": C[S["safety_channel"]]}
        if "system_channel_flags" in S: gp["system_channel_flags"] = S["system_channel_flags"]   # 4 + 8: no setup tips, no "wave" sticker reply
        if S.get("community") and not community:
            say(" + Community mode"); gp["features"] = list(g.get("features") or []) + ["COMMUNITY"]
        api.patch("/guilds/%s" % gid, gp)
        for name in later:
            say(" #%s -> announcement channel" % name); api.patch("/channels/%s" % C[name], {"type": 5})
        say("Join question")
        ob = L["onboarding"]
        try: old = api.get("/guilds/%s/onboarding" % gid) or {}
        except ApiError: old = {}
        old_p = {p["title"]: p for p in old.get("prompts", [])}
        seq = [0]
        def snowflake():
            seq[0] += 1
            return str(((int(time.time() * 1000) - 1420070400000) << 22) | (seq[0] & 0xFFF))
        prompts = []
        for q in ob["questions"]:
            op = old_p.get(q["title"], {})
            old_o = {o["title"]: o for o in op.get("options", [])}
            opts = []
            for o in q["options"]:
                x = {"id": old_o.get(o["title"], {}).get("id") or snowflake(), "title": o["title"], "description": o["description"],
                     "role_ids": [R[r] for r in o["roles"]], "channel_ids": []}
                em = E.get(o.get("emoji", ""))
                if em: x.update(emoji_id=em["id"], emoji_name=o["emoji"], emoji_animated=em.get("animated", False))
                elif o.get("emoji"): x["emoji_name"] = o["emoji"]
                opts.append(x)
            prompts.append({"id": op.get("id") or snowflake(), "type": 0, "title": q["title"], "single_select": not q["multiple"],
                            "required": q["required"], "in_onboarding": True, "options": opts})
        api.put("/guilds/%s/onboarding" % gid, {"prompts": prompts, "default_channel_ids": [C[n] for n in ob["default_channels"] if n in C],
                                                "enabled": True, "mode": 0})
        say(" on")
        st["done"]["revealed"] = True

    save_state()
    if a.dry_run:
        say("Done (dry run)."); return
    with open(a.webhooks_file, "w", encoding="utf-8") as f:
        for name, url in hooks.items(): f.write("%s=%s\n" % (name, url))
    say("Webhook links saved to %s (not shown)." % a.webhooks_file)
    if a.write_settings:
        path = a.settings_file or os.path.join(HERE, L["settings_file"])   # (the layout's is relative to this folder)
        vals = {}
        for key, src in L["settings_keys"].items():
            kind, name = src.split(":", 1)
            v = hooks.get(name) if kind == "webhook" else ("&" + R[name] if name in R else None)
            if v: vals[key] = v
        lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
        seen = set()
        for i, line in enumerate(lines):
            k = line.split("=", 1)[0]
            if k in vals: lines[i] = "%s=%s" % (k, vals[k]); seen.add(k)
        lines += ["%s=%s" % (k, v) for k, v in sorted(vals.items()) if k not in seen]
        with open(path, "w", encoding="utf-8", newline="\n") as f: f.write("\n".join(lines) + "\n")
        say("Dev bot settings updated: %s." % ", ".join(sorted(vals)))
    say("Done.")


if __name__ == "__main__":
    try:
        main()
    except ApiError as e:
        raise SystemExit(str(e))
