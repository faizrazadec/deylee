#!/usr/bin/env node
/**
 * Procedural icon generator for Dayly — see ARCHITECTURE.md §11.
 *
 * Icons are generated rather than committed as binaries so the whole visual
 * language (ring weight, state shapes, accent colours) lives in one readable
 * place and can be re-tuned without a design tool. Everything here is plain
 * Node: a tiny RGBA rasteriser, a PNG encoder built on `zlib.deflateSync`, and
 * an ICO container that embeds those PNGs. No image dependency is installed.
 *
 * Run from the project root:  node scripts/generate-icons.mjs
 */

import { deflateSync, inflateSync } from 'node:zlib';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/* -------------------------------------------------------------------------- */
/* Rasteriser                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * A square RGBA surface with straight (non-premultiplied) alpha.
 *
 * Shapes are tested as hard in/out predicates at 4x resolution and the result is
 * box-filtered down on the way out. Supersampling is what buys the smooth edges —
 * it means no primitive ever has to compute its own coverage, so a circle is
 * literally "distance from centre <= r".
 */
class Canvas {
  constructor(size, supersample = 4) {
    this.size = size;
    this.ss = supersample;
    this.dim = size * supersample;
    this.pixels = new Uint8ClampedArray(this.dim * this.dim * 4);
  }

  /**
   * Composite `paint` wherever `shape` covers. Coordinates handed to both are in
   * logical units (0..size), so a design reads the same at every raster size.
   */
  fill(shape, paint) {
    const { ss, dim, pixels } = this;
    const [bx0, by0, bx1, by1] = shape.bounds;
    const dx0 = Math.max(0, Math.floor(bx0 * ss));
    const dy0 = Math.max(0, Math.floor(by0 * ss));
    const dx1 = Math.min(dim - 1, Math.ceil(bx1 * ss));
    const dy1 = Math.min(dim - 1, Math.ceil(by1 * ss));

    for (let dy = dy0; dy <= dy1; dy += 1) {
      const ly = (dy + 0.5) / ss;
      const rowStart = dy * dim;
      for (let dx = dx0; dx <= dx1; dx += 1) {
        const lx = (dx + 0.5) / ss;
        if (!shape.contains(lx, ly)) continue;
        const colour = paint(lx, ly);
        blend(pixels, (rowStart + dx) * 4, colour);
      }
    }
  }

  /**
   * Box-downsample to the logical size.
   *
   * RGB is averaged *weighted by alpha*, because averaging the colour of fully
   * transparent samples (whose RGB is zero) would fringe every antialiased edge
   * with black.
   */
  toRgba() {
    const { size, ss, dim, pixels } = this;
    const out = Buffer.alloc(size * size * 4);
    const samples = ss * ss;

    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        let sumR = 0;
        let sumG = 0;
        let sumB = 0;
        let sumA = 0;
        for (let sy = 0; sy < ss; sy += 1) {
          let idx = ((y * ss + sy) * dim + x * ss) * 4;
          for (let sx = 0; sx < ss; sx += 1) {
            const a = pixels[idx + 3];
            sumR += pixels[idx] * a;
            sumG += pixels[idx + 1] * a;
            sumB += pixels[idx + 2] * a;
            sumA += a;
            idx += 4;
          }
        }
        if (sumA === 0) continue; // Buffer.alloc already left it transparent.
        const o = (y * size + x) * 4;
        out[o] = Math.round(sumR / sumA);
        out[o + 1] = Math.round(sumG / sumA);
        out[o + 2] = Math.round(sumB / sumA);
        out[o + 3] = Math.round(sumA / samples);
      }
    }
    return out;
  }

  /**
   * The alpha mask only, with colour forced to black — the exact shape macOS
   * expects from a `*Template` image, which it recolours for the menu bar.
   */
  toTemplateRgba() {
    const rgba = this.toRgba();
    for (let i = 0; i < rgba.length; i += 4) {
      rgba[i] = 0;
      rgba[i + 1] = 0;
      rgba[i + 2] = 0;
    }
    return rgba;
  }
}

