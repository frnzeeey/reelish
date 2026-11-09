# Launch screen

What shows between tapping Reelish and its first screen, on each platform,
and the Founder's Sovereign Crest version of it.

## Layers

| Platform | What draws it | Artwork |
|---|---|---|
| Android 12 and later | The system splash: `LaunchTheme` in `values-v31` / `values-night-v31` (`windowSplashScreenAnimatedIcon` = `splash_icon.xml`, a 22.2% inset that shows the 846 px canvas at 160 dp) | `drawable-nodpi/reelish_splash.png` |
| Android before 12 | `launch_background.xml`, the window background (160 dp, centred) | the same |
| Windows | Nothing: the window stays hidden until Flutter's first frame (`flutter_window.cpp`) | none |
| All | Flutter's `SplashView` inside `SplashGate` ([`splash_screen.dart`](../../lib/src/screens/splash_screen.dart)), while `_StartupScreen._initialize` restores local state | `SplashSpec.logoAsset`, at `SplashSpec.logoSize` (160 dp) |

The background is `SplashSpec.background` (`#0B0B0F`) everywhere, fixed
rather than the theme's, because the system splash cannot follow a theme.
On Android, Flutter's first frame continues the system splash exactly: it
waits (at most 400 ms) for the artwork to decode, draws it at full opacity
in the same place, and only a soft glow blooms behind it. Elsewhere the
artwork fades and scales in (0.94 to 1). There is no minimum display time;
a slim progress bar appears after 1.2 s and a retry after 10 s. Reduced
motion skips the entrance and the fade to the first screen.

## The Founder's Sovereign Crest

For the Founder (`FounderPerk.founderSplash`,
[Founder perks](../backend/entitlements.md#founder-perks)) the launch screen
shows the Sovereign Crest, the [Founder Collection icon](app-icons.md#the-founder-collection)'s
wreath, crown and gold mark, with a champagne-over-violet glow in place of
the coral one. It follows the account, not the chosen icon or theme.

The splash shows before any account is restored, so `SplashArtStore`
([`splash_art.dart`](../../lib/src/platform/splash_art.dart)) keeps the
choice on the device:

1. `main()` reads it (one local preference read) before the first frame.
2. Once `_initialize` has restored the saved supporter status,
   `SplashArtStore.attach` follows the account and the supporter status: the
   crest for a signed-in Founder, the logo for anyone else or no one. A
   change (signing out, another account, the server no longer answering
   Founder) applies from the next launch.
3. On Android it also sets the system splash through `onfeed/splash`
   (`ReelishActivity`): on Android 13 and later
   `SplashScreen.setSplashScreenTheme` applies `SovereignSplashTheme`
   (`splash_icon_sovereign_crest.xml`) or resets it, and the system keeps
   that for later launches. This runs every launch, so the system's stored
   theme can never drift from the app's record. The style is stored by name:
   never rename it.

Android 12 and earlier cannot change their system splash, so it shows the
logo; Flutter's first frame draws the logo too and cross-fades to the crest
(about 450 ms), so nothing jumps. Windows reveals the crest directly.

Like every Founder cosmetic it unlocks nothing; a changed local value
changes only this device's launch screen.

**Artwork:** `tool/branding/generate_sovereign_crest.mjs` draws the crest
again from its shapes at 846 px (not the 432 px icon scaled up), with the
wreath spanning 64% of the canvas, to match the Reelish logo's weight. It
writes `drawable-nodpi/sovereign_crest_splash.png` and the identical
`assets/icons/sovereign_crest_splash.png`.

## Tests

`splash_screen_test` (first frame, reveal, the crest and its cross-fade,
progress, retry), `splash_art_test` (the Founder, a Supporter, sign-out, a
revoked status, Android 12, Windows, the per-launch system update),
`brand_assets_test`.

Not covered by tests: the system splash itself, which needs a device
(Android 13+ for the crest).
