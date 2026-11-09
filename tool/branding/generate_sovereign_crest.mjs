// Generates Sovereign Crest, the Founder Collection's launcher icon
// (Settings > Appearance > App icon, shown to the Founder only). Its mark is
// its own: a geometric Reelish R whose top edge rises into three crown points,
// the stem's outer edge running straight up into the first, so the crown is
// the letter and not a crown set above it. Champagne gold on obsidian, with a
// faint midnight-violet light behind it (the Sovereign Edition theme).
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_sovereign_crest.mjs
//
// The mark is one SVG path in the adaptive icon's 108 dp viewport (MARK), so
// the launcher layers are vectors and stay crisp at every size. Writes:
//   android/app/src/main/res/drawable/ic_launcher_foreground_sovereign_crest.xml
//       the mark as a VectorDrawable, in a champagne metallic gradient
//   android/app/src/main/res/drawable/ic_launcher_monochrome_sovereign_crest.xml
//       the same mark in one colour, for themed icons on Android 13 and later
//   android/app/src/main/res/drawable-nodpi/ic_launcher_background_sovereign_crest.png
//       the 432 px (108 dp at xxxhdpi) obsidian background and its violet light
//   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_sovereign_crest.xml
//       the adaptive icon
//   android/app/src/main/res/mipmap-<density>/ic_launcher_sovereign_crest.png
//       the visible icon, for launchers without adaptive icons
//   assets/images/app_icons/sovereign_crest.png
//       a 192 px preview for the settings screen
//   tool/branding/sovereign_crest.svg
//       the whole icon as one vector, for reference and other uses
//
// The mark keeps inside the 66 dp safe zone (checked below), so no mask shape
// cuts it. The visible icon and preview are the middle two thirds of the
// 108 dp canvas, as a launcher's mask shows it.
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const require = createRequire(join(root, 'tool', 'icons', 'package.json'));
const CanvasKitInit = require('canvaskit-wasm');
const CK = await CanvasKitInit();

const id = 'sovereign_crest';
const res = join(root, 'android', 'app', 'src', 'main', 'res');
const previews = join(root, 'assets', 'images', 'app_icons');
const size = 432;
const scale = size / 108;
const densities = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };

// The monogram in the 108 dp viewport, before [fit]: the stem and its crown
// point, two more points across the top, the bowl and its counter, the leg.
const MARK =
  'M34 79 L34 27 L41.5 35 L48.5 25 L55.5 35 L63 27.5 ' +
  'C78 33 79 55.5 65 61.2 L76.5 79 L66.8 79 L55.8 62 L42 62 L42 79 Z ' +
  'M42 44 L61 44 C67 44 67 54 61 54 L42 54 Z';

// Scaled about the centre so its outermost point stays inside the safe zone.
const fit = 0.84;

const palette = {
  // Champagne, lit from the upper left: highlight, body, shadow, the
  // returning light along the leg, and its foot.
  metal: [
    [0, '#F7E9C4'],
    [0.32, '#DCC08A'],
    [0.6, '#AF8D52'],
    [0.82, '#DEC48F'],
    [1, '#B9975C'],
  ],
  obsidian: ['#15122A', '#0B0B16', '#07070D'],
  violet: '#A78BFA',
  champagne: '#D6B779',
};

const hex = (value, alpha = 1) => {
  const n = parseInt(value.slice(1), 16);
  return CK.Color((n >> 16) & 255, (n >> 8) & 255, n & 255, alpha);
};

/** The mark in viewport units, fitted, as an SVG path string. */
function markPath() {
  const path = CK.Path.MakeFromSVGString(MARK);
  path.transform(CK.Matrix.multiply(
    CK.Matrix.translated(54, 54),
    CK.Matrix.scaled(fit, fit),
    CK.Matrix.translated(-54, -54),
  ));
  if (!insideSafeZone(path)) {
    throw new Error('Sovereign Crest mark leaves the 66 dp safe zone');
  }
  const bounds = path.getBounds();
  const svg = path.toSVGString();
  path.delete();
  return { svg, bounds };
}

/** Whether every point of the outline is within the 33 dp safe radius. */
function insideSafeZone(path) {
  const iter = new CK.ContourMeasureIter(path, false, 1);
  for (let contour = iter.next(); contour; contour = iter.next()) {
    for (let d = 0; d <= contour.length(); d += 0.25) {
      const [x, y] = contour.getPosTan(d);
      if (Math.hypot(x - 54, y - 54) > 33) return false;
    }
    contour.delete();
  }
  iter.delete();
  return true;
}

const { svg: markSvg, bounds } = markPath();
// The metal runs from the mark's upper left to its lower right.
const metalFrom = [bounds[0], bounds[1]];
const metalTo = [bounds[2], bounds[3]];

