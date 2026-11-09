// Generates Sovereign Crest, the Founder Collection's launcher icon
// (Settings > Appearance > App icon, shown to the Founder only). Its mark is
// its own: a geometric Reelish R cut like metal, with chamfered corners, whose
// top edge rises into a three-point diadem, each point cut as a jewel (a light
// face and a shadowed one). A bevel catches the light along its upper-left
// edges. Champagne gold on obsidian, with a restrained midnight-violet glow
// (the Sovereign Edition theme). No hairlines, so it holds at 48 px.
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_sovereign_crest.mjs
//
// The geometry below (MARK, FACETS) in the adaptive icon's 108 dp viewport is
// the master; every asset is made from it, so the launcher layers are vectors
// and stay crisp at any size. Writes:
//   tool/branding/sovereign_crest.svg
//       the whole icon as one SVG, the vector reference for other uses
//   tool/branding/sovereign_crest.ico
//       16 to 256 px, for Windows (not wired in: Windows embeds one icon in
//       Reelish.exe for everyone, so a Founder-only icon cannot replace it)
//   android/app/src/main/res/drawable/ic_launcher_foreground_sovereign_crest.xml
//       the mark as a VectorDrawable: metal fill, jewel facets, bevel
//   android/app/src/main/res/drawable/ic_launcher_monochrome_sovereign_crest.xml
//       the mark's silhouette, for themed icons on Android 13 and later
//   android/app/src/main/res/drawable-nodpi/ic_launcher_background_sovereign_crest.png
//       the 432 px (108 dp at xxxhdpi) obsidian background and its glow
//   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_sovereign_crest.xml
//       the adaptive icon
//   android/app/src/main/res/mipmap-<density>/ic_launcher_sovereign_crest.png
//       the visible icon, for launchers without adaptive icons
//   assets/images/app_icons/sovereign_crest.png
//       a 192 px preview for the settings screen
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
const branding = join(root, 'tool', 'branding');
const size = 432;
const scale = size / 108;
const densities = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

// The monogram, before [fit]: the stem rising into the diadem's first point,
// two more points, the chamfered bowl and the leg. The counter winds the other
// way, so it is a hole under any fill rule (VectorDrawable clip paths).
const MARK =
  'M35 82 L35 32 L39.5 24.5 L45 31 L51 22.5 L57 31 L62.5 24.5 L67 32 ' +
  'L77.5 42.5 L77.5 52.5 L69 61 L79.5 82 L68 82 L58 63.5 L45 63.5 L45 82 Z ' +
  'M45 42 L45 53 L63 53 L67.5 48.5 L67.5 46.5 L63 42 Z';

// The shadowed faces: the right face of each diadem point, the bowl's lower
// chamfer and the leg's outer face. Light comes from the upper left.
const FACETS = [
  'M39.5 24.5 L45 31 L39.5 32 Z',
  'M51 22.5 L57 31 L51 32 Z',
  'M62.5 24.5 L67 32 L62.5 32 Z',
  'M77.5 52.5 L69 61 L67.5 53 L67.5 48.5 Z',
  'M69 61 L79.5 82 L74.5 82 L66 62 Z',
];

// Scaled about the centre so the mark sits inside the safe zone with room.
const fit = 0.82;

const palette = {
  // Champagne metal, lit from the upper left: the platinum highlight, the
  // body, its shadow, the light returning along the leg, and its foot.
  metal: [
    [0, '#F3DCA7'],
    [0.35, '#D6B779'],
    [0.62, '#B08D50'],
    [0.8, '#D9BD84'],
    [1, '#A9874B'],
  ],
  facet: ['#5A4320', 0.32],
  // The bevel: bright on the upper-left edges, shadow on the lower right.
  bevel: [
    [0, '#FFF4D6', 0.75],
    [0.5, '#F3DCA7', 0.15],
    [1, '#3A2A12', 0.45],
  ],
  bevelWidth: 2.4,
  obsidian: ['#14122A', '#090A12', '#06060B'],
  violet: ['#A78BFA', 0.26],
  champagne: ['#D6B779', 0.1],
};