/** Source-over composite of a straight-alpha colour onto a straight-alpha pixel. */
function blend(pixels, idx, [r, g, b, a]) {
  if (a <= 0) return;
  if (a >= 255) {
    pixels[idx] = r;
    pixels[idx + 1] = g;
    pixels[idx + 2] = b;
    pixels[idx + 3] = 255;
    return;
  }
  const src = a / 255;
  const dst = pixels[idx + 3] / 255;
  const outA = src + dst * (1 - src);
  if (outA <= 0) return;
  const keep = (dst * (1 - src)) / outA;
  const add = src / outA;
  pixels[idx] = r * add + pixels[idx] * keep;
  pixels[idx + 1] = g * add + pixels[idx + 1] * keep;
  pixels[idx + 2] = b * add + pixels[idx + 2] * keep;
  pixels[idx + 3] = outA * 255;
}

/* -------------------------------------------------------------------------- */
/* Shapes — { bounds: [x0, y0, x1, y1], contains(x, y): boolean }              */
/* -------------------------------------------------------------------------- */

function circle(cx, cy, r) {
  const rr = r * r;
  return {
    bounds: [cx - r, cy - r, cx + r, cy + r],
    contains: (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= rr,
  };
}

function ring(cx, cy, outerR, innerR) {
  const outerRR = outerR * outerR;
  const innerRR = innerR * innerR;
  return {
    bounds: [cx - outerR, cy - outerR, cx + outerR, cy + outerR],
    contains: (x, y) => {
      const d = (x - cx) ** 2 + (y - cy) ** 2;
      return d <= outerRR && d >= innerRR;
    },
  };
}

function rect(x0, y0, x1, y1) {
  return {
    bounds: [x0, y0, x1, y1],
    contains: (x, y) => x >= x0 && x <= x1 && y >= y0 && y <= y1,
  };
}

/** Rounded rectangle via the standard "clamp to the inner box, then radius" test. */
function roundedRect(x0, y0, x1, y1, r) {
  const ix0 = x0 + r;
  const iy0 = y0 + r;
  const ix1 = x1 - r;
  const iy1 = y1 - r;
  const rr = r * r;
  return {
    bounds: [x0, y0, x1, y1],
    contains: (x, y) => {
      const qx = Math.min(Math.max(x, ix0), ix1);
      const qy = Math.min(Math.max(y, iy0), iy1);
      return (x - qx) ** 2 + (y - qy) ** 2 <= rr;
    },
  };
}

/** A line segment with round caps — used for the clock hands. */
function capsule(x0, y0, x1, y1, halfWidth) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const lenSq = dx * dx + dy * dy;
  const hw = halfWidth * halfWidth;
  return {
    bounds: [
      Math.min(x0, x1) - halfWidth,
      Math.min(y0, y1) - halfWidth,
      Math.max(x0, x1) + halfWidth,
      Math.max(y0, y1) + halfWidth,
    ],
    contains: (x, y) => {
      let t = lenSq === 0 ? 0 : ((x - x0) * dx + (y - y0) * dy) / lenSq;
      t = t < 0 ? 0 : t > 1 ? 1 : t;
      return (x - (x0 + dx * t)) ** 2 + (y - (y0 + dy * t)) ** 2 <= hw;
    },
  };
}

function intersect(a, b) {
  return {
    bounds: [
      Math.max(a.bounds[0], b.bounds[0]),
      Math.max(a.bounds[1], b.bounds[1]),
      Math.min(a.bounds[2], b.bounds[2]),
      Math.min(a.bounds[3], b.bounds[3]),
    ],
    contains: (x, y) => a.contains(x, y) && b.contains(x, y),
  };
}

/* -------------------------------------------------------------------------- */
/* Paints — (x, y) => [r, g, b, a]                                             */
/* -------------------------------------------------------------------------- */

function solid(colour) {
  return () => colour;
}

