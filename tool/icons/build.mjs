// Builds Reelish's icons from the drawings in icons.mjs:
//   assets/icons/svg/<name>.svg        one flattened, standalone SVG per icon
//   assets/fonts/ReelishIcons.otf      the same outlines as a font
//   lib/src/theme/reelish_icons.dart   the registry the app uses
//   tool/icons/contact_sheet.png       every icon on one page, for review
//
//   cd tool/icons && npm ci && npm run build
//
// Strokes become outlines with Skia's own stroker, so a glyph is exactly what
// the same stroke would draw. See docs/design/icon-system.md.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import CanvasKitInit from 'canvaskit-wasm';
import opentype from 'opentype.js';
import { icons } from './icons.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const CK = await CanvasKitInit();
const round = (value) => Math.round(value * 100) / 100;
const problems = [];

function outline(op) {
  const p = CK.Path.MakeFromSVGString(op.d);
  if (!p) throw new Error(`bad path: ${op.d}`);
  if (op.evenOdd) p.setFillType(CK.FillType.EvenOdd);
  if (op.w) {
    const stroked = p.stroke({
      width: op.w,
      cap: CK.StrokeCap.Round,
      join: CK.StrokeJoin.Round,
      precision: 1,
    });
    if (!stroked) throw new Error(`cannot stroke: ${op.d}`);
    stroked.simplify();
  }
  return p;
}

/** Merges an icon's drawing, in order, into one winding outline. */
function flatten(name, ops) {
  let shape = new CK.Path();
  for (const op of ops) {
    const piece = outline(op);
    const next = CK.Path.MakeFromOp(
      shape,
      piece,
      op.cut ? CK.PathOp.Difference : CK.PathOp.Union,
    );
    if (!next) throw new Error(`${name}: path operation failed`);
    // Path operations can fail quietly on simple shapes.
    if (op.cut && next.toSVGString() === shape.toSVGString()) {
      problems.push(`${name}: a cut removed nothing (${op.d})`);
    }
    shape = next;
  }
  shape.simplify();
  const wound = shape.makeAsWinding() ?? shape;
  const [left, top, right, bottom] = wound.getBounds();
  if (left < 0.5 || top < 0.5 || right > 23.5 || bottom > 23.5) {
    problems.push(`${name}: ${[left, top, right, bottom].map(round).join(' ')}`);
  }
  return wound;
}



/**
 * Skia's verbs as absolute commands. A rational arc becomes one cubic, a very
 * close fit for a quarter circle: four segments for a whole dot, where the
 * path's SVG string would give sixteen quadratics.
 */
function commands(shape) {
  const data = shape.toCmds();
  const out = [];
  let i = 0;
  let px = 0;
  let py = 0;
  const v = (count) => Array.from(data.subarray(i, (i += count)));
  while (i < data.length) {
    const verb = data[i++];
    if (verb === CK.MOVE_VERB) {
      const [x, y] = v(2);
      out.push(['M', round(x), round(y)]);
      [px, py] = [x, y];
    } else if (verb === CK.LINE_VERB) {
      const [x, y] = v(2);
      out.push(['L', round(x), round(y)]);
      [px, py] = [x, y];
    } else if (verb === CK.QUAD_VERB) {
      const [cx, cy, x, y] = v(4);
      out.push(['Q', ...[cx, cy, x, y].map(round)]);
      [px, py] = [x, y];
    } else if (verb === CK.CONIC_VERB) {
      const [cx, cy, x, y, w] = v(5);
      const k = (4 * w) / (3 * (1 + w));
      out.push([
        'C',
        ...[px + k * (cx - px), py + k * (cy - py), x + k * (cx - x), y + k * (cy - y), x, y].map(round),
      ]);
      [px, py] = [x, y];
    } else if (verb === CK.CUBIC_VERB) {
      const points = v(6);
      out.push(['C', ...points.map(round)]);
      [px, py] = points.slice(4);
    } else if (verb === CK.CLOSE_VERB) {
      out.push(['Z']);
    } else {
      throw new Error('unexpected verb ' + verb);
    }
  }
  return out;
}

