// Reelish's design tokens: the spacing, radius, type, icon and motion steps
// every interface draws from. Colours live in `GlassTheme`
// (`glass_theme.dart`). The steps are the values the screens already use
// most, so adopting a token does not change how a screen looks; new and
// refined UI should pick from here instead of inventing a value.
//
// Platform layouts keep their own metrics on top of these:
// `DesktopMetrics`/`DesktopSurfaces` (Windows), `SettingsMetrics` (phone
// settings) and the TV widgets' sizes, which are tuned for viewing distance.

import 'package:flutter/widgets.dart';

/// Spacing on a 4 dp grid: padding, gaps and section spacing.
abstract final class AppSpace {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

/// Corner radii, smallest to largest.
abstract final class AppRadius {
  /// Progress tracks and thin bars.
  static const xs = 4.0;

  /// Badges and small chips.
  static const sm = 8.0;

  /// Inputs, list tiles and compact buttons.
  static const md = 12.0;

  /// Windows cards and panels (`DesktopSurfaces.radius`).
  static const card = 14.0;

  /// Dialogs, sheets and grouped settings.
  static const lg = 16.0;

  /// Phone poster cards and settings sections.
  static const xl = 20.0;

  /// Floating surfaces such as the dock and large sheets.
  static const xxl = 28.0;

  /// Fully round ends: pills, chips, round icon buttons.
  static const pill = 999.0;
}

/// Font sizes of the type scale, for a `TextStyle` that needs its own weight
/// or colour. The smallest is [micro]; nothing on screen goes below it.
abstract final class AppTextSize {
  static const micro = 10.0;
  static const caption = 11.0;
  static const label = 12.0;
  static const bodySmall = 13.0;
  static const body = 14.0;
  static const titleSmall = 15.0;
  static const bodyLarge = 16.0;
  static const title = 18.0;
  static const titleLarge = 20.0;
  static const headline = 24.0;
  static const display = 32.0;
}

/// The type scale. Styles carry size, weight and line height only; colour
/// and the Montserrat family come from the surrounding theme, so use them
/// as-is or `copyWith` a colour.
abstract final class AppType {
  /// Hero and page titles on large screens.
  static const display = TextStyle(
    fontSize: AppTextSize.display,
    fontWeight: FontWeight.w800,
    height: 1.1,
    letterSpacing: -.5,
  );

  /// Page and section headers.
  static const headline = TextStyle(
    fontSize: AppTextSize.headline,
    fontWeight: FontWeight.w800,
    height: 1.15,
    letterSpacing: -.35,
  );

  /// Row titles, dialog titles.
  static const title = TextStyle(
    fontSize: AppTextSize.title,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );

  /// Card titles and list item titles.
  static const titleSmall = TextStyle(
    fontSize: AppTextSize.titleSmall,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );

  /// Synopses and paragraphs.
  static const body = TextStyle(
    fontSize: AppTextSize.body,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  /// Secondary paragraphs and descriptions.
  static const bodySmall = TextStyle(
    fontSize: AppTextSize.bodySmall,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  /// Buttons and emphasised metadata.
  static const label = TextStyle(
    fontSize: AppTextSize.label,
    fontWeight: FontWeight.w700,
  );

  /// Metadata lines under titles.
  static const caption = TextStyle(
    fontSize: AppTextSize.caption,
    fontWeight: FontWeight.w600,
  );

  /// Upper-case badges and eyebrow labels. The smallest text Reelish
  /// draws; nothing on screen goes below it.
  static const micro = TextStyle(
    fontSize: AppTextSize.micro,
    fontWeight: FontWeight.w800,
    letterSpacing: .8,
  );
}

/// Icon sizes.
abstract final class AppIcon {
  static const xs = 14.0;
  static const sm = 18.0;
  static const md = 22.0;
  static const lg = 28.0;
  static const xl = 36.0;
}

/// Motion: durations by what moves and how far, and the curves to pair
/// with them. Read a duration through [resolve] so the system's
/// reduce-motion setting turns it off.
abstract final class AppMotion {
  /// Press feedback: a card sinking under a finger.
  static const press = Duration(milliseconds: 120);

  /// Hover and focus highlights; small state changes.
  static const hover = Duration(milliseconds: 180);

  /// Selection changes, toggles, panels opening in place.
  static const standard = Duration(milliseconds: 220);

  /// A pushed page.
  static const page = Duration(milliseconds: 240);

  /// A larger move: a carousel page, a rail scrolling back.
  static const emphasized = Duration(milliseconds: 480);

  /// Full-bleed artwork crossfading behind content.
  static const crossfade = Duration(milliseconds: 700);

  /// Arriving: fast start, gentle stop.
  static const enter = Curves.easeOutCubic;

  /// Leaving: gentle start, fast finish.
  static const exit = Curves.easeInCubic;

  /// Moving between two resting places.
  static const move = Curves.easeInOutCubic;

  /// [duration], or zero when the system asks for reduced motion.
  static Duration resolve(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

  /// An exit timed at about two thirds of its entrance [duration], so
  /// dismissing feels quicker than arriving.
  static Duration exitOf(Duration duration) =>
      Duration(microseconds: (duration.inMicroseconds * 2 / 3).round());
}
