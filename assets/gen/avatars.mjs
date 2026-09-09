// Character spritesheet.
// Layout: 4 frames (walk cycle) across, 4 directions down, repeated per palette.
// Direction order matches DIRS below; palettes stack vertically.
import { Surface, shade } from "./png.mjs";

export const FW = 32;   // frame width
export const FH = 40;   // frame height
export const DIRS = ["down", "left", "right", "up"];
export const FRAMES = 4;

// Each palette is one selectable look in the avatar picker.
export const PALETTES = [
  { name: "amber",  skin: [232, 190, 156], hair: [86, 58, 42],  shirt: [214, 134, 74],  pants: [66, 74, 102], shoe: [52, 52, 58] },
  { name: "teal",   skin: [198, 150, 116], hair: [40, 36, 40],  shirt: [70, 150, 148],  pants: [58, 62, 78],  shoe: [44, 44, 50] },
  { name: "violet", skin: [246, 214, 190], hair: [178, 106, 62], shirt: [124, 104, 186], pants: [72, 68, 88],  shoe: [56, 50, 62] },
  { name: "rose",   skin: [148, 104, 76],  hair: [30, 28, 32],  shirt: [212, 108, 128], pants: [52, 56, 72],  shoe: [40, 40, 46] },
  { name: "moss",   skin: [222, 176, 138], hair: [212, 186, 118], shirt: [104, 152, 88], pants: [78, 70, 60],  shoe: [50, 46, 42] },
  { name: "slate",  skin: [118, 82, 62],   hair: [66, 62, 70],  shirt: [92, 116, 140],  pants: [46, 50, 60],  shoe: [36, 38, 44] },
];

function drawChar(s, dir, frame, p) {
  // frames 0/2 are the neutral contact pose; 1 and 3 are the two stride extremes
  const swing = frame === 1 ? 1 : frame === 3 ? -1 : 0;
  const bob = swing !== 0 ? -1 : 0;

  const skinLo = shade(p.skin, 0.86);
  const shirtLo = shade(p.shirt, 0.82);
  const hairLo = shade(p.hair, 0.8);

  s.ellipse(16, 37, 8, 3, [0, 0, 0, 55]); // ground shadow stays put while the body bobs

  const top = bob;

  // ---- legs ----------------------------------------------------------------
  if (dir === "left" || dir === "right") {
    const d = dir === "left" ? -1 : 1;
    // back leg then front leg, so the front one overlaps
    s.rect(15 - swing * 2 * d, 29 + top, 4, 7, shade(p.pants, 0.85));
    s.rect(14 - swing * 2 * d, 35 + top, 6, 3, shade(p.shoe, 0.85));
    s.rect(13 + swing * 2 * d, 29 + top, 4, 7, p.pants);
    s.rect(12 + swing * 2 * d, 35 + top, 6, 3, p.shoe);
  } else {
    const l = swing > 0 ? -1 : 0;
    const r = swing < 0 ? -1 : 0;
    s.rect(11, 29 + top + l, 4, 7 - l, p.pants);
    s.rect(11, 36 + top, 4, 3, p.shoe);
    s.rect(17, 29 + top + r, 4, 7 - r, p.pants);
    s.rect(17, 36 + top, 4, 3, p.shoe);
  }

  // ---- torso ---------------------------------------------------------------
  s.roundRect(10, 19 + top, 12, 11, 2, p.shirt);
  s.hline(10, 19 + top, 12, shade(p.shirt, 1.12));
  if (dir === "up") s.rect(10, 24 + top, 12, 2, shirtLo);

  // ---- arms (swing opposite the legs) --------------------------------------
  if (dir === "left" || dir === "right") {
    const d = dir === "left" ? -1 : 1;
    s.rect(13 - swing * 2 * d, 20 + top, 4, 7, shirtLo);
    s.rect(13 - swing * 2 * d, 27 + top, 4, 3, skinLo);
  } else {
    s.rect(7, 20 + top - (swing > 0 ? 1 : 0), 4, 7, p.shirt);
    s.rect(7, 27 + top - (swing > 0 ? 1 : 0), 4, 3, p.skin);
    s.rect(21, 20 + top - (swing < 0 ? 1 : 0), 4, 7, p.shirt);
    s.rect(21, 27 + top - (swing < 0 ? 1 : 0), 4, 3, p.skin);
  }

  // ---- head ----------------------------------------------------------------
  const hy = 7 + top;
  s.roundRect(10, hy, 12, 13, 3, p.skin);
  s.rect(10, hy + 12, 12, 1, skinLo); // jawline

  // hair: a cap that wraps further around for the back view
  s.roundRect(9, hy - 1, 14, 7, 3, p.hair);
  if (dir === "up") {
    s.roundRect(9, hy - 1, 14, 13, 3, p.hair);
    s.rect(10, hy + 9, 12, 3, hairLo);
  } else if (dir === "left") {
    s.rect(9, hy - 1, 4, 10, p.hair);
  } else if (dir === "right") {
    s.rect(19, hy - 1, 4, 10, p.hair);
  } else {
    s.rect(9, hy + 1, 2, 7, p.hair);
    s.rect(21, hy + 1, 2, 7, p.hair);
  }

  // ---- face ----------------------------------------------------------------
  const eye = [38, 34, 40];
  if (dir === "down") {
    s.rect(12, hy + 7, 2, 2, eye);
    s.rect(18, hy + 7, 2, 2, eye);
    s.hline(15, hy + 11, 2, skinLo);
  } else if (dir === "left") {
    s.rect(11, hy + 7, 2, 2, eye);
  } else if (dir === "right") {
    s.rect(19, hy + 7, 2, 2, eye);
  }
}

export function buildAvatars() {
  const sheet = new Surface(FRAMES * FW, PALETTES.length * DIRS.length * FH);
  PALETTES.forEach((p, pi) => {
    DIRS.forEach((dir, di) => {
      for (let f = 0; f < FRAMES; f++) {
        const cell = new Surface(FW, FH);
        drawChar(cell, dir, f, p);
        sheet.blit(cell, f * FW, (pi * DIRS.length + di) * FH);
      }
    });
  });
  return sheet;
}