function linearGradient(x0, y0, x1, y1, from, to) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const lenSq = dx * dx + dy * dy;
  const out = [0, 0, 0, 0];
  return (x, y) => {
    let t = lenSq === 0 ? 0 : ((x - x0) * dx + (y - y0) * dy) / lenSq;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    for (let i = 0; i < 4; i += 1) out[i] = from[i] + (to[i] - from[i]) * t;
    return out;
  };
}

/**
 * A colour whose alpha falls off quadratically to zero at `radius`.
 *
 * Used for the app icon's highlight: a hard-edged translucent shape would leave a
 * visible arc across the field, which reads as a rendering artefact rather than
 * as light.
 */
function radialFade(cx, cy, radius, rgb, centreAlpha) {
  const out = [rgb[0], rgb[1], rgb[2], 0];
  return (x, y) => {
    const d = Math.sqrt((x - cx) ** 2 + (y - cy) ** 2) / radius;
    const t = d >= 1 ? 0 : 1 - d;
    out[3] = centreAlpha * t * t;
    return out;
  };
}

/* -------------------------------------------------------------------------- */
/* PNG encoding                                                                */
/* -------------------------------------------------------------------------- */

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

let crcTable = null;

function crc32(buf) {
  if (crcTable === null) {
    crcTable = new Int32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c;
    }
  }
  let c = -1;
  for (let i = 0; i < buf.length; i += 1) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function pngChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typed = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typed), 0);
  return Buffer.concat([length, typed, crc]);
}

/**
 * 8-bit RGBA, non-interlaced, every scanline filtered with type 0 (None).
 *
 * Adaptive filtering would compress these flat, mostly-transparent images by a
 * few percent at best; keeping filter 0 makes the output trivially verifiable.
 */
