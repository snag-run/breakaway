// Canvas renderer for the office floor.
//
// The server owns the truth: it sends avatar positions at 20Hz and this hook
// interpolates between them at display rate. Input is intent only — a direction
// vector, sent when it changes rather than every frame.

const TILE = 32;
const ZOOMS = [1, 2, 3];  // integer only — fractional scaling blurs pixel art
const DEFAULT_ZOOM = 1;   // index into ZOOMS
const LERP = 18;          // higher snaps harder to the server position
const BUBBLE_MS = 6000;

const KEY_VECTORS = {
  ArrowUp: [0, -1], KeyW: [0, -1],
  ArrowDown: [0, 1], KeyS: [0, 1],
  ArrowLeft: [-1, 0], KeyA: [-1, 0],
  ArrowRight: [1, 0], KeyD: [1, 0],
};

const loadImage = (src) =>
  new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`failed to load ${src}`));
    img.src = src;
  });

export const Office = {
  async mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d", { alpha: false });
    this.selfId = this.el.dataset.userId;

    this.avatars = new Map();   // id -> {x, y, tx, ty, dir, palette, moving, frame, name, status}
    this.bubbles = new Map();   // id -> {text, until}
    this.held = new Set();
    this.input = [0, 0];
    this.map = null;
    this.ground = null;         // pre-rendered static layer
    this.camera = { x: 0, y: 0 };
    this.running = true;
    this.ready = false;         // true once the spritesheets have decoded
    this.zoom = DEFAULT_ZOOM;

    // Register these *before* awaiting anything. `office:map` is pushed during
    // mount, and a listener attached after the await would never see it.
    this.handleEvent("office:map", (map) => this.setMap(map));
    this.handleEvent("office:tick", ({ avatars }) => this.applyTick(avatars));
    this.handleEvent("office:say", ({ id, text }) =>
      this.bubbles.set(id, { text, until: performance.now() + BUBBLE_MS })
    );

    this.bindInput();
    this.resize();
    this.onResize = () => this.resize();
    window.addEventListener("resize", this.onResize);

    this.last = performance.now();
    this.frame = requestAnimationFrame((t) => this.loop(t));

    this.atlas = await fetch("/images/atlas.json").then((r) => r.json());
    const [tiles, props, avatars] = await Promise.all([
      loadImage(this.atlas.tiles.src),
      loadImage(this.atlas.props.src),
      loadImage(this.atlas.avatars.src),
    ]);
    this.sheets = { tiles, props, avatars };
    this.ready = true;
    if (this.map) this.ground = this.renderGround(this.map);
  },

  destroyed() {
    this.running = false;
    cancelAnimationFrame(this.frame);
    window.removeEventListener("resize", this.onResize);
    window.removeEventListener("keydown", this.onKeyDown);
    window.removeEventListener("keyup", this.onKeyUp);
    window.removeEventListener("blur", this.onBlur);
  },

  // --- map ------------------------------------------------------------------

  setMap(map) {
    this.map = map;
    if (this.ready) this.ground = this.renderGround(map);
    const me = this.avatars.get(this.selfId);
    if (!me) this.camera = { x: map.spawn_x + 0.5, y: map.spawn_y + 0.5 };
  },

  // The ground never changes, so flatten it into one offscreen canvas and blit
  // the visible slice each frame instead of drawing ~1400 tiles.
  renderGround(map) {
    const c = document.createElement("canvas");
    c.width = map.width * TILE;
    c.height = map.height * TILE;
    const g = c.getContext("2d");
    g.imageSmoothingEnabled = false;

    const cols = this.atlas.tiles.columns;
    for (let y = 0; y < map.height; y++) {
      for (let x = 0; x < map.width; x++) {
        const id = map.ground[y * map.width + x];
        g.drawImage(
          this.sheets.tiles,
          (id % cols) * TILE, Math.floor(id / cols) * TILE, TILE, TILE,
          x * TILE, y * TILE, TILE, TILE
        );
      }
    }
    return c;
  },

  // --- server updates -------------------------------------------------------

  applyTick(list) {
    const seen = new Set();
    for (const a of list) {
      seen.add(a.id);
      const existing = this.avatars.get(a.id);
      if (existing) {
        existing.tx = a.x; existing.ty = a.y;
        existing.dir = a.d; existing.palette = a.p;
        existing.moving = a.m; existing.frame = a.f;
        existing.name = a.n; existing.status = a.s; existing.zone = a.z;
        existing.activity = a.a;
        existing.seated = a.sit;
      } else {
        this.avatars.set(a.id, {
          x: a.x, y: a.y, tx: a.x, ty: a.y,
          dir: a.d, palette: a.p, moving: a.m, frame: a.f,
          name: a.n, status: a.s, zone: a.z, activity: a.a, seated: a.sit,
        });
        // Don't pan the camera across the map on first sight of ourselves.
        if (a.id === this.selfId) this.camera = { x: a.x, y: a.y };
      }
    }
    for (const id of this.avatars.keys()) if (!seen.has(id)) this.avatars.delete(id);
  },

  // --- input ----------------------------------------------------------------

  bindInput() {
    this.onKeyDown = (e) => {
      if (this.typing(e.target)) {
        if (e.code === "Escape") e.target.blur();
        return;
      }
      if (e.code === "KeyE") {
        e.preventDefault();
        this.pushEvent("interact", {});
        return;
      }
      if (e.code === "Enter") {
        const input = document.querySelector("#chat-form input[name=text]");
        if (input) { e.preventDefault(); input.focus(); }
        return;
      }
      if (e.code === "Minus" || e.code === "Equal") {
        e.preventDefault();
        this.zoom = Math.max(0, Math.min(ZOOMS.length - 1, this.zoom + (e.code === "Equal" ? 1 : -1)));
        return;
      }
      const v = KEY_VECTORS[e.code];
      if (!v) return;
      e.preventDefault();
      this.held.add(e.code);
      this.pushInput();
    };
    this.onKeyUp = (e) => {
      if (e.code === "Escape" && this.typing(e.target)) { e.target.blur(); return; }
      if (!KEY_VECTORS[e.code]) return;
      this.held.delete(e.code);
      this.pushInput();
    };
    // Releasing focus mid-stride would otherwise leave the avatar walking forever.
    this.onBlur = () => { this.held.clear(); this.pushInput(); };

    window.addEventListener("keydown", this.onKeyDown);
    window.addEventListener("keyup", this.onKeyUp);
    window.addEventListener("blur", this.onBlur);
  },

  typing(el) {
    return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
  },

  pushInput() {
    let dx = 0, dy = 0;
    for (const code of this.held) {
      const [vx, vy] = KEY_VECTORS[code];
      dx += vx; dy += vy;
    }
    dx = Math.sign(dx); dy = Math.sign(dy);
    if (dx === this.input[0] && dy === this.input[1]) return;
    this.input = [dx, dy];
    this.pushEvent("move", { dx, dy });
  },

  // --- rendering ------------------------------------------------------------

  resize() {
    const rect = this.el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this.canvas.width = Math.floor(rect.width * dpr);
    this.canvas.height = Math.floor(rect.height * dpr);
    this.canvas.style.width = `${rect.width}px`;
    this.canvas.style.height = `${rect.height}px`;
    this.dpr = dpr;
    this.viewW = rect.width;
    this.viewH = rect.height;
  },

  loop(now) {
    if (!this.running) return;
    const dt = Math.min((now - this.last) / 1000, 0.1);
    this.last = now;

    for (const a of this.avatars.values()) {
      const k = Math.min(1, dt * LERP);
      a.x += (a.tx - a.x) * k;
      a.y += (a.ty - a.y) * k;
    }

    const me = this.avatars.get(this.selfId);
    if (me) {
      const k = Math.min(1, dt * 8);
      this.camera.x += (me.x - this.camera.x) * k;
      this.camera.y += (me.y - this.camera.y) * k;
    }

    this.draw();
    this.frame = requestAnimationFrame((t) => this.loop(t));
  },

  draw() {
    const { ctx } = this;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = "#14161c";
    ctx.fillRect(0, 0, this.viewW, this.viewH);

    if (!this.ready || !this.map || !this.ground) return;

    const scale = ZOOMS[this.zoom];
    const tile = TILE * scale;
    const worldW = this.map.width * tile;
    const worldH = this.map.height * tile;

    // Camera in screen pixels, clamped so we never show past the walls (unless
    // the floor is smaller than the viewport, in which case centre it).
    let ox = this.viewW / 2 - this.camera.x * tile;
    let oy = this.viewH / 2 - this.camera.y * tile;
    ox = worldW <= this.viewW ? (this.viewW - worldW) / 2 : Math.min(0, Math.max(this.viewW - worldW, ox));
    oy = worldH <= this.viewH ? (this.viewH - worldH) / 2 : Math.min(0, Math.max(this.viewH - worldH, oy));
    ox = Math.round(ox); oy = Math.round(oy);

    ctx.save();
    ctx.translate(ox, oy);
    ctx.scale(scale, scale);

    ctx.drawImage(this.ground, 0, 0);
    this.drawZones(ctx);

    // Props and avatars share one depth-sorted pass so you can stand behind a
    // desk and be occluded by it.
    const drawables = [];
    for (const p of this.map.props) {
      const meta = this.atlas.props.meta[p.kind];
      drawables.push({ sort: (p.y + meta.h) * TILE, kind: "prop", p, meta });
    }
    for (const [id, a] of this.avatars) {
      // Props sort by their bottom edge, so bias a seated avatar a tile lower —
      // otherwise the chair would be painted over the person sitting in it.
      const sortY = a.seated ? a.y + 1 : a.y;
      drawables.push({ sort: sortY * TILE, kind: "avatar", id, a });
    }
    drawables.sort((m, n) => m.sort - n.sort);

    for (const d of drawables) {
      if (d.kind === "prop") this.drawProp(ctx, d.p, d.meta);
      else this.drawAvatar(ctx, d.id, d.a);
    }

    ctx.restore();

    // Labels are drawn unscaled so text stays crisp at any zoom.
    this.drawLabels(ox, oy, tile);
    this.drawInteractHint(ox, oy, tile);
  },

  drawZones(ctx) {
    for (const z of this.map.zones) {
      if (z.kind === "lobby") continue;
      ctx.save();
      ctx.globalAlpha = 0.10;
      ctx.fillStyle = z.accent;
      ctx.fillRect(z.x * TILE, z.y * TILE, z.width * TILE, z.height * TILE);
      ctx.globalAlpha = 0.55;
      ctx.strokeStyle = z.accent;
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 3]);
      ctx.strokeRect(z.x * TILE + 0.5, z.y * TILE + 0.5, z.width * TILE - 1, z.height * TILE - 1);
      ctx.restore();
    }
  },

  drawProp(ctx, p, meta) {
    const cell = this.atlas.props.cell;
    const cols = this.atlas.props.columns;
    ctx.drawImage(
      this.sheets.props,
      (meta.index % cols) * cell, Math.floor(meta.index / cols) * cell,
      meta.w * TILE, meta.h * TILE,
      p.x * TILE, p.y * TILE,
      meta.w * TILE, meta.h * TILE
    );
  },

  drawAvatar(ctx, id, a) {
    const { frameWidth: fw, frameHeight: fh, directions, sitFrame } = this.atlas.avatars;
    const dirIndex = Math.max(0, directions.indexOf(a.dir));
    const row = a.palette * directions.length + dirIndex;
    const frame = a.seated ? sitFrame : a.moving ? a.frame : 0;

    // Feet sit on the avatar's position; the sprite is taller than a tile.
    const dx = Math.round(a.x * TILE - fw / 2);
    const dy = Math.round(a.y * TILE - fh + TILE / 2);

    if (id === this.selfId && !a.seated) {
      ctx.save();
      ctx.globalAlpha = 0.35;
      ctx.strokeStyle = "#ffd479";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.ellipse(a.x * TILE, a.y * TILE + 4, 11, 5, 0, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    ctx.drawImage(this.sheets.avatars, frame * fw, row * fh, fw, fh, dx, dy, fw, fh);
  },

  drawLabels(ox, oy, tile) {
    const ctx = this.ctx;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "bottom";

    for (const z of this.map.zones) {
      if (z.kind === "lobby") continue;
      const x = ox + (z.x + z.width / 2) * tile;
      const y = oy + z.y * tile - 4;
      if (x < -200 || x > this.viewW + 200) continue;
      ctx.font = "600 11px ui-sans-serif, system-ui, sans-serif";
      ctx.fillStyle = "rgba(255,255,255,0.55)";
      ctx.fillText(z.name.toUpperCase(), x, y);
    }

    const now = performance.now();
    for (const [id, a] of this.avatars) {
      const x = ox + a.x * tile;
      const y = oy + a.y * tile - tile * 1.25;
      if (x < -100 || x > this.viewW + 100) continue;

      ctx.font = "600 12px ui-sans-serif, system-ui, sans-serif";
      const w = ctx.measureText(a.name).width + 10;
      ctx.fillStyle = id === this.selfId ? "rgba(255,212,121,0.92)" : "rgba(20,22,28,0.75)";
      this.roundRect(ctx, x - w / 2, y - 15, w, 16, 5);
      ctx.fill();
      ctx.fillStyle = id === this.selfId ? "#1a1c22" : "#f2f2ef";
      ctx.fillText(a.name, x, y - 2);

      if (a.activity) {
        ctx.font = "600 11px ui-sans-serif, system-ui, sans-serif";
        ctx.lineWidth = 3;
        ctx.strokeStyle = "rgba(12,14,18,0.85)";
        ctx.strokeText(a.activity, x, y - 17);
        ctx.fillStyle = "rgba(255,255,255,0.85)";
        ctx.fillText(a.activity, x, y - 17);
      }

      const bubble = this.bubbles.get(id);
      if (bubble) {
        if (bubble.until < now) { this.bubbles.delete(id); continue; }
        ctx.font = "13px ui-sans-serif, system-ui, sans-serif";
        const bw = Math.min(220, ctx.measureText(bubble.text).width + 16);
        ctx.fillStyle = "rgba(250,250,247,0.96)";
        this.roundRect(ctx, x - bw / 2, y - 44, bw, 24, 8);
        ctx.fill();
        ctx.fillStyle = "#1a1c22";
        ctx.fillText(this.ellipsize(ctx, bubble.text, 204), x, y - 26);
      }
    }
    ctx.restore();
  },

  // Mirrors the server's reach check so the hint only appears when pressing E
  // would actually do something.
  nearestInteractable() {
    const me = this.avatars.get(this.selfId);
    if (!me || !this.map?.interactions) return null;

    const reach = this.map.reach ?? 1.7;
    let best = null;
    for (const p of this.map.props) {
      const prompt = this.map.interactions[p.kind];
      if (!prompt) continue;
      const meta = this.atlas.props.meta[p.kind];
      const dx = p.x + meta.w / 2 - me.x;
      const dy = p.y + meta.h / 2 - me.y;
      const d = Math.hypot(dx, dy);
      if (d <= reach && (!best || d < best.d)) best = { d, prompt };
    }
    return best;
  },

  drawInteractHint(ox, oy, tile) {
    const me = this.avatars.get(this.selfId);
    if (!me) return;

    const near = this.nearestInteractable();
    const label = me.seated ? "Stand up" : me.activity ? "Stop" : near && near.prompt;
    if (!label) return;

    const ctx = this.ctx;
    const x = ox + me.x * tile;
    const y = oy + me.y * tile + tile * 0.85;

    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "600 12px ui-sans-serif, system-ui, sans-serif";

    const keyW = 18;
    const textW = ctx.measureText(label).width;
    const w = keyW + textW + 20;

    ctx.fillStyle = "rgba(20,22,28,0.82)";
    this.roundRect(ctx, x - w / 2, y - 12, w, 24, 8);
    ctx.fill();

    ctx.fillStyle = "rgba(255,212,121,0.95)";
    this.roundRect(ctx, x - w / 2 + 6, y - 8, keyW, 16, 4);
    ctx.fill();

    ctx.fillStyle = "#1a1c22";
    ctx.fillText("E", x - w / 2 + 6 + keyW / 2, y + 1);

    ctx.fillStyle = "#f2f2ef";
    ctx.textAlign = "left";
    ctx.fillText(label, x - w / 2 + keyW + 12, y + 1);
    ctx.restore();
  },

  ellipsize(ctx, text, max) {
    if (ctx.measureText(text).width <= max) return text;
    let t = text;
    while (t.length > 1 && ctx.measureText(t + "…").width > max) t = t.slice(0, -1);
    return t + "…";
  },

  roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  },
};

