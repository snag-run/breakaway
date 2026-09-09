// Furniture / prop spritesheet. Each prop is drawn top-left aligned inside a
// 64x64 cell at exactly its tile footprint, so the sprite and its collision box
// are the same rectangle.
import { Surface, shade, rng } from "./png.mjs";

export const CELL = 64;
export const COLS = 8;

const C = {
  woodTop: [166, 118, 74],
  woodSide: [128, 88, 54],
  metal: [148, 152, 160],
  metalDark: [104, 108, 116],
  dark: [58, 60, 66],
  screen: [40, 46, 58],
  screenGlow: [96, 176, 200],
  white: [238, 238, 234],
  leafA: [76, 140, 72],
  leafB: [102, 168, 92],
  pot: [166, 96, 70],
  fabric: [78, 96, 132],
  fabricLo: [58, 72, 102],
  accent: [214, 118, 92],
  shadow: [0, 0, 0, 60],
};

const shadowUnder = (s, x, y, w, h) => s.roundRect(x, y, w, h, 3, C.shadow);

const props = {
  desk: { w: 2, h: 1, draw(s) {
    shadowUnder(s, 2, 22, 60, 8);
    s.roundRect(1, 4, 62, 20, 3, C.woodTop);
    s.roundRect(1, 4, 62, 4, 2, shade(C.woodTop, 1.12));
    s.rect(1, 24, 62, 4, C.woodSide);
    s.rect(5, 28, 4, 4, C.metalDark);
    s.rect(55, 28, 4, 4, C.metalDark);
    // monitor + keyboard
    s.rect(24, 2, 18, 12, C.dark);
    s.rect(26, 4, 14, 8, C.screen);
    s.hline(27, 6, 8, C.screenGlow);
    s.hline(27, 8, 11, shade(C.screenGlow, 0.7));
    s.rect(30, 14, 6, 2, C.metalDark);
    s.roundRect(22, 17, 22, 5, 1, C.white);
    s.roundRect(47, 17, 6, 5, 2, C.white);
  }},

  desk_double: { w: 2, h: 2, draw(s) {
    shadowUnder(s, 2, 52, 60, 8);
    s.roundRect(1, 6, 62, 50, 4, C.woodTop);
    s.roundRect(1, 6, 62, 4, 2, shade(C.woodTop, 1.12));
    s.hline(1, 31, 62, C.woodSide);
    s.rect(1, 56, 62, 4, C.woodSide);
    for (const [mx, my] of [[10, 10], [38, 34]]) {
      s.rect(mx, my, 18, 12, C.dark);
      s.rect(mx + 2, my + 2, 14, 8, C.screen);
      s.hline(mx + 3, my + 4, 9, C.screenGlow);
    }
  }},

  office_chair: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 6, 24, 20, 6);
    s.roundRect(7, 2, 18, 14, 4, C.fabric);       // backrest, away from the viewer
    s.roundRect(9, 4, 14, 9, 3, shade(C.fabric, 1.15));
    s.roundRect(6, 16, 20, 9, 4, C.fabricLo);     // seat
    s.rect(15, 25, 2, 4, C.metalDark);            // post
    s.hline(9, 29, 14, C.metalDark);              // base
    s.px(9, 30, C.metalDark); s.px(22, 30, C.metalDark);
  }},

  // Same chair turned to face away from the camera — for desks, where you sit
  // with your back to the room. The backrest is nearest the viewer.
  office_chair_up: { w: 1, h: 1, variantOf: "office_chair", facing: "up", draw(s) {
    shadowUnder(s, 6, 24, 20, 6);
    s.rect(15, 12, 2, 6, C.metalDark);            // post, behind everything
    s.hline(9, 8, 14, C.metalDark);               // base splayed away from us
    s.roundRect(6, 6, 20, 9, 4, C.fabricLo);      // seat
    s.roundRect(7, 14, 18, 15, 4, C.fabric);      // backrest, toward the viewer
    s.roundRect(9, 17, 14, 9, 3, shade(C.fabric, 1.15));
  }},

  chair: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 7, 25, 18, 5);
    s.roundRect(8, 3, 16, 6, 2, C.woodSide);
    s.roundRect(7, 12, 18, 13, 3, C.woodTop);
    s.rect(8, 25, 3, 5, C.woodSide);
    s.rect(21, 25, 3, 5, C.woodSide);
  }},

  meeting_table: { w: 2, h: 2, draw(s) {
    shadowUnder(s, 4, 50, 56, 10);
    s.roundRect(2, 8, 60, 46, 14, C.woodTop);
    s.roundRect(2, 8, 60, 5, 12, shade(C.woodTop, 1.12));
    s.roundRect(8, 14, 48, 34, 10, shade(C.woodTop, 0.94));
    // conference puck + notepads
    s.ellipse(32, 31, 5, 4, C.metalDark);
    s.ellipse(32, 30, 3, 2, C.screenGlow);
    for (const [x, y] of [[13, 19], [46, 19], [13, 40], [46, 40]]) s.roundRect(x, y, 7, 5, 1, C.white);
  }},

  couch: { w: 2, h: 1, draw(s) {
    shadowUnder(s, 2, 24, 60, 7);
    s.roundRect(1, 2, 62, 12, 5, C.fabricLo);      // back
    s.roundRect(1, 10, 62, 16, 5, C.fabric);       // seat
    s.roundRect(3, 12, 27, 12, 4, shade(C.fabric, 1.14));
    s.roundRect(34, 12, 27, 12, 4, shade(C.fabric, 1.14));
    s.roundRect(0, 8, 7, 18, 4, C.fabricLo);       // arms
    s.roundRect(57, 8, 7, 18, 4, C.fabricLo);
  }},

  coffee_table: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 3, 24, 26, 6);
    s.roundRect(2, 7, 28, 18, 4, C.woodTop);
    s.roundRect(2, 7, 28, 4, 3, shade(C.woodTop, 1.12));
    s.rect(4, 25, 3, 4, C.woodSide);
    s.rect(25, 25, 3, 4, C.woodSide);
    s.roundRect(11, 12, 10, 8, 2, C.white);        // magazine
    s.hline(13, 15, 6, C.accent);
  }},

  whiteboard: { w: 2, h: 1, draw(s) {
    shadowUnder(s, 4, 26, 56, 5);
    s.rect(2, 2, 60, 24, C.metalDark);
    s.rect(4, 4, 56, 20, C.white);
    // scribbles + a box diagram
    s.outline(9, 8, 14, 9, [72, 110, 190]);
    s.outline(31, 8, 14, 9, [190, 88, 78]);
    s.hline(23, 12, 8, C.dark);
    s.hline(9, 20, 34, [96, 160, 96]);
    s.rect(6, 26, 52, 3, C.metal);
    s.rect(10, 27, 5, 2, C.accent);
  }},

  tv_screen: { w: 2, h: 1, draw(s) {
    shadowUnder(s, 6, 27, 52, 5);
    s.rect(2, 2, 60, 24, C.dark);
    s.rect(5, 5, 54, 18, C.screen);
    for (let y = 0; y < 18; y += 3) s.hline(5, 5 + y, 54, shade(C.screen, 1 + y * 0.02));
    s.roundRect(9, 9, 20, 10, 2, shade(C.screenGlow, 0.8));
    s.roundRect(33, 9, 20, 10, 2, shade(C.screenGlow, 0.55));
    s.rect(28, 26, 8, 4, C.metalDark);
  }},

  bookshelf: { w: 1, h: 1, draw(s) {
    s.rect(2, 1, 28, 30, C.woodSide);
    s.rect(4, 3, 24, 26, shade(C.woodSide, 0.72));
    const r = rng(11);
    const spines = [[100, 140, 190], [190, 110, 90], [120, 170, 110], [200, 180, 100], [150, 120, 180]];
    for (const shelfY of [4, 13, 22]) {
      let x = 5;
      while (x < 26) {
        const w = 2 + Math.floor(r() * 2);
        const h = 6 + Math.floor(r() * 2);
        s.rect(x, shelfY + (8 - h), w, h, spines[Math.floor(r() * spines.length)]);
        x += w + 1;
      }
      s.hline(4, shelfY + 8, 24, C.woodTop);
    }
  }},

  plant_small: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 8, 26, 16, 5);
    s.ellipse(16, 12, 10, 8, C.leafA);
    s.ellipse(12, 10, 5, 4, C.leafB);
    s.ellipse(21, 14, 4, 3, C.leafB);
    s.roundRect(10, 19, 12, 10, 2, C.pot);
    s.hline(10, 19, 12, shade(C.pot, 1.2));
  }},

  plant_tall: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 9, 27, 14, 4);
    s.vline(16, 8, 12, shade(C.leafA, 0.8));
    for (const [x, y, rx, ry] of [[16, 4, 7, 4], [10, 9, 5, 3], [22, 8, 5, 3], [12, 15, 4, 3], [21, 15, 4, 3]]) {
      s.ellipse(x, y, rx, ry, C.leafA);
      s.ellipse(x, y - 1, Math.max(1, rx - 2), Math.max(1, ry - 1), C.leafB);
    }
    s.roundRect(11, 20, 10, 10, 2, shade(C.pot, 0.85));
    s.hline(11, 20, 10, shade(C.pot, 1.1));
  }},

  coffee_machine: { w: 1, h: 1, draw(s) {
    s.roundRect(5, 3, 22, 26, 3, C.metalDark);
    s.roundRect(7, 5, 18, 10, 2, C.screen);
    s.hline(9, 8, 6, C.screenGlow);
    s.rect(9, 17, 14, 8, shade(C.metal, 0.8));
    s.roundRect(12, 19, 8, 7, 2, [92, 62, 44]);   // cup of coffee
    s.hline(13, 20, 6, [156, 110, 78]);
    s.rect(6, 27, 20, 3, C.dark);
  }},

  water_cooler: { w: 1, h: 1, draw(s) {
    s.roundRect(9, 1, 14, 12, 4, [150, 200, 220, 210]);
    s.hline(11, 4, 6, [220, 240, 248]);
    s.roundRect(7, 13, 18, 17, 2, C.white);
    s.rect(13, 17, 6, 3, [110, 170, 200]);
    s.rect(10, 27, 12, 3, C.metalDark);
  }},

  fridge: { w: 1, h: 1, draw(s) {
    s.roundRect(4, 1, 24, 30, 3, C.white);
    s.hline(4, 12, 24, C.metal);
    s.vline(23, 4, 7, C.metalDark);
    s.vline(23, 15, 12, C.metalDark);
    s.roundRect(8, 4, 5, 4, 1, [214, 118, 92]);   // magnet
    s.roundRect(8, 17, 5, 4, 1, [96, 160, 96]);
  }},

  printer: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 4, 26, 24, 5);
    s.roundRect(3, 8, 26, 18, 2, C.metal);
    s.rect(3, 8, 26, 4, C.metalDark);
    s.roundRect(8, 2, 16, 7, 1, C.white);          // paper tray
    s.rect(6, 16, 20, 3, C.dark);
    s.px(25, 13, C.screenGlow);
  }},

  server_rack: { w: 1, h: 1, draw(s) {
    s.roundRect(5, 1, 22, 30, 2, C.dark);
    for (let i = 0; i < 6; i++) {
      const y = 4 + i * 4;
      s.rect(7, y, 18, 3, shade(C.metalDark, 0.9));
      s.px(9, y + 1, i % 2 ? C.screenGlow : [120, 200, 120]);
      s.px(11, y + 1, [120, 200, 120]);
    }
  }},

  beanbag: { w: 1, h: 1, draw(s) {
    shadowUnder(s, 5, 25, 22, 6);
    s.ellipse(16, 19, 13, 10, C.accent);
    s.ellipse(16, 15, 10, 7, shade(C.accent, 1.12));
    s.ellipse(13, 13, 4, 3, shade(C.accent, 1.25));
  }},

  arcade: { w: 1, h: 1, draw(s) {
    s.roundRect(5, 1, 22, 30, 3, [82, 66, 140]);
    s.rect(8, 4, 16, 12, C.screen);
    s.rect(10, 6, 4, 3, [232, 96, 96]);
    s.rect(16, 9, 4, 3, [96, 200, 232]);
    s.rect(12, 12, 8, 2, [232, 220, 96]);
    s.rect(8, 18, 16, 6, shade([82, 66, 140], 1.2));
    s.px(12, 20, [232, 96, 96]); s.px(18, 20, [96, 200, 232]);
    s.rect(8, 26, 16, 4, C.dark);
  }},

  lamp: { w: 1, h: 1, draw(s) {
    s.roundRect(9, 2, 14, 9, 3, [232, 208, 140]);
    s.ellipse(16, 13, 6, 3, [255, 240, 190, 90]);
    s.vline(16, 11, 16, C.metalDark);
    s.ellipse(16, 28, 6, 3, C.metalDark);
  }},
};