function paintBackground(canvas) {
  const rect = CK.XYWHRect(0, 0, size, size);
  const fill = (shader) => {
    const paint = new CK.Paint();
    paint.setShader(shader);
    canvas.drawRect(rect, paint);
    paint.delete();
  };
  fill(CK.Shader.MakeLinearGradient([0, 0], [size, size],
    palette.obsidian.map((c) => hex(c)), [0, 0.55, 1], CK.TileMode.Clamp));
  const glow = (x, y, radius, color) => fill(CK.Shader.MakeRadialGradient(
    [x, y], radius, [color, CK.Color4f(color[0], color[1], color[2], 0)],
    null, CK.TileMode.Clamp));
  // Midnight violet behind the mark, and a trace of champagne from above.
  glow(size * 0.5, size * 0.54, size * 0.42, hex(palette.violet, 0.24));
  glow(size * 0.3, size * 0.24, size * 0.45, hex(palette.champagne, 0.08));
}

function paintMark(canvas) {
  const path = CK.Path.MakeFromSVGString(markSvg);
  path.setFillType(CK.FillType.EvenOdd);
  path.transform(CK.Matrix.scaled(scale, scale));
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setShader(CK.Shader.MakeLinearGradient(
    metalFrom.map((v) => v * scale), metalTo.map((v) => v * scale),
    palette.metal.map(([, c]) => hex(c)), palette.metal.map(([o]) => o),
    CK.TileMode.Clamp));
  canvas.drawPath(path, paint);
  paint.delete();
  path.delete();
}

function snapshot(draw, width, height = width) {
  const surface = CK.MakeSurface(width, height);
  draw(surface.getCanvas());
  surface.flush();
  const image = surface.makeImageSnapshot();
  surface.delete();
  return image;
}

function save(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

const generated = 'Generated by tool/branding/generate_sovereign_crest.mjs.';
const metalItems = palette.metal
  .map(([offset, color]) => `                <item android:offset="${offset}" android:color="#FF${color.slice(1)}"/>`)
  .join('\n');
const vector = (fill) => `<?xml version="1.0" encoding="utf-8"?>
<!-- ${generated} -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillType="evenOdd"
        android:pathData="${markSvg}"${fill}
</vector>
`;

save(join(res, 'drawable', `ic_launcher_foreground_${id}.xml`), vector(`>
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="${metalFrom[0].toFixed(2)}"
                android:startY="${metalFrom[1].toFixed(2)}"
                android:endX="${metalTo[0].toFixed(2)}"
                android:endY="${metalTo[1].toFixed(2)}">
${metalItems}
            </gradient>
        </aapt:attr>
    </path>`));
save(join(res, 'drawable', `ic_launcher_monochrome_${id}.xml`),
  vector(`
        android:fillColor="#FFFFFFFF" />`));
save(join(res, 'mipmap-anydpi-v26', `ic_launcher_${id}.xml`), `<?xml version="1.0" encoding="utf-8"?>
<!-- ${generated} -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_background_${id}"/>
  <foreground android:drawable="@drawable/ic_launcher_foreground_${id}"/>
  <monochrome android:drawable="@drawable/ic_launcher_monochrome_${id}"/>
</adaptive-icon>
`);

const background = snapshot(paintBackground, size);
save(join(res, 'drawable-nodpi', `ic_launcher_background_${id}.png`),
  background.encodeToBytes());
const composed = snapshot((c) => {
  c.drawImage(background, 0, 0, null);
  paintMark(c);
}, size);

// The visible middle two thirds, on a rounded tile like the other presets.
const visible = CK.XYWHRect(size / 6, size / 6, size * 2 / 3, size * 2 / 3);
const tile = (pixels) => snapshot((c) => {
  c.clipRRect(CK.RRectXY(CK.XYWHRect(0, 0, pixels, pixels), pixels * 0.22, pixels * 0.22),
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
composed.delete();
background.delete();

// The whole icon as one SVG, on the full 108 dp canvas.
const stops = (list) => list.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('');
save(join(root, 'tool', 'branding', `${id}.svg`), `<?xml version="1.0" encoding="utf-8"?>
<!-- Sovereign Crest, the Founder Collection's launcher icon. ${generated} -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="432" height="432">
  <defs>
    <linearGradient id="obsidian" x1="0" y1="0" x2="1" y2="1">${stops([[0, palette.obsidian[0]], [0.55, palette.obsidian[1]], [1, palette.obsidian[2]]])}</linearGradient>
    <radialGradient id="violet" cx="54" cy="58.3" r="45.4" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${palette.violet}" stop-opacity=".24"/><stop offset="1" stop-color="${palette.violet}" stop-opacity="0"/></radialGradient>
    <radialGradient id="champagne" cx="32.4" cy="25.9" r="48.6" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="${palette.champagne}" stop-opacity=".08"/><stop offset="1" stop-color="${palette.champagne}" stop-opacity="0"/></radialGradient>
    <linearGradient id="metal" gradientUnits="userSpaceOnUse" x1="${metalFrom[0].toFixed(2)}" y1="${metalFrom[1].toFixed(2)}" x2="${metalTo[0].toFixed(2)}" y2="${metalTo[1].toFixed(2)}">${stops(palette.metal)}</linearGradient>
  </defs>
  <rect width="108" height="108" fill="url(#obsidian)"/>
  <rect width="108" height="108" fill="url(#violet)"/>
  <rect width="108" height="108" fill="url(#champagne)"/>
  <path fill="url(#metal)" fill-rule="evenodd" d="${markSvg}"/>
</svg>
`);
console.log(`founder ${id}`);
