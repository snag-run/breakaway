#!/usr/bin/env node
// Regenerates every 2D asset plus the atlas manifest that both the Elixir
// server and the browser renderer read. Run with: mix assets.sprites
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildTileset, TILE, COLS as TILE_COLS, TILE_NAMES, SOLID_TILES } from "./tiles.mjs";
import { buildFurniture, CELL, COLS as PROP_COLS, PROP_NAMES, PROP_META } from "./furniture.mjs";
import { buildAvatars, FW, FH, DIRS, FRAMES, COLUMNS, SIT_FRAME, PALETTES } from "./avatars.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../priv/static/images");
fs.mkdirSync(out, { recursive: true });

const write = (name, buf) => {
  fs.writeFileSync(path.join(out, name), buf);
  console.log(`  ${name.padEnd(18)} ${(buf.length / 1024).toFixed(1)} KB`);
};

console.log("generating 2D assets ->", path.relative(process.cwd(), out));
write("tileset.png", buildTileset().toPNG());
write("furniture.png", buildFurniture().toPNG());
write("avatars.png", buildAvatars().toPNG());

const atlas = {
  tiles: {
    src: "/images/tileset.png",
    size: TILE,
    columns: TILE_COLS,
    names: TILE_NAMES,
    index: Object.fromEntries(TILE_NAMES.map((n, i) => [n, i])),
    solid: TILE_NAMES.filter((n) => SOLID_TILES.has(n)),
  },
  props: {
    src: "/images/furniture.png",
    cell: CELL,
    columns: PROP_COLS,
    names: PROP_NAMES,
    meta: PROP_META,
  },
  avatars: {
    src: "/images/avatars.png",
    frameWidth: FW,
    frameHeight: FH,
    frames: FRAMES,
    columns: COLUMNS,
    sitFrame: SIT_FRAME,
    directions: DIRS,
    palettes: PALETTES.map((p) => p.name),
  },
};

const atlasJson = JSON.stringify(atlas, null, 2);
fs.writeFileSync(path.join(out, "atlas.json"), atlasJson);
console.log(`  atlas.json         ${(atlasJson.length / 1024).toFixed(1)} KB`);
console.log("done.");
