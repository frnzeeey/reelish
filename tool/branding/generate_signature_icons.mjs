// Generates the Signature launcher icons, the supporter collection's own
// artwork (Settings > Appearance > App icon). Each matches an app theme
// (lib/src/theme/supporter_themes.dart). Unlike the colour presets
// (generate_icon_presets.ps1, which samples a flat gradient from a source
// tile), these backgrounds carry ornaments, so they are painted here:
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_signature_icons.mjs
//
// Writes, per icon:
//   android/app/src/main/res/drawable-nodpi/ic_launcher_background_<id>.png
//       the 432 px (108 dp at xxxhdpi) adaptive background
//   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_<id>.xml
//       that background with the shared foreground mark and themed layer
//   android/app/src/main/res/mipmap-<density>/ic_launcher_<id>.png
//       the visible icon, for launchers without adaptive icons
//   assets/images/app_icons/<id>.png
//       a 192 px preview for the settings screen
//
// The visible icon is the middle two thirds of the 108 dp canvas, as a
// launcher's mask shows it, so the previews match the home screen. The mark is
// the shared foreground, inset 20% as in every other preset, which keeps it
// inside the safe zone under any mask. Ornaments are deterministic.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const require = createRequire(join(root, 'tool', 'icons', 'package.json'));
const CanvasKitInit = require('canvaskit-wasm');
const CK = await CanvasKitInit();

const res = join(root, 'android', 'app', 'src', 'main', 'res');
const previews = join(root, 'assets', 'images', 'app_icons');
const size = 432;
const densities = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };

const hex = (value, alpha = 1) => {
  const n = parseInt(value.slice(1), 16);
  return CK.Color((n >> 16) & 255, (n >> 8) & 255, n & 255, alpha);
};

/** A seeded generator, so every run paints the same sky. */
function seeded(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

function linear(canvas, from, to, colors, stops) {
  const paint = new CK.Paint();
  paint.setShader(CK.Shader.MakeLinearGradient(from, to, colors, stops, CK.TileMode.Clamp));
  canvas.drawRect(CK.XYWHRect(0, 0, size, size), paint);
  paint.delete();
}

function glow(canvas, x, y, radius, color) {
  const paint = new CK.Paint();
  paint.setShader(CK.Shader.MakeRadialGradient([x, y], radius,
    [color, CK.Color4f(color[0], color[1], color[2], 0)], null, CK.TileMode.Clamp));
  canvas.drawRect(CK.XYWHRect(0, 0, size, size), paint);
  paint.delete();
}

/** A soft diagonal highlight across the visible icon. */
function sheen(canvas, color) {
  const path = new CK.Path();
  path.moveTo(size * .56, 0).lineTo(size * .76, 0)
    .lineTo(size * .40, size).lineTo(size * .20, size).close();
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setShader(CK.Shader.MakeLinearGradient([0, size * .15], [0, size * .85],
    [color, CK.Color4f(color[0], color[1], color[2], 0)], null, CK.TileMode.Clamp));
  paint.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 6, true));
  canvas.drawPath(path, paint);
  paint.delete();
  path.delete();
}

function stars(canvas, color, count, seed) {
  const random = seeded(seed);
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  for (let i = 0; i < count; i++) {
    const bright = random();
    paint.setColor(CK.Color4f(color[0], color[1], color[2], .2 + bright * .6));
    canvas.drawCircle(random() * size, random() * size, .8 + bright * 1.8, paint);
  }
  paint.delete();
}

/** A four-pointed glint, for the brightest stars. */
function glint(canvas, x, y, radius, color) {
  const path = new CK.Path();
  const w = radius * .22;
  path.moveTo(x, y - radius).quadTo(x + w, y - w, x + radius, y)
    .quadTo(x + w, y + w, x, y + radius).quadTo(x - w, y + w, x - radius, y)
    .quadTo(x - w, y - w, x, y - radius).close();
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setColor(color);
  canvas.drawPath(path, paint);
  paint.delete();
  path.delete();
}

function ribbon(canvas, offset, color) {
  const path = new CK.Path();
  path.moveTo(0, size * (offset + .28))
    .cubicTo(size * .3, size * (offset - .12), size * .62, size * (offset + .36), size, size * (offset - .02))
    .lineTo(size, size * (offset + .14))
    .cubicTo(size * .62, size * (offset + .52), size * .3, size * (offset + .04), 0, size * (offset + .44))
    .close();
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setShader(CK.Shader.MakeLinearGradient([0, 0], [size, 0],
    [CK.Color4f(color[0], color[1], color[2], 0), color, CK.Color4f(color[0], color[1], color[2], 0)],
    [0, .5, 1], CK.TileMode.Clamp));
  paint.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 16, true));
  canvas.drawPath(path, paint);
  paint.delete();
  path.delete();
}