// Clears the composer once the server has accepted the message, so a dropped
// connection never silently swallows what you typed.
export const ChatInput = {
  mounted() {
    this.handleEvent("office:sent", () => this.el.reset());
  },
};

// The controls panel. Kept out of LiveView's hands (phx-update="ignore") so the
// open/closed state survives re-renders, and remembered per browser so it stops
// greeting people who already know the keys.
const CONTROLS_KEY = "breakaway:controls-open";

export const ControlsOverlay = {
  mounted() {
    this.panel = this.el.querySelector("[data-role=panel]");
    this.toggle = this.el.querySelector("[data-role=toggle]");

    let open = true;
    try {
      const stored = localStorage.getItem(CONTROLS_KEY);
      if (stored !== null) open = stored === "1";
    } catch (_) {
      // Private mode or blocked storage — just show the panel.
    }
    this.setOpen(open);

    this.toggle.addEventListener("click", () => this.setOpen(this.panel.hidden));

    this.onKey = (e) => {
      const el = e.target;
      if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)) return;
      if (e.key === "?" || e.code === "Slash") {
        e.preventDefault();
        this.setOpen(this.panel.hidden);
      }
    };
    window.addEventListener("keydown", this.onKey);
  },

  setOpen(open) {
    this.panel.hidden = !open;
    this.toggle.setAttribute("aria-expanded", String(open));
    try {
      localStorage.setItem(CONTROLS_KEY, open ? "1" : "0");
    } catch (_) {
      // Not being able to remember the choice is not worth failing over.
    }
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey);
  },
};
