// Ground/wall tileset. Every tile is 32x32 and drawn top-down.
import { Surface, rng, shade } from "./png.mjs";

export const TILE = 32;
export const COLS = 8;

const P = {
  wood: [176, 130, 84],
  woodDark: [141, 100, 60],
  woodSeam: [118, 82, 47],
  teal: [58, 122, 124],
  plum: [104, 71, 116],
  concrete: [150, 152, 158],
  kitchenA: [232, 232, 226],
  kitchenB: [206, 208, 205],
  grout: [176, 178, 176],
  grass: [104, 158, 80],
  water: [72, 132, 196],
  wallTop: [222, 216, 205],
  wallFace: [196, 188, 176],
  wallTrim: [150, 142, 130],
  glass: [176, 208, 216, 150],
  frame: [92, 96, 104],
  rug: [190, 92, 82],
  rugTrim: [232, 206, 168],
  stone: [178, 174, 166],
};

// --- individual tile painters -------------------------------------------------

function plankFloor(s, base, seam) {
  const r = rng(7);
  s.rect(0, 0, TILE, TILE, base);
  for (let y = 0; y < TILE; y++) {
    for (let x = 0; x < TILE; x++) {
      if (r() < 0.10) s.px(x, y, shade(base, 0.96));
    }
  }
  // horizontal plank seams every 8px, with staggered vertical joins
  for (let y = 7; y < TILE; y += 8) {
    s.hline(0, y, TILE, seam);
    s.hline(0, y + 1, TILE, shade(base, 1.06));
  }
  const joins = [[0, 12], [8, 26], [16, 5], [24, 19]];
  for (const [row, x] of joins) s.vline(x, row, 7, seam);
}

function noiseFloor(s, base, density, dark, light) {
  const r = rng(19);
  s.rect(0, 0, TILE, TILE, base);
  for (let y = 0; y < TILE; y++) {
    for (let x = 0; x < TILE; x++) {
      const n = r();
      if (n < density) s.px(x, y, shade(base, dark));
      else if (n < density * 2) s.px(x, y, shade(base, light));
    }
  }
}