/** Soft out-of-focus lights, like bokeh behind a subject. */
function bokeh(canvas, color, seed) {
  const random = seeded(seed);
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 3, true));
  for (let i = 0; i < 9; i++) {
    paint.setColor(CK.Color4f(color[0], color[1], color[2], .08 + random() * .14));
    canvas.drawCircle(random() * size, random() * size, size * (.05 + random() * .09), paint);
  }
  paint.delete();
}

/** Beams fanning from the upper left, like a cinema spotlight. */
function rays(canvas, color) {
  const paint = new CK.Paint();
  paint.setAntiAlias(true);
  paint.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 8, true));
  for (const [from, to] of [[.18, .30], [.42, .52], [.66, .74]]) {
    const path = new CK.Path();
    path.moveTo(-size * .1, -size * .1)
      .lineTo(size * 1.2, size * from * 1.2)
      .lineTo(size * 1.2, size * to * 1.2)
      .close();
    paint.setShader(CK.Shader.MakeLinearGradient([0, 0], [size, size],
      [color, CK.Color4f(color[0], color[1], color[2], 0)], null, CK.TileMode.Clamp));
    canvas.drawPath(path, paint);
    path.delete();
  }
  paint.delete();
}

// Keyed by the launcher alias id, which is the saved choice and never
// changes; each now paints the app theme it is named for in the Dart presets
// (royal_violet is Velvet Cinema, celestial Arctic, rose_luxe Rosé Noir,
// golden_hour Obsidian Gold).
const icons = {
  // Velvet Cinema, the flagship: midnight violet lit in lavender, with the
  // beams of a cinema projector.
  royal_violet: (c) => {
    linear(c, [0, 0], [size, size], [hex('#8B6CF0'), hex('#5B2FC4'), hex('#1A1030')], [0, .5, 1]);
    glow(c, size * .26, size * .22, size * .55, hex('#C4B5FD', .42));
    rays(c, hex('#EDE7FF', .36));
    glow(c, size * .8, size * .86, size * .4, hex('#0D0B14', .5));
  },
  // Aurora: northern lights in teal and emerald over a green-black sky.
  aurora: (c) => {
    linear(c, [0, 0], [0, size], [hex('#0F2E2A'), hex('#0A1C19'), hex('#071311')], [0, .55, 1]);
    ribbon(c, .18, hex('#54D6C0', .8));
    ribbon(c, .44, hex('#34D399', .6));
    glow(c, size * .7, size * .2, size * .35, hex('#67E8F9', .22));
    stars(c, hex('#ECFDF5'), 30, 11);
  },
  // Ember: a dark theatre, warmed from below, with drifting embers.
  ember: (c) => {
    linear(c, [0, 0], [0, size], [hex('#1E0F0D'), hex('#3A1A16'), hex('#6B2620')], [0, .55, 1]);
    glow(c, size * .5, size * .95, size * .6, hex('#FF795F', .55));
    glow(c, size * .3, size * .25, size * .4, hex('#FFAD70', .18));
    bokeh(c, hex('#FFAD70'), 23);
  },
  // Arctic: a deep navy night with icy stars.
  celestial: (c) => {
    linear(c, [0, 0], [0, size], [hex('#1B3350'), hex('#0F1E30'), hex('#08111C')], [0, .55, 1]);
    glow(c, size * .32, size * .28, size * .6, hex('#8CCBFF', .38));
    stars(c, hex('#F0F9FF'), 90, 7);
    glint(c, size * .72, size * .27, 13, hex('#F0F9FF', .95));
    glint(c, size * .27, size * .74, 9, hex('#BAE6FD', .85));
    glint(c, size * .78, size * .7, 6, hex('#BAE6FD', .8));
  },
  // Ivory Studio: warm ivory and stone under a soft bronze light; its mark
  // is ink, not white (marks below).
  ivory_studio: (c) => {
    linear(c, [0, 0], [size, size], [hex('#FFFFFF'), hex('#F1EDE4'), hex('#DDD4C4')], [0, .55, 1]);
    glow(c, size * .3, size * .25, size * .55, hex('#FFFFFF', .7));
    glow(c, size * .78, size * .82, size * .45, hex('#B49B78', .3));
    sheen(c, hex('#FFFFFF', .5));
  },
  // Obsidian Gold: black obsidian, a champagne light and a gold sheen.
  golden_hour: (c) => {
    linear(c, [0, 0], [size, size], [hex('#2A261E'), hex('#151411'), hex('#0D0D0C')], [0, .5, 1]);
    glow(c, size * .28, size * .22, size * .5, hex('#D6B36A', .32));
    sheen(c, hex('#E9D5A3', .36));
    glow(c, size * .82, size * .86, size * .32, hex('#B58A45', .22));
  },
  // Rosé Noir: dark plum with rose light and soft mauve bokeh.
  rose_luxe: (c) => {
    linear(c, [0, 0], [size, size], [hex('#4A2540'), hex('#2A1729'), hex('#140D14')], [0, .55, 1]);
    glow(c, size * .3, size * .26, size * .52, hex('#F18EB5', .42));
    bokeh(c, hex('#C4A0D2'), 5);
  },
};