const hex = (value, alpha = 1) => {
  const n = parseInt(value.slice(1), 16);
  return CK.Color((n >> 16) & 255, (n >> 8) & 255, n & 255, alpha);
};
const argb = (value, alpha = 1) =>
  `#${Math.round(alpha * 255).toString(16).padStart(2, '0').toUpperCase()}${value.slice(1).toUpperCase()}`;

const fitMatrix = CK.Matrix.multiply(
  CK.Matrix.translated(54, 54),
  CK.Matrix.scaled(fit, fit),
  CK.Matrix.translated(-54, -54),
);

/** [svg] fitted into the viewport, as an SVG path string. */
function fitted(svg) {
  const path = CK.Path.MakeFromSVGString(svg);
  path.transform(fitMatrix);
  const out = path.toSVGString();
  path.delete();
  return out;
}

/** Whether every point of the outline is within the 33 dp safe radius. */
function insideSafeZone(svg) {
  const path = CK.Path.MakeFromSVGString(svg);
  const iter = new CK.ContourMeasureIter(path, false, 1);
  let inside = true;
  for (let contour = iter.next(); contour; contour = iter.next()) {
    for (let d = 0; d <= contour.length(); d += 0.25) {
      const [x, y] = contour.getPosTan(d);
      if (Math.hypot(x - 54, y - 54) > 33) inside = false;
    }
    contour.delete();
  }
  iter.delete();
  path.delete();
  return inside;
}

const mark = fitted(MARK);
const facets = FACETS.map(fitted);
if (!insideSafeZone(mark)) {
  throw new Error('Sovereign Crest mark leaves the 66 dp safe zone');
}
const markBounds = (() => {
  const path = CK.Path.MakeFromSVGString(mark);
  const bounds = path.computeTightBounds();
  path.delete();
  return bounds;
})();
// Gradients run across the mark, from its upper left to its lower right.
const from = [markBounds[0], markBounds[1]];
const to = [markBounds[2], markBounds[3]];
const bevelWidth = palette.bevelWidth * fit;

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
  const glow = (x, y, radius, [color, alpha]) => {
    const c = hex(color, alpha);
    fill(CK.Shader.MakeRadialGradient([x, y], radius,
      [c, CK.Color4f(c[0], c[1], c[2], 0)], null, CK.TileMode.Clamp));
  };
  // Midnight violet behind the mark, and a soft champagne light on it.
  glow(size * 0.5, size * 0.523, size * 0.405, palette.violet);
  glow(size * 0.5, size * 0.463, size * 0.243, palette.champagne);
}

