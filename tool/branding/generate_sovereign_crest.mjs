// Generates Sovereign Crest, the Founder Collection's launcher icon
// (Settings > Appearance > App icon, shown to the Founder only): the Reelish
// logo (assets/icons/logo_icon.png) recoloured in champagne gold, wearing the
// Founder Collection's crown (sovereign_shared.mjs), on obsidian with a
// restrained midnight-violet glow.
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_sovereign_crest.mjs
//
// The gold fills the clean mark (tool/branding/launcher_monochrome.png, the
// logo without its shadow, on the same canvas); logo_icon.png's own soft
// shadow is kept underneath in dark ink, so the depth of the original stays.
// Writes:
//   android/app/src/main/res/drawable-nodpi/ic_launcher_foreground_sovereign_crest.png
//       the 432 px (108 dp at xxxhdpi) foreground: crown and gold logo
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
// The artwork is sized to stay inside the 66 dp safe zone (measured on the
// rendered pixels below), so no mask shape cuts it. The visible icon and
// preview are the middle two thirds of the 108 dp canvas, as a launcher's
// mask shows it.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { drawCrown, hexColor, metal, palette } from './sovereign_shared.mjs';

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
// y 240-605, the R alone x 263-668. The crown sits on the R, centred over it
// (not over the whole mark, whose dot would pull it left), and the group of
// crown and mark is centred on the canvas.
const crown = { left: 465 - 146, top: 79, width: 292 };
const content = { x: (178 + 668) / 2, y: (79 + 605) / 2 };
// The safe zone's radius at 432 px (33 dp), less a little room for shadows.
const safe = 132 - 12;

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

/** The foreground at [scale] (logo px to icon px), centred on the canvas. */
const foregroundAt = (scale, options) => snapshot((c) => {
  c.clear(CK.Color(0, 0, 0, 0));
  c.translate(size / 2, size / 2);
  c.scale(scale, scale);
  c.translate(-content.x, -content.y);
  paintArtwork(c, options);
}, size);

/** How far from the centre the artwork's visible pixels reach. */
function reach(image) {
  const pixels = image.readPixels(0, 0, {
    width: size, height: size, colorType: CK.ColorType.RGBA_8888,
    alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB,
  });
  let far = 0;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (pixels[(y * size + x) * 4 + 3] > 40) {
        far = Math.max(far, Math.hypot(x + 0.5 - size / 2, y + 0.5 - size / 2));
      }
    }
  }
  return far;
}

// The largest size whose artwork stays inside the safe zone.
let scale = 0.5;
let foreground = foregroundAt(scale);
while (reach(foreground) > safe) {
  foreground.delete();
  scale -= 0.01;
  foreground = foregroundAt(scale);
}
const monochrome = foregroundAt(scale, { mono: true });

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
console.log(`founder ${id} (artwork at ${scale.toFixed(2)} of the logo)`);