const ALL_SPRITES = Object.keys(props);

// Placeable kinds. Oriented variants are art only — a chair facing up is still
// a chair, so it must not become a separate thing you can put on the floor.
export const PROP_NAMES = ALL_SPRITES.filter((n) => !props[n].variantOf);

export const PROP_META = Object.fromEntries(
  PROP_NAMES.map((n) => [
    n,
    { index: ALL_SPRITES.indexOf(n), w: props[n].w, h: props[n].h },
  ])
);

// baseKind -> { facing -> spritesheet cell index }
export const PROP_VARIANTS = ALL_SPRITES.reduce((acc, name) => {
  const { variantOf, facing } = props[name];
  if (!variantOf) return acc;
  acc[variantOf] = { ...(acc[variantOf] || {}), [facing]: ALL_SPRITES.indexOf(name) };
  return acc;
}, {});

export function buildFurniture() {
  const rows = Math.ceil(ALL_SPRITES.length / COLS);
  const sheet = new Surface(COLS * CELL, rows * CELL);
  ALL_SPRITES.forEach((name, i) => {
    const cell = new Surface(CELL, CELL);
    props[name].draw(cell);
    sheet.blit(cell, (i % COLS) * CELL, Math.floor(i / COLS) * CELL);
  });
  return sheet;
}
