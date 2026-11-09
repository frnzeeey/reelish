// Generates Sovereign Crest, the Founder Collection's launcher icon
// (Settings > Appearance > App icon, shown to the Founder only): the Reelish
// logo (assets/icons/logo_icon.png) recoloured in champagne gold, wearing the
// Founder Collection's crown (sovereign_shared.mjs), inside a champagne laurel
// wreath, on obsidian with a restrained midnight-violet glow.
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_sovereign_crest.mjs
//
// The gold fills the clean mark (tool/branding/launcher_monochrome.png, the
// logo without its shadow, on the same canvas); logo_icon.png's own soft
// shadow is kept underneath in dark ink, so the depth of the original stays.
// Writes:
//   android/app/src/main/res/drawable-nodpi/ic_launcher_foreground_sovereign_crest.png
//       the 432 px (108 dp at xxxhdpi) foreground: wreath, crown and gold logo
//   android/app/src/main/res/drawable-nodpi/ic_launcher_monochrome_sovereign_crest.png
//       their silhouette, for themed icons on Android 13 and later
//   android/app/src/main/res/drawable-nodpi/ic_launcher_background_sovereign_crest.png
//       the obsidian background and its glow
//   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_sovereign_crest.xml
//       the adaptive icon
//   android/app/src/main/res/mipmap-<density>/ic_launcher_sovereign_crest.png
//       the visible icon, for launchers without adaptive icons
//   assets/images/app_icons/sovereign_crest.png
//       a 192 px preview for the settings screen
//   tool/branding/sovereign_crest.ico
//       16 to 256 px, for Windows (not wired in: Windows embeds one icon in
//       Reelish.exe for everyone, so a Founder-only icon cannot replace it)
//
// The wreath is sized to stay inside the 66 dp safe zone, and the crown and
// mark to keep some room inside the wreath (both measured on the rendered
// pixels below), so no mask shape cuts it. The visible icon and
// preview are the middle two thirds of the 108 dp canvas, as a launcher's
// mask shows it.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { crownHeight, drawCrown, hexColor, metal, palette } from './sovereign_shared.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const require = createRequire(join(root, 'tool', 'icons', 'package.json'));
const CanvasKitInit = require('canvaskit-wasm');
const CK = await CanvasKitInit();

const id = 'sovereign_crest';
const res = join(root, 'android', 'app', 'src', 'main', 'res');
const previews = join(root, 'assets', 'images', 'app_icons');
const branding = join(root, 'tool', 'branding');
const size = 432;
const densities = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

const logo = CK.MakeImageFromEncoded(readFileSync(join(root, 'assets', 'icons', 'logo_icon.png')));
const clean = CK.MakeImageFromEncoded(readFileSync(join(branding, 'launcher_monochrome.png')));

// Placement in the logo's own 846 px space: the mark spans about x 178-668,
// y 242-602, the R alone x 263-668. The crown sits on the R, centred over it
// (not over the whole mark, whose dot would pull it left), a little narrower
// than the R's bowl so the letter stays the subject. Its base keeps 12 px
// above the R.
const crownWidth = 236;
const crown = {
  left: 465 - crownWidth / 2,
  top: 230 - crownHeight(crownWidth),
  width: crownWidth,
};
// The group of crown and mark, centred on the wreath: its box, nudged a
// little toward the R, so the crown sits close to the wreath's axis.
const content = { x: (178 + 668) / 2 + 14, y: (crown.top + 602) / 2 };
// The safe zone's radius at 432 px (33 dp), less a little room for shadows.
const safe = 132 - 12;
// Room between the artwork and the wreath's inner leaves, at 432 px.
const breathing = 8;
// The share of the room inside the wreath the crown and mark reach to, so
// they read as a crest, not as a logo squeezed into a ring.
const share = 0.78;

/** Draws the artwork in logo space; the caller sets the transform. */
function paintArtwork(canvas, { mono = false } = {}) {
  if (mono) {
    canvas.drawImage(clean, 0, 0, null);
    drawCrown(CK, canvas, crown.left, crown.top, crown.width, { ink: CK.Color(255, 255, 255, 1) });
    return;
  }
  // logo_icon's shadow, in ink.
  const ink = new CK.Paint();
  ink.setColorFilter(CK.ColorFilter.MakeBlend(CK.Color(0, 0, 0, 0.55), CK.BlendMode.SrcIn));
  canvas.drawImage(logo, 0, 0, ink);
  ink.delete();
  drawCrown(CK, canvas, crown.left, crown.top, crown.width);
  // The clean mark, filled with metal.
  canvas.saveLayer(null, null, null, 0);
  canvas.drawImage(clean, 0, 0, null);
  const gold = new CK.Paint();
  gold.setShader(metal(CK, [178, 240], [668, 605]));
  gold.setBlendMode(CK.BlendMode.SrcIn);
  canvas.drawRect(CK.XYWHRect(0, 0, 846, 846), gold);
  gold.delete();
  canvas.restore();
}

