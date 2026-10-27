---
name: ui-refinement
description: Visual and interaction work on Reelish's phone, TV or Windows interface — layout, spacing, typography, cards, hover/focus states, motion, responsiveness — within the existing coral glass design system. Use for UI polish, redesign of a screen, overflow/clipping bugs, or animation changes.
argument-hint: "[screen or platform]"
---

# UI refinement

## Purpose
Improve how a screen looks and feels on its own platform while keeping
behaviour, navigation and the other platforms unchanged. Outcome: verified
visual changes at real window/screen sizes, with no regressions in focus,
touch or keyboard use.

## Activation
- Polish, refinement or redesign of a screen; spacing, density, hierarchy.
- Overflow, clipping, broken hover/focus, janky or missing motion.
- Changes under `lib/src/desktop/`, `lib/src/screens/`, `lib/src/widgets/`.

## Codebase context
- Tokens: `GlassTheme` (`lib/src/theme/glass_theme.dart`): background
  `0xFF0B0B0F`, surfaces, accent palettes (coral `#FF4D6D` default; the
  user can change it, so read `GlassTheme.primary`, never hard-code coral),
  Montserrat font, and `warning`/`danger` status colours. Spacing, radius,
  type scale, icon sizes and motion durations/curves are in `AppSpace`,
  `AppRadius`, `AppTextSize`/`AppType`, `AppIcon` and `AppMotion`
  (`lib/src/theme/design_tokens.dart`; 10 pt is the smallest text, 14 pt
  on TV). Pick from them in new or refined UI, and run animation
  durations through `AppMotion.resolve`. Settings and plugin pages already
  use them. Windows adds `DesktopMetrics`, `DesktopSurfaces`,
  `desktopMotion()` and `posterDecodeWidth()` in `desktop_widgets.dart`.
- Phone: `SoftGlassDock`, `MediaCard`, `LiquidGlass`/`GlassBox`.
- TV: `TvFocusable`, `TvSafeArea` (overscan), `TvKeyScroll`,
  `TvTextEntryDialog`; focus rules in `docs/android_tv.md`.
- Windows: `DesktopShell` (hover-open glass sidebar, saved pin state, Ctrl+F),
  `DesktopPosterCard`, `DesktopMediaRow`, `DesktopHero`,
  `DesktopDetailsScreen` (episode panel from 1180 px),
  `DesktopSettingsPage`, `DesktopPluginsPage`.
- Shared player chrome: `lib/src/widgets/player/` (see `playback-audit`).

## Workflow
1. Render the screen at the target sizes before changing anything (see
   [render-audit.md](render-audit.md)); list concrete issues with sizes.
2. Separate real defects from artefacts of fake data.
3. Change the platform's own widgets first. A shared widget change must be
   inert elsewhere (hover-only, or gated on `isDesktop` / `isTv`).
4. Use the tokens; motion through `desktopMotion()` or
   `MediaQuery.disableAnimationsOf` so reduced motion turns it off.
5. Re-render and compare; add widget tests for layout rules that matter
   (no overlap, counts per row, no overflow at sizes).

## Safety constraints
- Keep navigation structure, destinations, shortcuts and tooltips that
  tests or users rely on (`desktop_ui_test`, `desktop_gamepad_test`,
  `tv_home_test`, `tv_support_test` check them).
- No new BackdropFilter per list item; one fixed-size blur per panel at
  most. Decode images at drawn size (`cacheWidth`).
- Don't introduce new fonts, colors outside the theme, or dependencies.
- Don't change data, playback or persistence to fix a visual issue.

## Platform considerations
- Phone: touch targets ≥ 48 dp, the dock overlaps content (clearance in
  `SettingsMetrics.dockClearance`), safe areas and camera cutouts.
- TV: everything reachable by D-pad, visible focus, overscan-safe margins
  only when `isTv`; low glass quality.
- Windows: mouse hover, keyboard focus ring, gamepad, resizable windows
  from compact (~1024) to 4K at 200 % scaling; sidebar 80 px compact,
  248 px open (over the page on hover, beside it when pinned).

## Validation
- Widget tests use the Ahem test font, much wider than Montserrat: text
  overflows that real fonts don't, and taps can hit the wrong widget. Load
  real fonts (`FontLoader`) when measuring layout; prefer real taps once
  overlaps are fixed.
- Relevant tests: `desktop_*_test`, `details_screens_test`,
  `search_library_screens_test`, `media_card_test`, `soft_glass_dock_test`,
  `tv_home_test`, `paused_overlay_test`, `settings_ui_test`.
- Build the platform; then `regression-check`.

## Completion criteria
Every listed issue is fixed or explicitly deferred; renders at all target
sizes show no overflow or clipping; tests for the touched screens pass; no
other platform's UI changed (or the shared change is justified).

## Reporting
Per CLAUDE.md § Reporting, plus: sizes rendered, before/after findings, and
any shared widget touched with why it is inert elsewhere.