/** A contour's points, with curves sampled, for measuring it. */
function polygon(contour) {
  const points = [];
  let [px, py] = [0, 0];
  for (const [type, ...a] of contour) {
    if (type === 'M' || type === 'L') points.push(a);
    if (type === 'Q' || type === 'C') {
      const steps = 8;
      for (let i = 1; i <= steps; i++) {
        const t = i / steps;
        const u = 1 - t;
        points.push(
          type === 'Q'
            ? [0, 1].map((k) => u * u * [px, py][k] + 2 * u * t * a[k] + t * t * a[k + 2])
            : [0, 1].map(
                (k) =>
                  u * u * u * [px, py][k] +
                  3 * u * u * t * a[k] +
                  3 * u * t * t * a[k + 2] +
                  t * t * t * a[k + 4],
              ),
        );
      }
    }
    if (type !== 'Z') [px, py] = a.slice(-2);
  }
  return points;
}

const area = (points) =>
  points.reduce((sum, [x, y], i) => {
    const [nx, ny] = points[(i + 1) % points.length];
    return sum + x * ny - nx * y;
  }, 0) / 2;

const inside = ([x, y], points) => {
  let hit = false;
  points.forEach(([ax, ay], i) => {
    const [bx, by] = points[(i + 1) % points.length];
    if (ay > y !== by > y && x < ((bx - ax) * (y - ay)) / (by - ay) + ax) hit = !hit;
  });
  return hit;
};

function reversed(contour) {
  const body = contour.filter(([type]) => type !== 'Z');
  const ends = body.map((command) => command.slice(-2));
  const out = [['M', ...ends.at(-1)]];
  for (let i = body.length - 1; i > 0; i--) {
    const [type, ...a] = body[i];
    const to = ends[i - 1];
    if (type === 'L') out.push(['L', ...to]);
    if (type === 'Q') out.push(['Q', a[0], a[1], ...to]);
    if (type === 'C') out.push(['C', a[2], a[3], a[0], a[1], ...to]);
  }
  out.push(['Z']);
  return out;
}

/**
 * Fonts and SVGs fill by winding, so a hole must run against the shape around
 * it. Each contour's direction comes from how deeply it is nested, since Skia
 * can leave a hole running the same way, which fills it in.
 */
function wind(cmds) {
  const contours = [];
  for (const command of cmds) {
    if (command[0] === 'M') contours.push([]);
    contours.at(-1).push(command);
  }
  const shapes = contours.map(polygon);
  return contours.flatMap((contour, index) => {
    const depth = shapes.filter(
      (other, i) => i !== index && inside(shapes[index][0], other),
    ).length;
    const clockwise = area(shapes[index]) > 0;
    return clockwise === (depth % 2 === 0) ? contour : reversed(contour);
  });
}

