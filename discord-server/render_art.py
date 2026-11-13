# Pictures the server posts, drawn by the overlay's gsc.js (the game's own
# tiles, font, frame and Pokegear cards) at 2x, in Edge:
#   python render_art.py          avatar.png + the layout's "pictures" (welcome.png, rules.png) into art/
# and, from other scripts:
#   render({"name": spec, ...}, outdir)   spec: a text box  {"w","h","box","lines","sprite"? or "sprites"?: [[no, shiny, tileX, tileY]],"arrow"?}
#                                          or a Pokegear card {"card": "radio", "station", "lines": [l1, l2]}
import base64, http.server, json, os, subprocess, threading
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ART = os.path.join(HERE, "art")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

PAGE = """<!doctype html><meta charset="utf-8"><body><script src="/bot/overlay/gsc.js"></script><script>
(async () => {
  const B = "/bot/overlay/gfx/", S = 2, P = %s;
  const g = await GSC.load(B, { frame: 1 });
  for (const [name, p] of Object.entries(P)) {
    let s;
    if (p.card) {
      s = g.pokegearScreen(p.card);
      if (p.card === "radio") {
        const st = (p.station || "").toUpperCase().slice(0, 16), pad = Math.floor((16 - st.length) / 2);
        s.text(2, 9, " ".repeat(pad) + st);
      }
      (p.lines || []).forEach((t, i) => s.text(1, 14 + i * 2, t));
      if (p.arrow) s.put(18, 17, GSC.CHARS["\\u25bc"]);
    } else {
      s = new g.Screen(p.w, p.h, null, 0);
      s.textbox(...p.box);
      for (const [x, y, t] of p.lines) s.text(x, y, t);
      if (p.arrow) s.put(p.arrow[0], p.arrow[1], GSC.CHARS["\\u25bc"]);
    }
    const c = document.createElement("canvas"); g.draw(c, s, S);
    for (const sp of (p.sprites || (p.sprite ? [p.sprite] : []))) {
      const [n, shiny, tx, ty] = sp, pic = await GSC.monPicture(B, n, shiny);
      const x = c.getContext("2d"); x.imageSmoothingEnabled = false;
      if (pic) x.drawImage(pic, tx * 8 * S, ty * 8 * S, 56 * S, 56 * S);
    }
    await fetch("/save/" + name + ".png", { method: "POST", body: c.toDataURL("image/png") });
  }
  await fetch("/save/_done", { method: "POST", body: "x" });
})();
</script>"""


def render(pictures, outdir=ART):
    page = (PAGE % json.dumps(pictures)).encode()
    done = threading.Event()

    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
        def log_message(self, *a): pass
        def do_GET(self):
            if self.path.startswith("/_render.html"):
                self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page))); self.end_headers(); self.wfile.write(page); return
            super().do_GET()
        def do_POST(self):
            name = os.path.basename(self.path)
            body = self.rfile.read(int(self.headers["Content-Length"])).decode()
            if name == "_done": done.set()
            else: open(os.path.join(outdir, name), "wb").write(base64.b64decode(body.split(",", 1)[1]))
            self.send_response(200); self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    prof = os.path.join(os.environ.get("TEMP", HERE), "render_art_edge")
    p = subprocess.Popen([EDGE, "--headless", "--disable-gpu", "--user-data-dir=" + prof, "--virtual-time-budget=10000",
                          "--dump-dom", "http://127.0.0.1:%d/_render.html" % srv.server_port], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = done.wait(60)
    p.kill(); srv.shutdown()
    if not ok: raise SystemExit("Edge didn't finish drawing")
    return [os.path.join(outdir, n + ".png") for n in pictures]


if __name__ == "__main__":
    L = json.load(open(os.path.join(HERE, "server_layout.json"), encoding="utf-8"))
    d = Image.open(os.path.join(ART, "delibird.png")).convert("RGBA")
    d = d.crop(d.getbbox())
    k = max(1, min(340 // d.width, 340 // d.height))
    d = d.resize((d.width * k, d.height * k), Image.NEAREST)
    av = Image.new("RGBA", (512, 512), (248, 248, 240, 255))
    av.alpha_composite(d, ((512 - d.width) // 2, (512 - d.height) // 2 + 10))
    av.convert("RGB").save(os.path.join(ART, "avatar.png"))
    for f in render(L["pictures"]): print(os.path.basename(f), Image.open(f).size)
