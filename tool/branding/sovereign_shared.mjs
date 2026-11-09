// The Founder Collection's crown and champagne metal, used by
// generate_sovereign_crest.mjs (the launcher icon). The Founder's profile
// frame (_LaurelPainter in lib/src/widgets/avatar_frame.dart) draws the
// same crown from the same numbers; change both together.

/** Champagne metal lit from the upper left: highlight, body, shadow, the
 *  returning light, and the foot. */
export const metalStops = [
  [0, '#F3DCA7'],
  [0.35, '#D6B779'],
  [0.62, '#B08D50'],
  [0.8, '#D9BD84'],
  [1, '#A9874B'],
];

export const palette = {
  obsidian: ['#14122A', '#090A12', '#06060B'],
  violet: '#A78BFA',
  champagne: '#D6B779',
  jewel: '#2A2140',
};

export function hexColor(CK, value, alpha = 1) {
  const n = parseInt(value.slice(1), 16);
  return CK.Color((n >> 16) & 255, (n >> 8) & 255, n & 255, alpha);
}

/** A linear metal gradient from [from] to [to]. */
export function metal(CK, from, to) {
  return CK.Shader.MakeLinearGradient(from, to,
    metalStops.map(([, c]) => hexColor(CK, c)), metalStops.map(([o]) => o),
    CK.TileMode.Clamp);
}

// The crown, designed in a 292 x 149 box: three points ending in pearls, the
// middle one tallest, over a rounded band set with three jewels.
const CROWN_W = 292;
const CROWN_H = 149;
const BODY = 'M23 145 L15 43 L87 97 L146 23 L205 97 L277 43 L269 145 Z';
const BAND = [19, 119, 254, 30, 12];
const PEARLS = [[15, 37], [146, 15], [277, 37]];
const PEARL_R = 15;
const JEWELS = [68, 146, 224];
const JEWEL_Y = 134;
const JEWEL_R = 7;

/** The crown's height for a given [width]. */
export const crownHeight = (width) => (width * CROWN_H) / CROWN_W;

/**
 * Draws the crown with its top-left corner at ([left], [top]) and [width]
 * across: an optional soft shadow, the metal body, and the band's jewels.
 * [ink] draws it in one colour instead (a monochrome layer).
 */
export function drawCrown(CK, canvas, left, top, width, { shadow = true, ink = null } = {}) {
  const k = width / CROWN_W;
  const path = CK.Path.MakeFromSVGString(BODY);
  const [bx, by, bw, bh, br] = BAND;
  path.addRRect(CK.RRectXY(CK.XYWHRect(bx, by, bw, bh), br, br));
  for (const [x, y] of PEARLS) path.addCircle(x, y, PEARL_R);
  path.transform(CK.Matrix.multiply(CK.Matrix.translated(left, top), CK.Matrix.scaled(k, k)));
  if (shadow && !ink) {
    const paint = new CK.Paint();
    paint.setAntiAlias(true);
    paint.setColor(CK.Color(0, 0, 0, 0.38));
    paint.setMaskFilter(CK.MaskFilter.MakeBlur(CK.BlurStyle.Normal, 9 * k, true));
    canvas.save();
    canvas.translate(5 * k, 10 * k);
    canvas.drawPath(path, paint);
    canvas.restore();
    paint.delete();
  }
  const body = new CK.Paint();
  body.setAntiAlias(true);
  if (ink) {
    body.setColor(ink);
  } else {
    body.setShader(metal(CK, [left, top], [left + width, top + crownHeight(width)]));
  }
  canvas.drawPath(path, body);
  body.delete();
  path.delete();
  if (ink) return;
  const jewel = new CK.Paint();
  jewel.setAntiAlias(true);
  jewel.setColor(hexColor(CK, palette.jewel));
  for (const x of JEWELS) canvas.drawCircle(left + x * k, top + JEWEL_Y * k, JEWEL_R * k, jewel);
  jewel.delete();
}
