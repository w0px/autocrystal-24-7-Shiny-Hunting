// gsc.js - draws Gold/Silver/Crystal screens the way the Game Boy Color does:
// 8x8 tiles from the game's own graphics, a 20x18 tilemap, and the
// palettes the game loads for that screen. Everything comes from the
// pokecrystal disassembly's files in gfx/ (graphics, palettes, tilemaps).
//
//   const gsc = await GSC.load("gfx/");
//   const screen = gsc.pokegearScreen("radio");   // tilemap + palette per tile
//   screen.text(1, 14, "Hello!");                  // the game's font
//   gsc.draw(canvas, screen, 4);                   // 4x pixels

const GSC = (() => {
  // charmap.asm: the game's letters as tile numbers (the font sits at $80).
  const CHARS = {};
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").forEach((c, i) => CHARS[c] = 0x80 + i);
  "abcdefghijklmnopqrstuvwxyz".split("").forEach((c, i) => CHARS[c] = 0xa0 + i);
  "0123456789".split("").forEach((c, i) => CHARS[c] = 0xf6 + i);
  Object.assign(CHARS, {
    " ": 0x7f, "(": 0x9a, ")": 0x9b, ":": 0x9c, ";": 0x9d, "[": 0x9e, "]": 0x9f,
    "Ä": 0xc0, "Ö": 0xc1, "Ü": 0xc2, "ä": 0xc3, "ö": 0xc4, "ü": 0xc5,
    "'": 0xe0, "’": 0xe0, "-": 0xe3, "–": 0xe3, "?": 0xe6, "!": 0xe7, ".": 0xe8, "&": 0xe9,
    "é": 0xea, "→": 0xeb, "▷": 0xec, "▶": 0xed, "▼": 0xee, "♂": 0xef, "¥": 0xf0,
    "×": 0xf1, "/": 0xf3, ",": 0xf4, "♀": 0xf5,
    "┌": 0x79, "─": 0x7a, "┐": 0x7b, "│": 0x7c, "└": 0x7d, "┘": 0x7e,
    "%": 0x60,
  });
  // A few the font doesn't have, spelled the game's way.
  const FALLBACK = { "É": "E", "è": "e", "ê": "e", "á": "a", "à": "a", "ó": "o", "ú": "u", "\"": "'", "…": "...", "#": "No." };

  // The one letter drawn here, not taken from the game: none of its fonts
  // has a %. Drawn the way its digits are - two-pixel strokes, seven rows
  // high, the bottom row clear - and put in a tile the Pokegear screens
  // leave free ($60).
  const PERCENT = [
    ".##...#.",
    ".##..##.",
    "....##..",
    "...##...",
    "..##....",
    ".##..##.",
    ".#...##.",
    "........",
  ];
  const PERCENT_TILE = Uint8Array.from(PERCENT.join("").split("").map(c => c === "#" ? 3 : 0));

  // gfx/pokegear/town_map_palette_map.asm: the palette of tiles $00-$5f on
  // Pokegear screens, two tiles per byte (TownMapPals, low nybble first).
  const POKEGEAR_PAL_MAP = [
    // town_map.png
    "1 1 1 2 2 2 0 0", "1 1 3 1 4 5 4 5", "1 1 1 2 2 2 0 0",
    "1 1 0 1 1 0 0 0", "1 1 1 2 2 2 0 0", "0 0 0 0 0 0 0 0",
    // pokegear.png
    "0 0 0 0 4 4 4 0", "0 0 0 0 0 0 0 0", "3 3 3 3 3 3 3 3",
    "3 3 3 3 3 3 3 0", "3 3 3 3 3 3 3 3", "0 0 0 0 0 0 0 0",
  ].join(" ").split(" ").map(Number);

  const SHADE = gray => gray > 200 ? 0 : gray > 127 ? 1 : gray > 42 ? 2 : 3;

  async function image(url) {
    // onload, not img.decode(): decode() can stall in a page that isn't
    // on screen (a background tab, the options page's frames).
    const img = new Image();
    await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = reject; img.src = url; });
    const c = document.createElement("canvas");
    c.width = img.width; c.height = img.height;
    const ctx = c.getContext("2d");
    ctx.drawImage(img, 0, 0);
    return ctx.getImageData(0, 0, img.width, img.height);
  }

  // A sheet's 8x8 tiles, each 64 shades 0 (white) .. 3 (black).
  async function tiles(url) {
    const data = await image(url);
    const out = [];
    for (let ty = 0; ty < data.height / 8; ty++) {
      for (let tx = 0; tx < data.width / 8; tx++) {
        const t = new Uint8Array(64);
        for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
          const i = ((ty * 8 + y) * data.width + tx * 8 + x) * 4;
          t[y * 8 + x] = data.data[i + 3] < 128 ? 0 : SHADE(data.data[i]);
        }
        out.push(t);
      }
    }
    return out;
  }

  // A .pal file: "RGB r, g, b" lines (0-31 each), four to a palette.
  async function palettes(url) {
    const text = await (await fetch(url)).text();
    const colors = [...text.matchAll(/RGB\s+(\d+),\s*(\d+),\s*(\d+)/g)]
      .map(m => [1, 2, 3].map(i => { const v = Number(m[i]); return (v << 3) | (v >> 2); }));
    const out = [];
    for (let i = 0; i < colors.length; i += 4) out.push(colors.slice(i, i + 4));
    return out;
  }

  // Pokegear_LoadTilemapRLE: pairs of (tile, count), ending with $ff.
  async function rle(url) {
    const bytes = new Uint8Array(await (await fetch(url)).arrayBuffer());
    const map = [];
    for (let i = 0; i + 1 < bytes.length && bytes[i] !== 0xff; i += 2) {
      for (let n = 0; n < bytes[i + 1]; n++) map.push(bytes[i]);
    }
    return map;
  }

  class Screen {
    constructor(width, height, fill, palette) {
      this.width = width; this.height = height;
      this.tile = new Array(width * height).fill(fill);
      this.pal = new Array(width * height).fill(palette || 0);
    }
    put(x, y, tile, pal) {
      if (x < 0 || y < 0 || x >= this.width || y >= this.height) return;
      this.tile[y * this.width + x] = tile;
      if (pal !== undefined) this.pal[y * this.width + x] = pal;
    }
    // The game's text: letters it has, others swapped for the nearest.
    text(x, y, s, pal) {
      let cx = x;
      for (let ch of s) {
        if (ch === "\n") { y++; cx = x; continue; }
        if (!(ch in CHARS)) ch = FALLBACK[ch] !== undefined ? FALLBACK[ch] : "?";
        for (const c of ch) this.put(cx++, y, CHARS[c] !== undefined ? CHARS[c] : CHARS["?"], pal);
      }
      return cx;
    }
    // The Pokegear's own window frame (the radio and phone cards' grey
    // border, town_map.png tiles $06/$07/$16/$17/$26/$27), w x h tiles
    // including the frame, the inside blank. A title sits in the top edge.
    panel(x, y, w, h, title) {
      this.put(x, y, 0x06, 0); this.put(x + w - 1, y, 0x17, 0);
      this.put(x, y + h - 1, 0x26, 0); this.put(x + w - 1, y + h - 1, 0x27, 0);
      for (let i = 1; i < w - 1; i++) { this.put(x + i, y, 0x07, 0); this.put(x + i, y + h - 1, 0x07, 0); }
      for (let j = 1; j < h - 1; j++) {
        this.put(x, y + j, 0x16, 0); this.put(x + w - 1, y + j, 0x16, 0);
        for (let i = 1; i < w - 1; i++) this.put(x + i, y + j, 0x7f, 0);
      }
      if (title) this.text(x + 2, y, " " + title + " ", 0);
    }
    // Home's Textbox: a frame w letters wide, h lines high, inside. base:
    // the frame's first tile ($79, or $61 for a second frame - load's
    // opts.boxFrame).
    textbox(x, y, h, w, pal, base = 0x79) {
      const b = base - 0x79;
      this.put(x, y, 0x79 + b, pal); this.put(x + w + 1, y, 0x7b + b, pal);
      this.put(x, y + h + 1, 0x7d + b, pal); this.put(x + w + 1, y + h + 1, 0x7e + b, pal);
      for (let i = 1; i <= w; i++) { this.put(x + i, y, 0x7a + b, pal); this.put(x + i, y + h + 1, 0x7a + b, pal); }
      for (let j = 1; j <= h; j++) {
        this.put(x, y + j, 0x7c + b, pal); this.put(x + w + 1, y + j, 0x7c + b, pal);
        for (let i = 1; i <= w; i++) this.put(x + i, y + j, 0x7f, pal);
      }
    }
  }

  async function load(base, opts = {}) {
    const frame = opts.frame || 1;
    const [townMap, gear, font, frameTiles, boyPals, girlPals, clock, phone, radio] = await Promise.all([
      tiles(base + "town_map.png"), tiles(base + "pokegear.png"), tiles(base + "font.png"),
      tiles(base + "frame" + frame + ".png"),
      palettes(base + "pokegear.pal"), palettes(base + "pokegear_f.pal"),
      rle(base + "clock.tilemap.rle"), rle(base + "phone.tilemap.rle"), rle(base + "radio.tilemap.rle"),
    ]);
    // VRAM as Pokegear_LoadGFX leaves it: the town map at $00, the
    // Pokegear's own tiles at $30, the frame at $79 (LoadFrame), the font at $80.
    const vram = new Array(256).fill(null);
    townMap.forEach((t, i) => vram[i] = t);
    gear.forEach((t, i) => vram[0x30 + i] = t);
    frameTiles.forEach((t, i) => vram[0x79 + i] = t);
    vram[0x7f] = new Uint8Array(64);
    vram[0x60] = PERCENT_TILE;
    font.forEach((t, i) => vram[0x80 + i] = t);
    // A second text frame (one of the game's 9 frame styles) at $61-$66,
    // tiles the Pokegear leaves free: textbox(..., 0x61) draws with it.
    if (opts.boxFrame) (await tiles(base + "frame" + opts.boxFrame + ".png")).forEach((t, i) => { if (i < 6) vram[0x61 + i] = t; });
    const maps = { clock, phone, radio };

    return {
      vram,
      palettes: opts.girl ? girlPals : boyPals,
      Screen,

      // A Pokegear card as InitPokegearTilemap draws it: the card's own
      // tilemap, its text box, the card icons in the top left.
      pokegearScreen(card, icons = { map: true, phone: true, radio: true }) {
        const s = new Screen(20, 18, 0x4f);
        maps[card].forEach((t, i) => s.tile[i] = t);
        if (card === "clock") s.text(12, 1, " SWITCH▶");
        s.textbox(0, 12, 4, 18);
        // Pokegear_FinishTilemap: the top-left icons.
        for (let x = 0; x < 8; x++) { s.put(x, 0, 0x4f); s.put(x, 1, 0x4f); }
        const icon = (x, t) => { s.put(x, 0, t); s.put(x + 1, 0, t + 1); s.put(x, 1, t + 0x10); s.put(x + 1, 1, t + 0x11); };
        if (icons.map) icon(2, 0x40);
        if (icons.phone) icon(4, 0x44);
        if (icons.radio) icon(6, 0x42);
        icon(0, 0x46);
        if (card === "phone") { s.put(17, 1, 0x3c); s.put(18, 1, 0x3d); s.put(17, 2, 0x3e); s.put(18, 2, 0x3f); }
        // TownMapPals: tiles below $60 by the palette map, the rest palette 0.
        s.pal = s.tile.map(t => t < 0x60 ? POKEGEAR_PAL_MAP[t] : 0);
        return s;
      },

      // A screen in Game Boy pixels (1x). Tiles set to null stay clear;
      // paperAlpha (0-255) lets the lightest colour show what's behind.
      render(screen, paperAlpha = 255) {
        const c = document.createElement("canvas");
        c.width = screen.width * 8; c.height = screen.height * 8;
        const ctx = c.getContext("2d");
        const img = ctx.createImageData(c.width, c.height);
        for (let ty = 0; ty < screen.height; ty++) for (let tx = 0; tx < screen.width; tx++) {
          const id = screen.tile[ty * screen.width + tx];
          if (id === null) continue;
          const t = vram[id] || vram[0x7f];
          const pal = this.palettes[screen.pal[ty * screen.width + tx]] || this.palettes[0];
          for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
            const shade = t[y * 8 + x];
            const col = pal[shade];
            const i = ((ty * 8 + y) * c.width + tx * 8 + x) * 4;
            img.data[i] = col[0]; img.data[i + 1] = col[1]; img.data[i + 2] = col[2];
            img.data[i + 3] = shade === 0 ? paperAlpha : 255;
          }
        }
        ctx.putImageData(img, 0, 0);
        return c;
      },

      // Draws a screen at `scale` pixels per Game Boy pixel.
      draw(canvas, screen, scale = 1) {
        canvas.width = screen.width * 8 * scale;
        canvas.height = screen.height * 8 * scale;
        const ctx = canvas.getContext("2d");
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(this.render(screen), 0, 0, canvas.width, canvas.height);
      },
    };
  }

  // A Pokemon's front picture, every frame of it: gfx/pokemon/<name>/front.png
  // (copied as gfx/monNNN.png) is the picture with each animation frame
  // stacked below it, all the same square size. White made clear. Shiny:
  // its two middle colours swapped for gfx/monNNN.pal (the game's
  // shiny.pal) - the same two the game changes. Pictures smaller than 56x56
  // sit centred at the bottom of a 56x56 square, as in battle. A list of
  // canvases, frame 0 first; cached per species/shininess.
  const framesCache = new Map();
  function monFrames(base, species, shiny) {
    const key = species + (shiny ? "s" : "n");
    if (!framesCache.has(key)) framesCache.set(key, (async () => {
      const tag = String(species).padStart(3, "0");
      const data = await image(base + "mon" + tag + ".png");
      const size = data.width, count = Math.max(1, Math.floor(data.height / size));
      let swap = null;
      if (shiny) {
        const pal = await (await fetch(base + "mon" + tag + ".pal")).text();
        swap = [...pal.matchAll(/RGB\s+(\d+),\s*(\d+),\s*(\d+)/g)]
          .map(m => [1, 2, 3].map(i => { const v = Number(m[i]); return (v << 3) | (v >> 2); }));
      }
      // The picture's colours, lightest first: white, light, dark, black.
      const colors = new Map();
      for (let i = 0; i < data.data.length; i += 4) {
        const k = (data.data[i] << 16) | (data.data[i + 1] << 8) | data.data[i + 2];
        colors.set(k, data.data[i] * 3 + data.data[i + 1] * 6 + data.data[i + 2]);
      }
      const order = [...colors.keys()].sort((a, b) => colors.get(b) - colors.get(a));
      const frames = [];
      const isWhite = s => order.indexOf((data.data[s] << 16) | (data.data[s + 1] << 8) | data.data[s + 2]) === 0 &&
        data.data[s] >= 230 && data.data[s + 1] >= 230 && data.data[s + 2] >= 230;
      for (let f = 0; f < count; f++) {
        const out = document.createElement("canvas");
        out.width = 56; out.height = 56;
        const ctx = out.getContext("2d");
        const img = ctx.createImageData(56, 56);
        const ox = Math.floor((56 - size) / 2), oy = 56 - size;
        // The background: the white reachable from the picture's edges. Only
        // that is made clear - white inside the Pokemon (eyes, highlights)
        // stays white, so the picture reads on dark paper too.
        const bg = new Uint8Array(size * size), stack = [];
        const at = (x, y) => ((f * size + y) * data.width + x) * 4;
        for (let i = 0; i < size; i++) stack.push([i, 0], [i, size - 1], [0, i], [size - 1, i]);
        while (stack.length) {
          const [x, y] = stack.pop();
          if (x < 0 || y < 0 || x >= size || y >= size || bg[y * size + x] || !isWhite(at(x, y))) continue;
          bg[y * size + x] = 1;
          stack.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]);
        }
        for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
          const s = at(x, y);
          const k = (data.data[s] << 16) | (data.data[s + 1] << 8) | data.data[s + 2];
          const rank = order.indexOf(k);
          if (bg[y * size + x]) continue;   // background: clear
          let rgb = [data.data[s], data.data[s + 1], data.data[s + 2]];
          if (swap && order.length === 4 && (rank === 1 || rank === 2)) rgb = swap[rank - 1];
          const d = ((oy + y) * 56 + ox + x) * 4;
          img.data[d] = rgb[0]; img.data[d + 1] = rgb[1]; img.data[d + 2] = rgb[2]; img.data[d + 3] = 255;
        }
        ctx.putImageData(img, 0, 0);
        frames.push(out);
      }
      return frames;
    })().catch(() => null));
    return framesCache.get(key);
  }

  // Just the still picture (frame 0).
  async function monPicture(base, species, shiny) {
    const frames = await monFrames(base, species, shiny);
    return frames ? frames[0] : null;
  }

  // The game's own animations for a Pokemon (gfx/pokemon/<name>/anim.asm -
  // played when it appears - and anim_idle.asm, copied as animNNN.txt and
  // idleNNN.txt), as lists of [frame, game frames to show it]. The commands
  // run the way PokeAnim_DoAnimScript does: "frame n, d" shows frame n for
  // d frames (at 60 a second), "setrepeat n" + "dorepeat i" play commands
  // from i onward n times in all, "endanim" stops.
  function expandAnim(text) {
    const cmds = [];
    for (const line of text.split("\n")) {
      let m;
      if ((m = line.match(/^\s*frame\s+(\d+)\s*,\s*(\d+)/))) cmds.push(["frame", +m[1], +m[2]]);
      else if ((m = line.match(/^\s*setrepeat\s+(\d+)/))) cmds.push(["set", +m[1]]);
      else if ((m = line.match(/^\s*dorepeat\s+(\d+)/))) cmds.push(["do", +m[1]]);
      else if (/^\s*endanim/.test(line)) cmds.push(["end"]);
    }
    const out = [];
    let pc = 0, repeat = 0;
    for (let guard = 0; guard < 400 && pc < cmds.length; guard++) {
      const c = cmds[pc];
      if (c[0] === "end") break;
      if (c[0] === "set") { repeat = c[1]; pc++; continue; }
      if (c[0] === "do") {
        if (repeat > 0) repeat--;
        if (repeat === 0) { pc++; continue; }
        pc = c[1];
        continue;
      }
      out.push([c[1], Math.max(1, c[2])]);
      pc++;
    }
    return out;
  }
  const animCache = new Map();
  function monAnims(base, species) {
    if (!animCache.has(species)) animCache.set(species, (async () => {
      const tag = String(species).padStart(3, "0");
      const get = async name => { try { const r = await fetch(base + name + tag + ".txt"); return r.ok ? expandAnim(await r.text()) : []; } catch (e) { return []; } };
      const [intro, idle] = await Promise.all([get("anim"), get("idle")]);
      return { intro, idle };
    })());
    return animCache.get(species);
  }
  // A Pokemon's own two colours (light, dark) as [r, g, b], from its front
  // picture (gfx/monNNN.png, in the game's normal palette); null if the
  // picture doesn't have the usual four.
  const colorsCache = new Map();
  function monColors(base, species) {
    if (!colorsCache.has(species)) colorsCache.set(species, (async () => {
      const data = await image(base + "mon" + String(species).padStart(3, "0") + ".png");
      const colors = new Map();
      for (let i = 0; i < data.data.length; i += 4) {
        const k = (data.data[i] << 16) | (data.data[i + 1] << 8) | data.data[i + 2];
        colors.set(k, data.data[i] * 3 + data.data[i + 1] * 6 + data.data[i + 2]);
      }
      const order = [...colors.keys()].sort((a, b) => colors.get(b) - colors.get(a));
      if (order.length !== 4) return null;
      return [order[1], order[2]].map(k => [k >> 16, (k >> 8) & 255, k & 255]);
    })().catch(() => null));
    return colorsCache.get(species);
  }

  return { load, CHARS, monPicture, monFrames, monAnims, expandAnim, monColors };
})();