function snapshot(draw, width, height = width) {
  const surface = CK.MakeSurface(width, height);
  draw(surface.getCanvas());
  surface.flush();
  const image = surface.makeImageSnapshot();
  surface.delete();
  return image;
}

/** The crown and mark at [scale] (logo px to icon px), centred on the canvas. */
const artworkAt = (scale, options) => snapshot((c) => {
  c.clear(CK.Color(0, 0, 0, 0));
  c.translate(size / 2, size / 2);
  c.scale(scale, scale);
  c.translate(-content.x, -content.y);
  paintArtwork(c, options);
}, size);

/** A laurel leaf: a pointed oval from [base] along [direction] (radians), the
 *  same shape as the Founder's profile frame (_LaurelPainter). */
function addLeaf(path, [x, y], direction, length, width) {
  const d = [Math.cos(direction), Math.sin(direction)];
  const n = [-d[1], d[0]];
  const mid = [x + d[0] * length / 2, y + d[1] * length / 2];
  path.moveTo(x, y);
  path.quadTo(mid[0] + n[0] * width, mid[1] + n[1] * width, x + d[0] * length, y + d[1] * length);
  path.quadTo(mid[0] - n[0] * width, mid[1] - n[1] * width, x, y);
  path.close();
}

/**
 * The wreath round the crown and mark, at [s] (1 is a 100 px stem circle):
 * two branches from the foot, their stems crossing there, rising either side
 * with pairs of leaves leaning toward the tips, which stop short of the top
 * and leave the crown its opening.
 */
const wreathAt = (s, { mono = false } = {}) => snapshot((c) => {
  c.clear(CK.Color(0, 0, 0, 0));
  const cx = size / 2;
  const cy = size / 2;
  const radius = 100 * s;
  const on = (degrees) => [
    cx + Math.cos(degrees * Math.PI / 180) * radius,
    cy + Math.sin(degrees * Math.PI / 180) * radius,
  ];
  const stems = new CK.Path();
  const leaves = new CK.Path();
  for (const [from, to] of [[80, 254], [100, -74]]) {
    const sign = Math.sign(to - from);
    stems.moveTo(...on(from));
    for (let i = 1; i <= 40; i++) stems.lineTo(...on(from + (to - from) * i / 40));
    // Leaves start past the crossing, so the foot stays clean.
    const start = from + sign * 14;
    const pairs = 7;
    for (let i = 0; i < pairs; i++) {
      const t = (i + 0.5) / pairs;
      const at = start + (to - start) * t;
      const forward = at * Math.PI / 180 + sign * Math.PI / 2;
      const grow = 1 - t * 0.28;
      addLeaf(leaves, on(at), forward - sign * 0.66, 38 * s * grow, 13 * s * grow);
      addLeaf(leaves, on(at), forward + sign * 0.42, 24 * s * grow, 9 * s * grow);
    }
    addLeaf(leaves, on(to), to * Math.PI / 180 + sign * Math.PI / 2, 28 * s, 10 * s);
  }
  const line = new CK.Paint();
  line.setAntiAlias(true);
  line.setStyle(CK.PaintStyle.Stroke);
  line.setStrokeCap(CK.StrokeCap.Round);
  line.setStrokeWidth(5.5 * s);
  const fill = new CK.Paint();
  fill.setAntiAlias(true);
  if (mono) {
    line.setColor(CK.Color(255, 255, 255, 1));
    fill.setColor(CK.Color(255, 255, 255, 1));
  } else {
    // The crown's soft shadow, so the wreath sits at the same depth.
    const shadow = new CK.Paint();
    shadow.setAntiAlias(true);
    shadow.setColor(CK.Color(0, 0, 0, 0.38));
    shadow.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 3 * s, true));
    c.save();
    c.translate(1.5 * s, 3 * s);
    c.drawPath(leaves, shadow);
    shadow.setStyle(CK.PaintStyle.Stroke);
    shadow.setStrokeWidth(5.5 * s);
    c.drawPath(stems, shadow);
    c.restore();
    shadow.delete();
    const shader = metal(CK, [cx - radius, cy - radius], [cx + radius, cy + radius]);
    line.setShader(shader);
    fill.setShader(shader);
  }
  c.drawPath(stems, line);
  c.drawPath(leaves, fill);
  [line, fill].forEach((p) => p.delete());
  [stems, leaves].forEach((p) => p.delete());
}, size);

/** Each visible pixel's distance from the centre: [nearest, farthest]. */
function extent(image) {
  const pixels = image.readPixels(0, 0, {
    width: size, height: size, colorType: CK.ColorType.RGBA_8888,
    alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB,
  });
  let near = Infinity;
  let far = 0;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (pixels[(y * size + x) * 4 + 3] > 40) {
        const d = Math.hypot(x + 0.5 - size / 2, y + 0.5 - size / 2);
        near = Math.min(near, d);
        far = Math.max(far, d);
      }
    }
  }
  return [near, far];
}

