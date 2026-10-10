import 'package:flutter/material.dart';
import 'src/platform/device_capabilities.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/screens/first_run_consent_screen.dart';
import 'src/services/perf_timeline.dart';
import 'src/services/player_engine.dart';
import 'src/services/accent_settings_controller.dart';
import 'src/theme/glass_theme.dart';
import 'src/widgets/tv/tv_focus.dart';

void main() {
  PerfTimeline.appStarted();
  WidgetsFlutterBinding.ensureInitialized();
  PlayerEngineBootstrap.initialize();
  runApp(const ReelishApp());
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

  @override
  void dispose() {
    _accentSettings.dispose();
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
      final tv = DeviceCapabilities.isTv;
      return MaterialApp(
        title: 'Reelish',
        debugShowCheckedModeBanner: false,
        theme: tv ? GlassTheme.tv : GlassTheme.dark,
        navigatorObservers: [if (tv) _popupFocus],
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
    ]);
    return results.first! as bool;
  }

  @override
  Widget build(BuildContext context) => SplashGate<bool>(
    initialize: _initialize,
    builder: (context, hasAcceptedDocuments) {
      if (hasAcceptedDocuments || _acceptedThisSession) {
        return HomeScreen(accentSettings: widget.accentSettings);
      }
      return FirstRunConsentScreen(
        onAccepted: () => setState(() => _acceptedThisSession = true),
      );
    },
  );
}
