# Icon system

Reelish draws its own icons. They come from the logo: a heavy stroke with
pill-shaped ends, and one detached solid dot.

| Piece | Where |
|---|---|
| Drawings (the source) | `tool/icons/icons.mjs` |
| Build | `tool/icons/build.mjs` (development only; nothing here ships) |
| One flattened SVG per icon | `assets/icons/svg/` |
| The font the app uses | `assets/fonts/ReelishIcons.otf` |
| The registry | `lib/src/theme/reelish_icons.dart` (generated) |
| Gallery | `lib/icon_gallery.dart` |

## Why a font

The SVGs are the design source, and the app renders them as a font rather than
parsing SVG at runtime. Every icon in the app is an `IconData`, used through
`Icon`, `IconButton`, `IconTheme`, and dozens of typed fields. A font keeps all
of that working, inherits colour and size, needs no package, and has no parse
or cache cost, which matters on TV hardware. Release builds also keep only the
glyphs the app uses.

The SVG folder is not declared in `pubspec.yaml`, so those files are not
bundled. They are for design tools and review.

## Design rules

| Rule | Value |
|---|---|
| Grid | 24 × 24, transparent |
| Safe area | Nothing outside 0.5–23.5; the build fails if it is |
| Keylines | Circle Ø 20–21, square 18, wide rectangle 19 × 13–15 |
| Stroke | 2.0; caps and joins fully round |
| Optical adjustments | 2.2 for lone diagonals and chevrons (`close`, `chevronRight`), 2.4 for `check`, 1.8 for numerals and tiny detail |
| Corners | 3.5 on large rectangles, 2.5–3 on small ones |
| The Reelish dot | A solid dot of radius 1.9 as the focal point of primary icons (`home`, `search`, `movie`, `tv`, `shield`, `calendar`) |
| Solid details | Dots of radius 1.1–1.4 for small marks such as `i` and `!` |
| Playback | Solid, with soft corners: stroked and filled triangles, pill bars |
| Slashes | `off()`: a clear gap either side of the stroke, top left to bottom right |
| Circular arrows | One true circle: centre 12, 12, radius 9, from `arc()` |
| Colour | `currentColor`; a single colour, so they work on any theme |

Do not add a dot where it would clutter (`close`, chevrons, arrows). Small icons
at 16 px are the test: if detail fills in, remove detail rather than thin the
stroke.

## Solid forms

An icon's selected form is the same name ending in `Filled`, and the dot
becomes a cut-out. A static font has no fill axis, so `Icon.fill` does nothing:

```dart
Icon(selected ? ReelishIcons.homeFilled : ReelishIcons.home)
Icon(ReelishIcons.filled(destination.icon))   // when the icon is a variable
```

`filled` returns the icon itself when it has no solid form. Every
`TvDestination` must have one: `test/reelish_icons_test.dart` checks.

## Adding or changing an icon

1. Draw it in `tool/icons/icons.mjs` with `s()` strokes, `f()` fills, `d()`
   dots, `c()` circles, `r()` rounded rectangles and `cut()`.
2. Build:

   ```sh
   cd tool/icons && npm ci && npm run build
   ```

3. Check `tool/icons/contact_sheet.png` (large and at 16 px), then the gallery:

   ```sh
   flutter run -d windows -t lib/icon_gallery.dart
   ```

Commit the drawings, `assets/icons/svg/`, the font and the registry together.
The toolchain uses Skia (through `canvaskit-wasm`) for stroking and path
operations, the same engine that draws the app, and `opentype.js` for the font.

The build fails if an icon leaves the safe area or a cut removes nothing, and it
sets each contour's direction from how deeply it is nested, because a hole
running the same way as its ring gets filled in by fonts and SVG renderers.

Use `ReelishIcons` everywhere; a test fails if `Icons.` or another set appears
in `lib/`.