function encodePng(rgba, width, height) {
  const stride = width * 4;
  const raw = Buffer.alloc(height * (stride + 1));
  for (let y = 0; y < height; y += 1) {
    const dest = y * (stride + 1);
    raw[dest] = 0;
    rgba.copy(raw, dest + 1, y * stride, (y + 1) * stride);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type: truecolour with alpha
  ihdr[10] = 0; // compression: deflate
  ihdr[11] = 0; // filter method: adaptive
  ihdr[12] = 0; // interlace: none

  return Buffer.concat([
    PNG_SIGNATURE,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(raw, { level: 9 })),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

/* -------------------------------------------------------------------------- */
/* ICO encoding                                                                */
/* -------------------------------------------------------------------------- */

/**
 * ICONDIR + one ICONDIRENTRY per size, followed by the PNG payloads.
 *
 * PNG-compressed entries (rather than the legacy BMP + AND-mask layout) are read
 * by everything from Vista onwards and by Chromium's decoder, which is what
 * Electron's `nativeImage` uses.
 */
function encodeIco(images) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // type: icon
  header.writeUInt16LE(images.length, 4);

  const directory = Buffer.alloc(16 * images.length);
  let offset = header.length + directory.length;

  images.forEach((image, i) => {
    const o = i * 16;
    // 0 encodes 256 in this single byte; nothing here is that large, but be exact.
    directory[o] = image.size >= 256 ? 0 : image.size;
    directory[o + 1] = image.size >= 256 ? 0 : image.size;
    directory[o + 2] = 0; // palette size — none for 32bpp
    directory[o + 3] = 0; // reserved
    directory.writeUInt16LE(1, o + 4); // colour planes
    directory.writeUInt16LE(32, o + 6); // bits per pixel
    directory.writeUInt32LE(image.png.length, o + 8);
    directory.writeUInt32LE(offset, o + 12);
    offset += image.png.length;
  });

  return Buffer.concat([header, directory, ...images.map((image) => image.png)]);
}

/* -------------------------------------------------------------------------- */
/* Design                                                                      */
/* -------------------------------------------------------------------------- */

const WHITE = [255, 255, 255, 255];
const BLACK = [0, 0, 0, 255];

/** Matches the renderer accent (indigo) so the app icon and the UI agree. */
const INDIGO_LIGHT = [129, 140, 248, 255];
const INDIGO_DEEP = [67, 56, 202, 255];

const STATE_COLOURS = {
  idle: [139, 144, 154, 255], // neutral grey — nothing is being tracked
  running: [34, 197, 94, 255], // green
  paused: [245, 158, 11, 255], // amber
};

/**
 * Every tray glyph is expressed as a fraction of the icon's edge, so 16, 22, 24
 * and 32px renders stay visually identical rather than drifting apart.
 */
const G = {
  ringOuter: 0.42,
  ringThin: 0.085, // idle: a lighter ring, but still ~1.4px at 16 so it survives
  ringThick: 0.1, // running / paused: a heavier ring
  dotRadius: 0.14,
  barHalfWidth: 0.05,
  barHalfHeight: 0.17,
  barOffset: 0.105,
  handHalfWidth: 0.042,
  minuteHandLength: 0.225,
  hourHandLength: 0.17,
};

/**
 * The three tray states differ by **shape**, not just colour: on Windows the icon
 * is the only state indicator (no tray title), and colour alone fails for
 * colour-blind users and on high-contrast themes.
 *
 *   idle    hollow thin ring
 *   running ring + filled centre dot
 *   paused  ring + two vertical bars
 */
function drawTrayState(canvas, state, colour) {
  const s = canvas.size;
  const c = s / 2;
  const outer = s * G.ringOuter;
  const thickness = s * (state === 'idle' ? G.ringThin : G.ringThick);
  const paint = solid(colour);

  canvas.fill(ring(c, c, outer, outer - thickness), paint);

  if (state === 'running') {
    canvas.fill(circle(c, c, s * G.dotRadius), paint);
  } else if (state === 'paused') {
    const bw = s * G.barHalfWidth;
    const bh = s * G.barHalfHeight;
    const off = s * G.barOffset;
    canvas.fill(rect(c - off - bw, c - bh, c - off + bw, c + bh), paint);
    canvas.fill(rect(c + off - bw, c - bh, c + off + bw, c + bh), paint);
  }
}

/** Ring plus two hands — the menu-bar mark. Drawn flat so it can be a template. */
function drawClockGlyph(canvas, colour) {
  const s = canvas.size;
  const c = s / 2;
  const outer = s * G.ringOuter;
  const paint = solid(colour);
  const hw = s * G.handHalfWidth;

  canvas.fill(ring(c, c, outer, outer - s * G.ringThick), paint);
  canvas.fill(capsule(c, c, c, c - s * G.minuteHandLength, hw), paint);
  canvas.fill(capsule(c, c, c + s * G.hourHandLength, c, hw), paint);
}

/**
 * The 1024x1024 app icon. electron-builder derives the `.icns` and `.ico` from
 * this single file, so the size is fixed and the mark has to survive being scaled
 * down to 32px: one bold ring, two thick hands, no fine detail.
 */
function drawAppIcon() {
  const S = 1024;
  const canvas = new Canvas(S, 4);

  const inset = 32;
  const field = roundedRect(inset, inset, S - inset, S - inset, 216);
  canvas.fill(
    field,
    linearGradient(inset, inset, S - inset, S - inset, INDIGO_LIGHT, INDIGO_DEEP),
  );
  // A soft highlight over the top-left keeps the flat gradient from looking like a
  // printed swatch. Clipped to the field so the corners stay clean.
  canvas.fill(intersect(field, circle(230, 120, 900)), radialFade(230, 120, 900, WHITE, 54));

  const c = S / 2;
  const outer = 360;
  const paint = solid(WHITE);
  canvas.fill(ring(c, c, outer, outer - 64), paint);
  canvas.fill(capsule(c, c, c, c - 240, 24), paint);
  canvas.fill(capsule(c, c, c + 168, c, 24), paint);
  canvas.fill(circle(c, c, 38), paint);

  return canvas;
}

/* -------------------------------------------------------------------------- */
/* Verification — read every artefact back off disk                            */
/* -------------------------------------------------------------------------- */

function readPngHeader(buf) {
  if (buf.length < 26) throw new Error('truncated PNG');
  if (!buf.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error('bad PNG signature');
  if (buf.toString('latin1', 12, 16) !== 'IHDR') throw new Error('first chunk is not IHDR');
  return {
    width: buf.readUInt32BE(16),
    height: buf.readUInt32BE(20),
    bitDepth: buf[24],
    colourType: buf[25],
  };
}

/** Decodes only what this script emits: 8-bit RGBA with every scanline filter 0. */
function decodePng(buf) {
  const header = readPngHeader(buf);
  if (header.bitDepth !== 8 || header.colourType !== 6) {
    throw new Error(`expected 8-bit RGBA, got depth ${header.bitDepth} type ${header.colourType}`);
  }

  const idat = [];
  let pos = 8;
  while (pos + 8 <= buf.length) {
    const length = buf.readUInt32BE(pos);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    if (type === 'IDAT') idat.push(buf.subarray(pos + 8, pos + 8 + length));
    if (type === 'IEND') break;
    pos += 12 + length;
  }

  const raw = inflateSync(Buffer.concat(idat));
  const stride = header.width * 4;
  const data = Buffer.alloc(header.height * stride);
  for (let y = 0; y < header.height; y += 1) {
    const src = y * (stride + 1);
    if (raw[src] !== 0) throw new Error(`unexpected scanline filter ${raw[src]}`);
    raw.copy(data, y * stride, src + 1, src + 1 + stride);
  }
  return { ...header, data };
}

function readIco(buf) {
  if (buf.length < 6) throw new Error('truncated ICO');
  if (buf.readUInt16LE(0) !== 0) throw new Error('ICONDIR reserved field is not 0');
  if (buf.readUInt16LE(2) !== 1) throw new Error('ICONDIR type is not 1 (icon)');
  const count = buf.readUInt16LE(4);
  if (count === 0) throw new Error('ICONDIR declares no images');

  const entries = [];
  for (let i = 0; i < count; i += 1) {
    const o = 6 + i * 16;
    const declaredW = buf[o] === 0 ? 256 : buf[o];
    const declaredH = buf[o + 1] === 0 ? 256 : buf[o + 1];
    const bytes = buf.readUInt32LE(o + 8);
    const offset = buf.readUInt32LE(o + 12);
    if (offset + bytes > buf.length) throw new Error(`entry ${i} points past end of file`);
    const png = readPngHeader(buf.subarray(offset, offset + bytes));
    if (png.width !== declaredW || png.height !== declaredH) {
      throw new Error(
        `entry ${i} declares ${declaredW}x${declaredH} but the PNG is ${png.width}x${png.height}`,
      );
    }
    entries.push({ size: declaredW, bytes });
  }
  return entries;
}

/* -------------------------------------------------------------------------- */
/* Emit                                                                        */
/* -------------------------------------------------------------------------- */

const written = [];

function write(relPath, buffer, note) {
  const absolute = join(ROOT, relPath);
  mkdirSync(dirname(absolute), { recursive: true });
  writeFileSync(absolute, buffer);
  written.push({ path: relPath, absolute, note });
}

function trayCanvas(size, state, colour) {
  const canvas = new Canvas(size, 4);
  drawTrayState(canvas, state, colour);
  return canvas;
}

const TRAY_STATES = ['idle', 'running', 'paused'];
const WIN_ICO_SIZES = [16, 24, 32];
/** 22 is the GNOME/KDE status-icon size; 24 and 32 cover denser panel themes. */
const LINUX_SIZES = [
  { size: 22, suffix: '' },
  { size: 24, suffix: '@24' },
  { size: 32, suffix: '@32' },
];

function generate() {
  // App icon.
  const app = drawAppIcon();
  write('build/icon.png', encodePng(app.toRgba(), app.size, app.size), '1024x1024 app icon');

  // macOS menu-bar template icons: black + alpha only, since macOS recolours them
  // for light/dark menu bars and for the highlighted (clicked) state.
  for (const [name, size] of [
    ['trayTemplate.png', 16],
    ['trayTemplate@2x.png', 32],
  ]) {
    const canvas = new Canvas(size, 4);
    drawClockGlyph(canvas, BLACK);
    write(
      `resources/tray/mac/${name}`,
      encodePng(canvas.toTemplateRgba(), size, size),
      `${size}x${size} template`,
    );
  }

  // Windows: one multi-size .ico per state.
  for (const state of TRAY_STATES) {
    const images = WIN_ICO_SIZES.map((size) => {
      const canvas = trayCanvas(size, state, STATE_COLOURS[state]);
      return { size, png: encodePng(canvas.toRgba(), size, size) };
    });
    write(
      `resources/tray/win/${state}.ico`,
      encodeIco(images),
      `${WIN_ICO_SIZES.join('/')} px ${state}`,
    );
  }

  // Linux: plain PNGs, one file per state and size.
  for (const state of TRAY_STATES) {
    for (const { size, suffix } of LINUX_SIZES) {
      const canvas = trayCanvas(size, state, STATE_COLOURS[state]);
      write(
        `resources/tray/linux/${state}${suffix}.png`,
        encodePng(canvas.toRgba(), size, size),
        `${size}x${size} ${state}`,
      );
    }
  }
}

function verify() {
  const problems = [];

  const check = (entry, expectation) => {
    try {
      expectation(readFileSync(entry.absolute));
    } catch (error) {
      problems.push(`${entry.path}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  for (const entry of written) {
    if (entry.path.endsWith('.ico')) {
      check(entry, (buf) => {
        const entries = readIco(buf);
        const sizes = entries.map((e) => e.size);
        if (sizes.join(',') !== WIN_ICO_SIZES.join(',')) {
          throw new Error(`expected sizes ${WIN_ICO_SIZES.join(',')}, got ${sizes.join(',')}`);
        }
      });
      continue;
    }

    const expectedSize = entry.path === 'build/icon.png' ? 1024 : expectedPngSize(entry.path);
    check(entry, (buf) => {
      const png = decodePng(buf);
      if (png.width !== expectedSize || png.height !== expectedSize) {
        throw new Error(`expected ${expectedSize}x${expectedSize}, got ${png.width}x${png.height}`);
      }
      if (png.bitDepth !== 8 || png.colourType !== 6) throw new Error('not 8-bit RGBA');
      if (entry.path.includes('/mac/')) {
        let opaqueSamples = 0;
        for (let i = 0; i < png.data.length; i += 4) {
          if (png.data[i] !== 0 || png.data[i + 1] !== 0 || png.data[i + 2] !== 0) {
            throw new Error('template icon has non-black pixels');
          }
          if (png.data[i + 3] > 0) opaqueSamples += 1;
        }
        if (opaqueSamples === 0) throw new Error('template icon is fully transparent');
      }
    });
  }

  return problems;
}

function expectedPngSize(relPath) {
  if (relPath.includes('/mac/')) return relPath.includes('@2x') ? 32 : 16;
  if (relPath.includes('@24')) return 24;
  if (relPath.includes('@32')) return 32;
  return 22;
}

function report(problems) {
  const width = written.reduce((max, e) => Math.max(max, e.path.length), 0);
  process.stdout.write('\nDayly icons\n');
  for (const entry of written) {
    const bytes = readFileSync(entry.absolute).length;
    process.stdout.write(
      `  ${entry.path.padEnd(width)}  ${String(bytes).padStart(8)} B  ${entry.note}\n`,
    );
  }

  if (problems.length > 0) {
    process.stdout.write(`\n${problems.length} verification failure(s):\n`);
    for (const problem of problems) process.stdout.write(`  ${problem}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    `\n${written.length} files written and verified (PNG signature, IHDR dimensions, ICONDIR header).\n`,
  );
}

generate();
report(verify());
