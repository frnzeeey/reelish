import 'package:flutter/material.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/screens/first_run_consent_screen.dart';
import 'src/services/perf_timeline.dart';
import 'src/services/player_engine.dart';
import 'src/services/accent_settings_controller.dart';
import 'src/theme/glass_theme.dart';

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

  @override
  void dispose() {
    _accentSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _accentSettings,
    builder: (context, _) => MaterialApp(
      title: 'Reelish',
      debugShowCheckedModeBanner: false,
      theme: GlassTheme.dark,
      home: _StartupScreen(accentSettings: _accentSettings),
    ),
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
  /// first screen and its colors. Network work (catalog, plugins, update
  /// checks) starts from Home after its first frame.
  Future<bool> _initialize() async {
    final results = await Future.wait<Object?>([
      FirstRunConsentScreen.hasAccepted().catchError((Object _) => false),
      // A failed read keeps the default accent rather than blocking startup.
      widget.accentSettings.load().catchError((Object _) {}),
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
