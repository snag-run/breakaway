// Minimal dependency-free PNG encoder (RGBA8) + a tiny pixel drawing surface.
import zlib from "node:zlib";

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

export class Surface {
  constructor(w, h) {
    this.w = w;
    this.h = h;
    this.data = new Uint8Array(w * h * 4); // transparent
  }

  px(x, y, color) {
    x |= 0;
    y |= 0;
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    if (!color) return;
    const [r, g, b, a = 255] = color;
    if (a === 0) return;
    const i = (y * this.w + x) * 4;
    if (a === 255) {
      this.data[i] = r; this.data[i + 1] = g; this.data[i + 2] = b; this.data[i + 3] = 255;
      return;
    }
    // source-over alpha blend
    const sa = a / 255;
    const da = this.data[i + 3] / 255;
    const oa = sa + da * (1 - sa);
    if (oa === 0) return;
    this.data[i] = Math.round((r * sa + this.data[i] * da * (1 - sa)) / oa);
    this.data[i + 1] = Math.round((g * sa + this.data[i + 1] * da * (1 - sa)) / oa);
    this.data[i + 2] = Math.round((b * sa + this.data[i + 2] * da * (1 - sa)) / oa);
    this.data[i + 3] = Math.round(oa * 255);
  }

  rect(x, y, w, h, color) {
    for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) this.px(x + i, y + j, color);
    return this;
  }

  outline(x, y, w, h, color) {
    for (let i = 0; i < w; i++) { this.px(x + i, y, color); this.px(x + i, y + h - 1, color); }
    for (let j = 0; j < h; j++) { this.px(x, y + j, color); this.px(x + w - 1, y + j, color); }
    return this;
  }

  hline(x, y, w, color) { for (let i = 0; i < w; i++) this.px(x + i, y, color); return this; }
  vline(x, y, h, color) { for (let j = 0; j < h; j++) this.px(x, y + j, color); return this; }

  // Filled ellipse, useful for plants / rounded blobs.
  ellipse(cx, cy, rx, ry, color) {
    for (let y = -ry; y <= ry; y++) {
      for (let x = -rx; x <= rx; x++) {
        if ((x * x) / (rx * rx) + (y * y) / (ry * ry) <= 1) this.px(cx + x, cy + y, color);
      }
    }
    return this;
  }

  // Rounded rectangle by corner clipping — keeps the pixel-art silhouette soft.
  roundRect(x, y, w, h, r, color) {
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < w; i++) {
        const dx = Math.min(i, w - 1 - i);
        const dy = Math.min(j, h - 1 - j);
        if (dx < r && dy < r) {
          const ox = r - 1 - dx;
          const oy = r - 1 - dy;
          if (ox * ox + oy * oy > r * r) continue;
        }
        this.px(x + i, y + j, color);
      }
    }
    return this;
  }

  blit(src, dx, dy) {
    for (let y = 0; y < src.h; y++) {
      for (let x = 0; x < src.w; x++) {
        const i = (y * src.w + x) * 4;
        const a = src.data[i + 3];
        if (a) this.px(dx + x, dy + y, [src.data[i], src.data[i + 1], src.data[i + 2], a]);
      }
    }
    return this;
  }

  toPNG() {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(this.w, 0);
    ihdr.writeUInt32BE(this.h, 4);
    ihdr[8] = 8;  // bit depth
    ihdr[9] = 6;  // RGBA
    const raw = Buffer.alloc(this.h * (this.w * 4 + 1));
    for (let y = 0; y < this.h; y++) {
      const off = y * (this.w * 4 + 1);
      raw[off] = 0; // filter: none
      Buffer.from(this.data.buffer, y * this.w * 4, this.w * 4).copy(raw, off + 1);
    }
    return Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk("IHDR", ihdr),
      chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
      chunk("IEND", Buffer.alloc(0)),
    ]);
  }
}

// Deterministic noise so regenerating assets never reshuffles the texture.
export function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

export const shade = ([r, g, b, a = 255], f) => [
  Math.max(0, Math.min(255, Math.round(r * f))),
  Math.max(0, Math.min(255, Math.round(g * f))),
  Math.max(0, Math.min(255, Math.round(b * f))),
  a,
];