/** Icons whose mark is not the shared white one: tinted to read on them. */
const marks = {
  ivory_studio: hex('#2E2A23'),
};

const adaptive = (id) => `<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/branding/generate_signature_icons.mjs. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_background_${id}"/>
  <foreground>
      <inset
          android:drawable="@drawable/ic_launcher_foreground${id in marks ? `_${id}` : ''}"
          android:inset="20%" />
  </foreground>
  <monochrome>
      <inset
          android:drawable="@drawable/ic_launcher_monochrome"
          android:inset="20%" />
  </monochrome>
</adaptive-icon>
`;

const foreground = CK.MakeImageFromEncoded(
  readFileSync(join(res, 'drawable-xxxhdpi', 'ic_launcher_foreground.png')));

function snapshot(draw, width, height = width) {
  const surface = CK.MakeSurface(width, height);
  draw(surface.getCanvas());
  surface.flush();
  const image = surface.makeImageSnapshot();
  surface.delete();
  return image;
}

function savePng(image, path) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, image.encodeToBytes());
}

for (const [id, paint] of Object.entries(icons)) {
  const background = snapshot(paint, size);
  savePng(background, join(res, 'drawable-nodpi', `ic_launcher_background_${id}.png`));
  writeFileSync(join(res, 'mipmap-anydpi-v26', `ic_launcher_${id}.xml`), adaptive(id));

  // The mark: the shared white one, or a tinted copy for a light icon, saved
  // as its own drawable for the adaptive icon to use.
  let mark = foreground;
  if (id in marks) {
    mark = snapshot((c) => {
      const paint = new CK.Paint();
      paint.setColorFilter(CK.ColorFilter.MakeBlend(marks[id], CK.BlendMode.SrcIn));
      c.drawImage(foreground, 0, 0, paint);
      paint.delete();
    }, foreground.width(), foreground.height());
    savePng(mark, join(res, 'drawable-nodpi', `ic_launcher_foreground_${id}.png`));
  }

  // The whole adaptive icon, as a launcher composes it.
  const composed = snapshot((c) => {
    c.drawImage(background, 0, 0, null);
    const inset = size * .2;
    c.drawImageRectCubic(mark, CK.XYWHRect(0, 0, mark.width(), mark.height()),
      CK.XYWHRect(inset, inset, size - inset * 2, size - inset * 2), 1 / 3, 1 / 3, null);
  }, size);
  if (mark !== foreground) mark.delete();

  // The visible middle two thirds, on a rounded tile like the other presets.
  const visible = CK.XYWHRect(size / 6, size / 6, size * 2 / 3, size * 2 / 3);
  const tile = (pixels) => snapshot((c) => {
    c.clipRRect(CK.RRectXY(CK.XYWHRect(0, 0, pixels, pixels), pixels * .22, pixels * .22),
      CK.ClipOp.Intersect, true);
    c.drawImageRectCubic(composed, visible, CK.XYWHRect(0, 0, pixels, pixels), 1 / 3, 1 / 3, null);
  }, pixels);
  for (const [density, pixels] of Object.entries(densities)) {
    const image = tile(pixels);
    savePng(image, join(res, `mipmap-${density}`, `ic_launcher_${id}.png`));
    image.delete();
  }
  const preview = tile(192);
  savePng(preview, join(previews, `${id}.png`));
  preview.delete();
  composed.delete();
  background.delete();
  console.log(`signature ${id}`);
}
foreground.delete();