// The largest wreath that stays inside the safe zone, then the largest
// artwork that keeps its breathing room inside the wreath.
let wreathScale = 1.3;
let wreath = wreathAt(wreathScale);
while (extent(wreath)[1] > safe) {
  wreath.delete();
  wreathScale -= 0.01;
  wreath = wreathAt(wreathScale);
}
const inside = (extent(wreath)[0] - breathing) * share;
let scale = 0.5;
let artwork = artworkAt(scale);
while (extent(artwork)[1] > inside) {
  artwork.delete();
  scale -= 0.005;
  artwork = artworkAt(scale);
}
const layered = (...images) => snapshot((c) => {
  c.clear(CK.Color(0, 0, 0, 0));
  for (const image of images) c.drawImage(image, 0, 0, null);
}, size);
const foreground = layered(wreath, artwork);
const monoWreath = wreathAt(wreathScale, { mono: true });
const monoArtwork = artworkAt(scale, { mono: true });
const monochrome = layered(monoWreath, monoArtwork);
[wreath, artwork, monoWreath, monoArtwork].forEach((i) => i.delete());

function paintBackground(canvas) {
  const rect = CK.XYWHRect(0, 0, size, size);
  const fill = (shader) => {
    const paint = new CK.Paint();
    paint.setShader(shader);
    canvas.drawRect(rect, paint);
    paint.delete();
  };
  fill(CK.Shader.MakeLinearGradient([0, 0], [size, size],
    palette.obsidian.map((c) => hexColor(CK, c)), [0, 0.55, 1], CK.TileMode.Clamp));
  const glow = (x, y, radius, color, alpha) => {
    const c = hexColor(CK, color, alpha);
    fill(CK.Shader.MakeRadialGradient([x, y], radius,
      [c, CK.Color4f(c[0], c[1], c[2], 0)], null, CK.TileMode.Clamp));
  };
  // Midnight violet behind the mark, and a soft champagne light on it.
  glow(size * 0.5, size * 0.52, size * 0.4, palette.violet, 0.26);
  glow(size * 0.5, size * 0.46, size * 0.24, palette.champagne, 0.1);
}

function save(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

const generated = 'Generated by tool/branding/generate_sovereign_crest.mjs.';
const nodpi = join(res, 'drawable-nodpi');
save(join(nodpi, `ic_launcher_foreground_${id}.png`), foreground.encodeToBytes());
save(join(nodpi, `ic_launcher_monochrome_${id}.png`), monochrome.encodeToBytes());
const background = snapshot(paintBackground, size);
save(join(nodpi, `ic_launcher_background_${id}.png`), background.encodeToBytes());
save(join(res, 'mipmap-anydpi-v26', `ic_launcher_${id}.xml`), `<?xml version="1.0" encoding="utf-8"?>
<!-- ${generated} -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_background_${id}"/>
  <foreground android:drawable="@drawable/ic_launcher_foreground_${id}"/>
  <monochrome android:drawable="@drawable/ic_launcher_monochrome_${id}"/>
</adaptive-icon>
`);

const composed = snapshot((c) => {
  c.drawImage(background, 0, 0, null);
  c.drawImage(foreground, 0, 0, null);
}, size);

// The visible middle two thirds, on a rounded tile like the other presets.
const visible = CK.XYWHRect(size / 6, size / 6, size * 2 / 3, size * 2 / 3);
const tile = (pixels, radius = 0.22) => snapshot((c) => {
  c.clipRRect(CK.RRectXY(CK.XYWHRect(0, 0, pixels, pixels), pixels * radius, pixels * radius),
    CK.ClipOp.Intersect, true);
  c.drawImageRectCubic(composed, visible, CK.XYWHRect(0, 0, pixels, pixels), 1 / 3, 1 / 3, null);
}, pixels);
for (const [density, pixels] of Object.entries(densities)) {
  const image = tile(pixels);
  save(join(res, `mipmap-${density}`, `ic_launcher_${id}.png`), image.encodeToBytes());
  image.delete();
}
const preview = tile(192);
save(join(previews, `${id}.png`), preview.encodeToBytes());
preview.delete();

// Windows: one .ico holding a PNG per size (supported since Windows Vista).
const pngs = icoSizes.map((pixels) => {
  const image = tile(pixels, 0.18);
  const bytes = Buffer.from(image.encodeToBytes());
  image.delete();
  return [pixels, bytes];
});
const header = Buffer.alloc(6 + 16 * pngs.length);
header.writeUInt16LE(0, 0);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(pngs.length, 4);
let offset = header.length;
pngs.forEach(([pixels, bytes], i) => {
  const entry = 6 + 16 * i;
  header.writeUInt8(pixels >= 256 ? 0 : pixels, entry);
  header.writeUInt8(pixels >= 256 ? 0 : pixels, entry + 1);
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(bytes.length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += bytes.length;
});
save(join(branding, `${id}.ico`), Buffer.concat([header, ...pngs.map(([, b]) => b)]));

[composed, background, foreground, monochrome, logo, clean].forEach((i) => i.delete());
console.log(`founder ${id} (wreath at ${wreathScale.toFixed(2)}, artwork at ${scale.toFixed(3)} of the logo)`);
