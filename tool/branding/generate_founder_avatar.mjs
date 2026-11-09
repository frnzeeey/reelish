// Generates the Founder's avatar (Profile > avatar, for the Founder only):
// two champagne laurel branches rising round an obsidian disc to the Founder
// Collection's crown (sovereign_shared.mjs), with the Reelish mark small at
// the centre and a fine champagne rim.
//
//   cd tool/icons && npm ci && cd ../.. && node tool/branding/generate_founder_avatar.mjs
//
// Writes assets/avatars/founder_laurel.png at 512 px, the asset AvatarPreset
// .founderLaurel names (lib/src/account/profile_controller.dart). Leaves are
// placed by formula, so every run draws the same wreath.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { crownHeight, drawCrown, hexColor, metal } from './sovereign_shared.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const require = createRequire(join(root, 'tool', 'icons', 'package.json'));
const CanvasKitInit = require('canvaskit-wasm');
const CK = await CanvasKitInit();

const N = 512;
const C = N / 2;
const out = join(root, 'assets', 'avatars', 'founder_laurel.png');

const surface = CK.MakeSurface(N, N);
const c = surface.getCanvas();
c.clear(CK.Color(0, 0, 0, 0));

// The disc: obsidian, lit faintly violet from just above the centre.
const disc = new CK.Paint();
disc.setAntiAlias(true);
disc.setShader(CK.Shader.MakeRadialGradient([C, C * 0.9], C,
  [hexColor(CK, '#231C3D'), hexColor(CK, '#120F20'), hexColor(CK, '#090A12')],
  [0, 0.6, 1], CK.TileMode.Clamp));
c.drawCircle(C, C, C, disc);

const gold = new CK.Paint();
gold.setAntiAlias(true);
gold.setShader(metal(CK, [60, 60], [452, 452]));

// The wreath: two branches on a circle, from the bottom up each side.
const radius = 168;
const rad = (degrees) => (degrees * Math.PI) / 180;
const on = (degrees) => [C + Math.cos(rad(degrees)) * radius, C + Math.sin(rad(degrees)) * radius];

/** A laurel leaf: a pointed oval from [base] along [direction]. */
function leaf([bx, by], direction, length, width) {
  const dx = Math.cos(direction);
  const dy = Math.sin(direction);
  const [mx, my] = [bx + dx * length * 0.5, by + dy * length * 0.5];
  const path = new CK.Path();
  path.moveTo(bx, by);
  path.quadTo(mx - dy * width, my + dx * width, bx + dx * length, by + dy * length);
  path.quadTo(mx + dy * width, my - dx * width, bx, by);
  path.close();
  return path;
}

function branch(from, to) {
  const sign = Math.sign(to - from);
  const stem = new CK.Path();
  for (let i = 0; i <= 40; i++) {
    const [x, y] = on(from + ((to - from) * i) / 40);
    if (i === 0) stem.moveTo(x, y);
    else stem.lineTo(x, y);
  }
  const line = new CK.Paint();
  line.setAntiAlias(true);
  line.setStyle(CK.PaintStyle.Stroke);
  line.setStrokeWidth(7);
  line.setStrokeCap(CK.StrokeCap.Round);
  line.setShader(metal(CK, [60, 60], [452, 452]));
  c.drawPath(stem, line);
  // Pairs of leaves, one either side, growing smaller toward the tip.
  const pairs = 6;
  for (let i = 0; i < pairs; i++) {
    const t = (i + 0.6) / (pairs + 0.4);
    const at = from + (to - from) * t;
    const forward = rad(at) + (sign * Math.PI) / 2;
    const grow = 1 - t * 0.38;
    for (const side of [1, -1]) {
      c.drawPath(leaf(on(at), forward + side * sign * rad(38), 70 * grow, 21 * grow), gold);
    }
  }
  c.drawPath(leaf(on(to), rad(to) + (sign * Math.PI) / 2, 58, 17), gold);
}
branch(100, 232);
branch(80, -52);

// The crown, at the top between the branch tips.
const crownWidth = 150;
drawCrown(CK, c, C - crownWidth / 2, 128 - crownHeight(crownWidth), crownWidth, { shadow: false });

// The Reelish mark, small, at the centre.
const mark = CK.MakeImageFromEncoded(readFileSync(join(root, 'tool', 'branding', 'launcher_monochrome.png')));
c.saveLayer(null, null, null, 0);
c.drawImageRectCubic(mark, CK.XYWHRect(150, 210, 546, 420), CK.XYWHRect(176, 222, 160, 123), 1 / 3, 1 / 3, null);
const fill = new CK.Paint();
fill.setShader(metal(CK, [176, 222], [336, 345]));
fill.setBlendMode(CK.BlendMode.SrcIn);
c.drawRect(CK.XYWHRect(0, 0, N, N), fill);
c.restore();

// A fine champagne rim.
const rim = new CK.Paint();
rim.setAntiAlias(true);
rim.setStyle(CK.PaintStyle.Stroke);
rim.setStrokeWidth(4);
rim.setColor(hexColor(CK, '#D6B779', 0.55));
c.drawCircle(C, C, C - 3, rim);

surface.flush();
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, surface.makeImageSnapshot().encodeToBytes());
console.log('founder avatar founder_laurel');