function paintMark(canvas) {
  const toPixels = CK.Matrix.scaled(scale, scale);
  const pathOf = (svg) => {
    const path = CK.Path.MakeFromSVGString(svg);
    path.transform(toPixels);
    return path;
  };
  const px = (point) => point.map((v) => v * scale);
  const body = pathOf(mark);
  const metal = new CK.Paint();
  metal.setAntiAlias(true);
  metal.setShader(CK.Shader.MakeLinearGradient(px(from), px(to),
    palette.metal.map(([, c]) => hex(c)), palette.metal.map(([o]) => o),
    CK.TileMode.Clamp));
  canvas.drawPath(body, metal);
  canvas.save();
  canvas.clipPath(body, CK.ClipOp.Intersect, true);
  const shade = new CK.Paint();
  shade.setAntiAlias(true);
  shade.setColor(hex(...palette.facet));
  for (const facet of facets) {
    const path = pathOf(facet);
    canvas.drawPath(path, shade);
    path.delete();
  }
  const bevel = new CK.Paint();
  bevel.setAntiAlias(true);
  bevel.setStyle(CK.PaintStyle.Stroke);
  bevel.setStrokeWidth(bevelWidth * scale);
  bevel.setShader(CK.Shader.MakeLinearGradient(px(from), px(to),
    palette.bevel.map(([, c, a]) => hex(c, a)), palette.bevel.map(([o]) => o),
    CK.TileMode.Clamp));
  canvas.drawPath(body, bevel);
  canvas.restore();
  [metal, shade, bevel].forEach((p) => p.delete());
  body.delete();
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
const line = (point, name) =>
  `android:${name}X="${point[0].toFixed(2)}" android:${name}Y="${point[1].toFixed(2)}"`;
const gradientXml = (attr, stops) => `
        <aapt:attr name="android:${attr}">
            <gradient android:type="linear" ${line(from, 'start')} ${line(to, 'end')}>
${stops.map(([o, c, a = 1]) => `                <item android:offset="${o}" android:color="${argb(c, a)}"/>`).join('\n')}
            </gradient>
        </aapt:attr>`;
const vectorXml = (body) => `<?xml version="1.0" encoding="utf-8"?>
<!-- ${generated} -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
${body}
</vector>
`;

// The foreground: the metal, then the facets and bevel clipped to the mark.
save(join(res, 'drawable', `ic_launcher_foreground_${id}.xml`), vectorXml(`    <path android:pathData="${mark}">${gradientXml('fillColor', palette.metal)}
    </path>
    <group>
        <clip-path android:pathData="${mark}"/>
${facets.map((f) => `        <path android:pathData="${f}" android:fillColor="${argb(...palette.facet)}"/>`).join('\n')}
        <path android:pathData="${mark}" android:strokeWidth="${bevelWidth.toFixed(3)}">${gradientXml('strokeColor', palette.bevel)}
        </path>
    </group>`));
save(join(res, 'drawable', `ic_launcher_monochrome_${id}.xml`),
  vectorXml(`    <path android:pathData="${mark}" android:fillColor="#FFFFFFFF"/>`));
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
composed.delete();
background.delete();

// The whole icon as one SVG, on the full 108 dp canvas.
const stops = (list) => list
  .map(([o, c, a = 1]) => `<stop offset="${o}" stop-color="${c}"${a < 1 ? ` stop-opacity="${a}"` : ''}/>`)
  .join('');
const across = `gradientUnits="userSpaceOnUse" x1="${from[0].toFixed(2)}" y1="${from[1].toFixed(2)}" x2="${to[0].toFixed(2)}" y2="${to[1].toFixed(2)}"`;
const radial = (name, cx, cy, r, [color, alpha]) =>
  `<radialGradient id="${name}" cx="${cx}" cy="${cy}" r="${r}" gradientUnits="userSpaceOnUse">${stops([[0, color, alpha], [1, color, 0]])}</radialGradient>`;
save(join(branding, `${id}.svg`), `<?xml version="1.0" encoding="utf-8"?>
<!-- Sovereign Crest, the Founder Collection's launcher icon. ${generated} -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="432" height="432">
  <defs>
    <linearGradient id="obsidian" x1="0" y1="0" x2="1" y2="1">${stops([[0, palette.obsidian[0]], [0.55, palette.obsidian[1]], [1, palette.obsidian[2]]])}</linearGradient>
    ${radial('violet', 54, 56.5, 43.7, palette.violet)}
    ${radial('champagne', 54, 50, 26.2, palette.champagne)}
    <linearGradient id="metal" ${across}>${stops(palette.metal)}</linearGradient>
    <linearGradient id="bevel" ${across}>${stops(palette.bevel)}</linearGradient>
    <clipPath id="mark"><path d="${mark}"/></clipPath>
  </defs>
  <rect width="108" height="108" fill="url(#obsidian)"/>
  <rect width="108" height="108" fill="url(#violet)"/>
  <rect width="108" height="108" fill="url(#champagne)"/>
  <path fill="url(#metal)" d="${mark}"/>
  <g clip-path="url(#mark)">
${facets.map((f) => `    <path fill="${palette.facet[0]}" fill-opacity="${palette.facet[1]}" d="${f}"/>`).join('\n')}
    <path fill="none" stroke="url(#bevel)" stroke-width="${bevelWidth.toFixed(3)}" d="${mark}"/>
  </g>
</svg>
`);
console.log(`founder ${id}`);
