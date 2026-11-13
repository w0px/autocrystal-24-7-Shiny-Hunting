// layouts.js - what a stream layout is made of, shared by scene.html (draws
// it), editor.html (edits it) and stage.html (previews it).
//
// A layout: { scale, clouds, meadow, water (opacities), scenery, visitors (opacity), visitorSize, visitorList, unown (opacity),
// girl, game: {x, y, w, h}, panels: [...] }, all
// in screen pixels on a 1920x1080 scene. Each panel: { type, x, y, w, h }
// (+ text for a "title"). Panels snap to tiles of 8 x scale pixels. Saved by
// the editor as layout.json next to the pages; without one, DEFAULT.

const AC_LAYOUT = {
  // The modules a panel can show. min: the smallest size that still fits,
  // in tiles (8 x scale pixels).
  MODULES: {
    chat:       { label: "Log (what the bot says, with times)", min: [20, 6] },
    encounters:      { label: "Encounters A: current + icon rows", min: [36, 8] },
    encounters_log:  { label: "Encounters B: current + text lines", min: [32, 14] },
    encounters_pics: { label: "Encounters C: current + picture rows", min: [32, 14] },
    now:        { label: "Current encounter only", min: [16, 14] },
    before:     { label: "Encounters before only (icon rows)", min: [16, 8] },
    wild:       { label: "Wild here, this time of day (table)", min: [22, 8] },
    shinies:    { label: "Recent shinies", min: [16, 13] },
    info:       { label: "Clock, place and the numbers", min: [16, 8] },
    title:      { label: "Text", min: [6, 3] },
  },

  // The flying visitors: when and over what each one comes by. times: MORN,
  // DAY (late afternoon counts as day), NITE; backdrops: the band showing
  // along the panels' tops. The layout's visitorList, once picked in the
  // editor, replaces this.
  TIMES: [["MORN", "Morning"], ["DAY", "Day"], ["NITE", "Night"]],
  BACKDROPS: [["clouds", "Clouds"], ["grass", "Meadow"], ["water", "Water"]],
  VISITORS: [
    // morning
    { species: 165, times: ["MORN"], backdrops: ["clouds", "grass"] },                  // Ledyba
    { species: 166, times: ["MORN"], backdrops: ["clouds", "grass"] },                  // Ledian
    { species: 12, times: ["MORN", "DAY"], backdrops: ["clouds", "grass"] },            // Butterfree
    { species: 187, times: ["MORN", "DAY"], backdrops: ["clouds", "grass", "water"] },  // Hoppip
    { species: 188, times: ["MORN"], backdrops: ["clouds", "grass", "water"] },         // Skiploom
    { species: 231, times: ["MORN"], backdrops: ["grass"] },                            // Phanpy
    { species: 16, times: ["MORN", "DAY"], backdrops: ["clouds", "grass", "water"] },   // Pidgey
    { species: 21, times: ["MORN", "DAY"], backdrops: ["clouds", "grass", "water"] },   // Spearow
    // day
    { species: 17, times: ["DAY"], backdrops: ["clouds", "grass", "water"] },           // Pidgeotto
    { species: 22, times: ["DAY"], backdrops: ["clouds", "grass", "water"] },           // Fearow
    { species: 189, times: ["DAY"], backdrops: ["clouds", "grass", "water"] },          // Jumpluff
    { species: 177, times: ["DAY"], backdrops: ["clouds", "grass"] },                   // Natu
    { species: 83, times: ["DAY"], backdrops: ["clouds", "grass", "water"] },           // Farfetch'd
    { species: 193, times: ["DAY"], backdrops: ["clouds", "grass", "water"] },          // Yanma
    { species: 226, times: ["MORN", "DAY"], backdrops: ["water"] },                     // Mantine
    // night
    { species: 92, times: ["NITE"], backdrops: ["clouds", "grass"] },                   // Gastly
    { species: 93, times: ["NITE"], backdrops: ["clouds", "grass"] },                   // Haunter
    { species: 200, times: ["NITE"], backdrops: ["clouds", "grass"] },                  // Misdreavus
    { species: 198, times: ["NITE"], backdrops: ["clouds", "grass", "water"] },         // Murkrow
    { species: 163, times: ["NITE"], backdrops: ["clouds", "grass", "water"] },         // Hoothoot
    { species: 164, times: ["NITE"], backdrops: ["clouds", "grass", "water"] },         // Noctowl
    { species: 41, times: ["NITE"], backdrops: ["clouds", "grass", "water"] },          // Zubat
    { species: 42, times: ["NITE"], backdrops: ["clouds", "grass", "water"] },          // Golbat
    { species: 49, times: ["NITE"], backdrops: ["clouds", "grass"] },                   // Venomoth
    { species: 131, times: ["NITE"], backdrops: ["water"] },                            // Lapras
  ],
  // Areas inside a panel you can move and size in the editor (select the
  // panel; they show as orange boxes), and settings for what's in them. In
  // tiles, from the panel's top-left corner; kept in the panel as
  // areas: {name: {x, y, w, h}} and opts: {key: value}. Never edited: the
  // defaults below (computed from the panel's size, in tiles), which are
  // the panels' old fixed layout.
  AREAS: {
    encounters_pics: {
      areas: {
        current: { label: "Current encounter", min: [8, 6], def: (w, h) => ({ x: 2, y: 2, w: 14, h: h - 4 }) },
        list: { label: "Before it", min: [10, 3], def: (w, h) => ({ x: 17, y: 2, w: w - 18, h: h - 4 }) },
      },
      // rowStep: tiles per row in the list. 4 and up: name, DVs, item, each
      // a line; 3 (the default - 4 rows fit): name, then DVs with the item
      // after them where it fits, and a row clear; 2: no gap. Smaller rows,
      // more of them.
      opts: { rowStep: { label: "Row height", min: 2, max: 6, def: 3, unit: "tiles" } },
    },
    shinies: {
      areas: {
        row: { label: "Shinies", min: [8, 10], def: (w, h) => ({ x: 2, y: 2, w: w - 4, h: 10 }) },
      },
      // slot: tiles each shiny gets across. Narrower, more of them.
      // card: the recent shinies take turns with the shiny history, this
      // many seconds each - 0: no turns (the user, 2026-11-10).
      opts: { slot: { label: "Slot width", min: 7, max: 16, def: 12, unit: "tiles" },
        card: { label: "Card turns (+ history)", min: 0, max: 120, def: 0, unit: "s" } },
    },
    wild: {
      areas: {},
      // card: the encounter table takes turns with the luck board (most over
      // the odds) and the most met, this many seconds each - 0: the table
      // always (the user, 2026-11-10).
      opts: { card: { label: "Card turns (+ luck, most met)", min: 0, max: 120, def: 0, unit: "s" } },
    },
    info: {
      areas: {},
      // card: the numbers on the right take turns with the wild table, the
      // luck board and the most met, this many seconds each - 0: no turns,
      // the numbers always (the user, 2026-11-10: "the encounter table on
      // the right side of the stats, rotating every 30 sec like cards").
      opts: { card: { label: "Card turns (+ table, luck, most met)", min: 0, max: 120, def: 0, unit: "s" } },
    },
  },
  // An area of panel p (w x h tiles): its saved place, kept inside the panel
  // (within its frame), or the default.
  areaOf(p, name, w, h) {
    const spec = this.AREAS[p.type] && this.AREAS[p.type].areas[name];
    if (!spec) return null;
    const saved = p.areas && p.areas[name];
    const a = Object.assign({}, spec.def(w, h), saved || {});
    a.w = Math.max(1, Math.min(a.w, w - 2)); a.h = Math.max(1, Math.min(a.h, h - 2));
    a.x = Math.max(1, Math.min(a.x, w - 1 - a.w)); a.y = Math.max(1, Math.min(a.y, h - 1 - a.h));
    return a;
  },
  optOf(p, key) {
    const spec = this.AREAS[p.type] && this.AREAS[p.type].opts[key];
    if (!spec) return null;
    const v = p.opts && p.opts[key] != null ? Number(p.opts[key]) : spec.def;
    return Math.min(spec.max, Math.max(spec.min, v));
  },
  // The meadow and water strips' settings (the editor's "Meadow & water"
  // sliders): key, label, min, max, step, default, how the value reads.
  // Kept in the layout as layout.scenery = { key: value }.
  SCENERY: [
    ["meadowSpeed", "Meadow speed", 0.25, 3, 0.05, 1, v => v.toFixed(2) + "x"],
    ["meadowFade", "Meadow top fade", 0, 80, 1, 44, v => v + " px"],
    ["meadowThin", "Dark band fade", 0.5, 4, 0.1, 1.5, v => v.toFixed(1)],
    ["trees", "Trees", 0, 8, 1, 3, v => v + " per 1500 px"],
    ["treeSoft", "Tree sides", 0, 60, 1, 28, v => v + " px soft"],
    ["treeFade", "Tree fade", 10, 100, 1, 50, v => v + " px"],
    ["waterSpeed", "Water speed", 0.25, 3, 0.05, 1, v => v.toFixed(2) + "x"],
    ["waterHeight", "Water height", 0.2, 1, 0.05, 0.55, v => Math.round(v * 100) + "% of a panel"],
    ["waterFade", "Water top fade", 0, 80, 1, 24, v => v + " px"],
    ["feet", "Visitor in grass", 0, 30, 1, 6, v => v + " px up"],
  ],
  sceneryOf(layout, key) {
    const spec = this.SCENERY.find(s => s[0] === key);
    const v = layout.scenery && layout.scenery[key] != null ? Number(layout.scenery[key]) : spec[5];
    return Math.min(spec[3], Math.max(spec[2], v));
  },
  // The meadow's opacity: its own slider's, else (never set) 80% of the clouds'.
  meadowOf(layout) {
    if (layout.meadow != null) return Number(layout.meadow);
    return Math.round((layout.clouds != null ? Number(layout.clouds) : 0.35) * 0.8 * 100) / 100;
  },
  // The water's opacity: its own slider's, else (never set) the clouds'.
  waterOf(layout) {
    if (layout.water != null) return Number(layout.water);
    return layout.clouds != null ? Number(layout.clouds) : 0.35;
  },
  visitorsOf(layout) { return Array.isArray(layout.visitorList) ? layout.visitorList : this.VISITORS; },

  // Where the Game Boy's own 160x144 screen shows, in scene pixels - the
  // chat poll / bet box sits on the game's text box there. layout.screen
  // (the editor's "Game Boy screen" numbers), else fitted into the game box,
  // centred (the user's OBS capture may include BizHawk's menu or borders,
  // so it can't be known from the game box alone).
  screenOf(layout) {
    const s = layout && layout.screen;
    if (s && s.w > 0 && s.h > 0) return { x: Number(s.x) || 0, y: Number(s.y) || 0, w: Number(s.w), h: Number(s.h) };
    const g = (layout && layout.game) || { x: 0, y: 0, w: 1280, h: 864 };
    const k = Math.min(g.w / 160, g.h / 144);
    return { x: Math.round(g.x + (g.w - 160 * k) / 2), y: Math.round(g.y + (g.h - 144 * k) / 2), w: Math.round(160 * k), h: Math.round(144 * k) };
  },
  // A sample poll or bet (the editor's Test buttons, scene.html?vote=poll):
  // made-up votes come in for 40 seconds, then the result (scene.html).
  testVote(kind) {
    const now = Math.floor(Date.now() / 1000);
    return kind === "bet"
      ? { id: "test-" + now, test: true, kind: "bet", question: "SHINY IN 1H?", options: ["YES", "NO"], pot: 3150, started: now, ends: now + 40 }
      : { id: "test-" + now, test: true, kind: "poll", question: "NEXT SPOT?", options: ["DARK CAVE", "ROUTE 32", "UNION CAVE"], started: now, ends: now + 40 };
  },

  DEFAULT: {
    scale: 2, clouds: 0.35, visitors: 0.8, visitorSize: 0.45, girl: false,
    game: { x: 0, y: 0, w: 1280, h: 864 },
    panels: [
      { type: "chat", x: 1280, y: 0, w: 640, h: 288 },
      { type: "encounters", x: 1280, y: 288, w: 640, h: 384 },
      { type: "wild", x: 1280, y: 672, w: 640, h: 400 },
      { type: "shinies", x: 0, y: 864, w: 848, h: 208 },
      { type: "info", x: 848, y: 864, w: 432, h: 208 },
    ],
  },

  copy(layout) { return JSON.parse(JSON.stringify(layout)); },

  // layout.json if there is one, else the default. file: another layout
  // next to it to show instead (scene.html?layout=layout.option-log-cards.json -
  // the user, 2026-11-10: two layouts to choose from; the editor always
  // edits layout.json).
  async load(file) {
    const name = file && /^[\w.-]+\.json$/.test(file) ? file : "layout.json";
    try {
      const r = await fetch(name, { cache: "no-store" });
      if (r.ok) {
        const l = await r.json();
        if (l && Array.isArray(l.panels) && l.game) return l;
      }
    } catch (e) { /* none saved yet */ }
    return this.copy(this.DEFAULT);
  },
};