const svgFile = (d) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><path fill="currentColor" d="${d}"/></svg>\n`;

const pathData = (cmds) =>
  cmds.map(([type, ...args]) => type + args.join(' ')).join('');

const unitsPerEm = 2400;
const ascender = 2000;
const X = (x) => Math.round(x * 100);
const Y = (y) => Math.round(ascender - y * 100);

function glyph(name, unicode, cmds) {
  const p = new opentype.Path();
  for (const [type, ...a] of cmds) {
    if (type === 'M') p.moveTo(X(a[0]), Y(a[1]));
    if (type === 'L') p.lineTo(X(a[0]), Y(a[1]));
    if (type === 'Q') p.quadraticCurveTo(X(a[0]), Y(a[1]), X(a[2]), Y(a[3]));
    if (type === 'C') {
      p.curveTo(X(a[0]), Y(a[1]), X(a[2]), Y(a[3]), X(a[4]), Y(a[5]));
    }
    if (type === 'Z') p.close();
  }
  return new opentype.Glyph({ name, unicode, advanceWidth: unitsPerEm, path: p });
}

const names = Object.keys(icons).sort();
const svgDir = path.join(root, 'assets/icons/svg');
fs.mkdirSync(svgDir, { recursive: true });
for (const file of fs.readdirSync(svgDir)) fs.rmSync(path.join(svgDir, file));

const glyphs = [
  new opentype.Glyph({ name: '.notdef', unicode: 0, advanceWidth: unitsPerEm, path: new opentype.Path() }),
];
const entries = [];
const outlines = {};
let points = 0;
names.forEach((name, index) => {
  const wound = flatten(name, icons[name]);
  const cmds = wind(commands(wound));
  const d = pathData(cmds);
  outlines[name] = d;
  points = Math.max(points, cmds.length);
  fs.writeFileSync(path.join(svgDir, `${kebab(name)}.svg`), svgFile(d));
  const code = 0xe000 + index;
  glyphs.push(glyph(name, code, cmds));
  entries.push({ name, code });
});

function kebab(value) {
  return value.replace(/[A-Z0-9]+/g, (m) => `-${m.toLowerCase()}`);
}

const font = new opentype.Font({
  familyName: 'ReelishIcons',
  styleName: 'Regular',
  unitsPerEm,
  ascender,
  descender: ascender - unitsPerEm,
  glyphs,
});
fs.writeFileSync(
  path.join(root, 'assets/fonts/ReelishIcons.otf'),
  Buffer.from(font.toArrayBuffer()),
);

const hex = (code) => `0x${code.toString(16).toUpperCase()}`;
const fills = entries.filter(({ name }) => name.endsWith('Filled'));
const dart = `// GENERATED by tool/icons/build.mjs from tool/icons/icons.mjs. Do not edit.
import 'package:flutter/widgets.dart';

/// Reelish's own icons, as a font compiled from \`assets/icons/svg\`. They are
/// ordinary [IconData], so \`Icon\`, \`IconButton\` and \`IconTheme\` work as usual.
/// See docs/design/icon-system.md.
abstract final class ReelishIcons {
  static const _family = 'ReelishIcons';

${entries.map(({ name, code }) => `  static const ${name} = IconData(${hex(code)}, fontFamily: _family);`).join('\n')}

  /// The solid form of [icon], for selected states; [icon] itself when it has
  /// none. A static font has no fill axis, so \`Icon.fill\` does nothing here.
  static IconData filled(IconData icon) => switch (icon.codePoint) {
${fills.map(({ name }) => `    ${hex(entries.find((e) => e.name === name.replace(/Filled$/, '')).code)} => ${name},`).join('\n')}
    _ => icon,
  };

  /// Every icon by name, for the icon gallery.
  static const all = <String, IconData>{
${entries.map(({ name }) => `    '${name}': ${name},`).join('\n')}
  };
}
`;
fs.writeFileSync(path.join(root, 'lib/src/theme/reelish_icons.dart'), dart);

// The contact sheet: each icon large, and at 16 px for legibility.
const columns = 12;
const cell = 112;
const height = Math.ceil(names.length / columns) * (cell + 8);
const surface = CK.MakeSurface(columns * cell, height);
const canvas = surface.getCanvas();
canvas.clear(CK.Color(16, 16, 22, 1));
const paint = new CK.Paint();
paint.setAntiAlias(true);
paint.setColor(CK.WHITE);
names.forEach((name, index) => {
  const p = CK.Path.MakeFromSVGString(outlines[name]);
  const x = (index % columns) * cell + 8;
  const y = Math.floor(index / columns) * (cell + 8) + 12;
  canvas.save();
  canvas.translate(x, y);
  canvas.scale(2.5, 2.5);
  canvas.drawPath(p, paint);
  canvas.restore();
  canvas.save();
  canvas.translate(x + 66, y + 22);
  canvas.scale(16 / 24, 16 / 24);
  canvas.drawPath(p, paint);
  canvas.restore();
});
const image = surface.makeImageSnapshot();
fs.writeFileSync(path.join(here, 'contact_sheet.png'), Buffer.from(image.encodeToBytes()));

if (problems.length) {
  console.error(['Problems:', ...problems].join('\n'));
  process.exitCode = 1;
}
console.log(`${names.length} icons, ${fills.length} solid forms, largest outline ${points} commands`);
console.log(names.map((n, i) => `${i % columns === 0 ? `\n[row ${i / columns + 1}] ` : ''}${n}`).join(' '));