const painters = {
  void: () => {},

  floor_wood: (s) => plankFloor(s, P.wood, P.woodSeam),
  floor_wood_dark: (s) => plankFloor(s, P.woodDark, shade(P.woodSeam, 0.85)),

  carpet_teal: (s) => noiseFloor(s, P.teal, 0.16, 0.9, 1.08),
  carpet_plum: (s) => noiseFloor(s, P.plum, 0.16, 0.9, 1.08),
  concrete: (s) => noiseFloor(s, P.concrete, 0.09, 0.94, 1.05),

  kitchen_tile: (s) => {
    s.rect(0, 0, TILE, TILE, P.kitchenA);
    s.rect(0, 0, 16, 16, P.kitchenB);
    s.rect(16, 16, 16, 16, P.kitchenB);
    s.hline(0, 0, TILE, P.grout);
    s.hline(0, 16, TILE, P.grout);
    s.vline(0, 0, TILE, P.grout);
    s.vline(16, 0, TILE, P.grout);
  },

  grass: (s) => {
    noiseFloor(s, P.grass, 0.12, 0.88, 1.1);
    const r = rng(31);
    for (let i = 0; i < 14; i++) {
      const x = Math.floor(r() * TILE);
      const y = Math.floor(r() * TILE);
      s.vline(x, y, 2, shade(P.grass, 1.2));
    }
  },

  water: (s) => {
    noiseFloor(s, P.water, 0.10, 0.9, 1.08);
    for (const [x, y, w] of [[4, 7, 9], [18, 13, 8], [8, 22, 11], [22, 27, 6]]) {
      s.hline(x, y, w, shade(P.water, 1.3));
    }
  },

  stone_path: (s) => {
    s.rect(0, 0, TILE, TILE, P.stone);
    const r = rng(53);
    for (let y = 0; y < TILE; y++)
      for (let x = 0; x < TILE; x++) if (r() < 0.12) s.px(x, y, shade(P.stone, 0.93));
    // irregular flagstones — low contrast so it reads as paving, not brickwork
    const seam = shade(P.stone, 0.92);
    s.hline(0, 10, TILE, seam);
    s.hline(0, 21, TILE, seam);
    s.vline(13, 0, 10, seam);
    s.vline(24, 11, 10, seam);
    s.vline(6, 22, 10, seam);
  },

  // Wall seen from above: flat cap the avatar can never stand on.
  wall_top: (s) => {
    s.rect(0, 0, TILE, TILE, P.wallTop);
    s.hline(0, 0, TILE, shade(P.wallTop, 1.05));
    s.hline(0, TILE - 1, TILE, P.wallTrim);
  },

  // The front-facing band drawn on the row below a wall_top.
  wall_front: (s) => {
    s.rect(0, 0, TILE, TILE, P.wallFace);
    s.hline(0, 0, TILE, shade(P.wallFace, 1.12));
    for (let y = 1; y < TILE - 5; y++) s.hline(0, y, TILE, shade(P.wallFace, 1 - y * 0.004));
    s.rect(0, TILE - 5, TILE, 5, P.wallTrim);          // baseboard
    s.hline(0, TILE - 5, TILE, shade(P.wallTrim, 1.15));
  },

  wall_window: (s) => {
    painters.wall_front(s);
    s.rect(4, 5, 24, 16, P.frame);
    s.rect(6, 7, 20, 12, [188, 220, 232]);
    // sky gradient + reflection streaks
    for (let y = 0; y < 12; y++) s.hline(6, 7 + y, 20, shade([188, 220, 232], 1 - y * 0.012));
    s.hline(7, 10, 7, [232, 244, 250]);
    s.hline(9, 12, 5, [232, 244, 250]);
    s.vline(15, 7, 12, P.frame);
    s.hline(6, 13, 20, P.frame);
  },

  // Glass partition for meeting rooms — see-through so the room stays readable.
  glass_top: (s) => {
    s.rect(0, 0, TILE, TILE, P.frame);
    s.rect(0, 10, TILE, 12, [150, 190, 200, 120]);
  },

  glass_front: (s) => {
    s.rect(0, 0, TILE, 4, P.frame);
    s.rect(0, 4, TILE, TILE - 8, P.glass);
    s.rect(0, TILE - 4, TILE, 4, P.frame);
    s.vline(2, 4, TILE - 8, [232, 244, 248, 90]);
    s.vline(3, 4, TILE - 8, [232, 244, 248, 60]);
    s.vline(21, 4, TILE - 8, [232, 244, 248, 70]);
  },

  door_mat: (s) => {
    plankFloor(s, P.wood, P.woodSeam);
    s.roundRect(3, 8, 26, 17, 3, [86, 92, 96]);
    s.roundRect(5, 10, 22, 13, 2, [110, 116, 120]);
  },

  rug_teal: (s) => {
    s.rect(0, 0, TILE, TILE, P.teal);
    s.outline(0, 0, TILE, TILE, shade(P.teal, 0.8));
    s.outline(3, 3, TILE - 6, TILE - 6, P.rugTrim);
  },

  rug_red: (s) => {
    s.rect(0, 0, TILE, TILE, P.rug);
    s.outline(0, 0, TILE, TILE, shade(P.rug, 0.8));
    s.outline(3, 3, TILE - 6, TILE - 6, P.rugTrim);
  },
};

export const TILE_NAMES = Object.keys(painters);

// Tiles the avatar cannot walk through. Everything else is floor.
export const SOLID_TILES = new Set([
  "wall_top", "wall_front", "wall_window", "glass_top", "glass_front", "water",
]);

export function buildTileset() {
  const rows = Math.ceil(TILE_NAMES.length / COLS);
  const sheet = new Surface(COLS * TILE, rows * TILE);
  TILE_NAMES.forEach((name, i) => {
    const cell = new Surface(TILE, TILE);
    painters[name](cell);
    sheet.blit(cell, (i % COLS) * TILE, Math.floor(i / COLS) * TILE);
  });
  return sheet;
}
