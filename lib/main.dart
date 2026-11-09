import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/account/account_controller.dart';
import 'src/account/supporter_controller.dart';
import 'src/account/profile_controller.dart';
import 'src/account/watchlist_sync.dart';
import 'src/diagnostics/crash_reporter.dart';
import 'src/notifications/episode_alerts.dart';
import 'src/platform/desktop_gamepad.dart';
import 'src/platform/desktop_window.dart';
import 'src/platform/device_capabilities.dart';
import 'src/platform/splash_art.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/sign_in_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/screens/first_run_consent_screen.dart';
import 'src/services/perf_timeline.dart';
import 'src/services/player_engine.dart';
import 'src/services/accent_settings_controller.dart';
import 'src/theme/glass_theme.dart';
import 'src/widgets/tv/tv_focus.dart';

/// WorkManager's entry point for the new-episode check (Android). It stays
/// in this library: see [runEpisodeAlertsTask].
@pragma('vm:entry-point')
void episodeAlertsDispatcher() => runEpisodeAlertsTask();

Future<void> main() async {
  PerfTimeline.appStarted();
  WidgetsFlutterBinding.ensureInitialized();
  CrashReporter.instance.install();
  PlayerEngineBootstrap.initialize();
  // One local preference read, so the splash draws the right artwork (the
  // Founder's crest or the logo) from its first frame; the system splash, or
  // on Windows the still hidden window, covers it.
  await SplashArtStore.instance.load();
  runApp(const ReelishApp());
  // After the first frame, so it costs startup nothing; errors before then
  // are held.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(CrashReporter.instance.load()),
  );
}

class ReelishApp extends StatefulWidget {
  const ReelishApp({super.key});

  @override
  State<ReelishApp> createState() => _ReelishAppState();
}

class _ReelishAppState extends State<ReelishApp> {
  // Loaded once, by the splash gate, before the first screen appears.
  final _accentSettings = AccentSettingsController();

  /// Focuses a control in each dialog and sheet on TV.
  final _popupFocus = TvPopupFocusObserver();

  /// Lets desktop keyboard shortcuts go back from any screen.
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// The look last drawn: accent and page colours.
  Object? _look;

  @override
  void initState() {
    super.initState();
    _accentSettings.addListener(_lookChanged);
  }

  /// Screens read the theme's colours through GlassTheme as they build, not
  /// only through Theme.of, so a new look rebuilds every element once,
  /// after this frame. Navigation and state are kept; nothing is recreated.
  void _lookChanged() {
    final look = (GlassTheme.accent.id, GlassTheme.surfaces);
    if (look == _look) return;
    final first = _look == null;
    _look = look;
    if (first) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    });
  }

  @override
  void dispose() {
    _accentSettings
      ..removeListener(_lookChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // The device is known before the splash gate opens, so a TV gets its
    // theme and remote navigation before the first screen appears.
    animation: Listenable.merge([
      _accentSettings,
      DeviceCapabilities.listenable,
    ]),
    builder: (context, _) {
      final tv = DeviceCapabilities.usesTvLayout;
      return MaterialApp(
        title: 'Reelish',
        debugShowCheckedModeBanner: false,
        theme: tv ? GlassTheme.tv : GlassTheme.dark,
        // A new theme fades in, except under reduced motion.
        themeAnimationDuration:
            MediaQueryData.fromView(View.of(context)).disableAnimations
            ? Duration.zero
            : kThemeAnimationDuration,
        navigatorKey: _navigatorKey,
        navigatorObservers: [if (tv) _popupFocus],
        builder: (context, child) {
          // Status bar icons that read on the theme's pages: dark ones on a
          // light theme. The player sets its own while it plays.
          final content = AnnotatedRegion<SystemUiOverlayStyle>(
            value: GlassTheme.surfaces.brightness == Brightness.light
                ? SystemUiOverlayStyle.dark
                : SystemUiOverlayStyle.light,
            child: child!,
          );
          return DeviceCapabilities.isDesktopPlatform
              ? DesktopGamepad(
                  navigatorKey: _navigatorKey,
                  child: DesktopShortcuts(
                    navigatorKey: _navigatorKey,
                    child: content,
                  ),
                )
              : content;
        },
        home: _StartupScreen(accentSettings: _accentSettings),
      );
    },
  );
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen({required this.accentSettings});

  final AccentSettingsController accentSettings;

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  bool _acceptedThisSession = false;

  // This launch's, read before the store updates them for the next one.
  final _splashArt = SplashArtStore.instance.art;
  final _nativeSplashArt = SplashArtStore.instance.nativeArt;

  /// Critical startup only: two local preference reads that decide the
  /// first screen and its colors, and the device type that decides between
  /// the mobile and TV interfaces. Network work (catalog, plugins, update
  /// checks) starts from Home after its first frame.
  Future<bool> _initialize() async {
    final results = await Future.wait<Object?>([
      FirstRunConsentScreen.hasAccepted().catchError((Object _) => false),
      // A failed read keeps the default accent rather than blocking startup.
      widget.accentSettings.load().catchError((Object _) {}),
      // Never fails; an unanswered query keeps the mobile interface.
      DeviceCapabilities.load(),
      // A local secure-storage read; the network is not touched.
      AccountController.instance.restore(),
    ]);
    // A local read: the saved supporter status, so an app theme's accent is
    // right on the first screen. The server is asked once Home has drawn.
    try {
      await SupporterController.instance.restoreSaved();
    } catch (_) {
      // The accent the user picked shows until the server answers.
    }
    // The next launch screen follows the account: the crest for the Founder.
    SplashArtStore.instance.attach(
      AccountController.instance,
      SupporterController.instance,
    );
    // The device-local profile follows whichever Trakt account is signed in.
    ProfileController.instance.attach(AccountController.instance);
    // My list and the Trakt watchlist, when the user turned that on.
    WatchlistSync.instance.attach(AccountController.instance);
    // New-episode alerts (Android phones and Windows; off until turned on).
    if (EpisodeAlerts.supported) {
      try {
        await EpisodeAlerts.initializeBackground(episodeAlertsDispatcher);
      } catch (_) {
        // Alerts then check only while the app runs.
      }
      EpisodeAlerts.instance.attach(AccountController.instance);
    }
    return results.first! as bool;
  }

  @override
  Widget build(BuildContext context) => SplashGate<bool>(
    initialize: _initialize,
    art: _splashArt,
    nativeArt: _nativeSplashArt,
    builder: (context, hasAcceptedDocuments) {
      if (hasAcceptedDocuments || _acceptedThisSession) {
        // The catalog needs a Trakt sign-in; Home appears once signed in.
        return AccountGate(
          account: AccountController.instance,
          child: HomeScreen(accentSettings: widget.accentSettings),
        );
      }
      return FirstRunConsentScreen(
        onAccepted: () => setState(() => _acceptedThisSession = true),
      );
    },
  );
}
