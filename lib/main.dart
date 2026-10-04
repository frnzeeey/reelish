import 'package:flutter/material.dart';
import 'src/screens/home_screen.dart';
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
  final _accentSettings = AccentSettingsController();

  @override
  void initState() {
    super.initState();
    _accentSettings.load();
  }

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
  bool? _hasAcceptedDocuments;

  @override
  void initState() {
    super.initState();
    _loadConsent();
  }

  Future<void> _loadConsent() async {
    try {
      final accepted = await FirstRunConsentScreen.hasAccepted();
      if (mounted) setState(() => _hasAcceptedDocuments = accepted);
    } catch (_) {
      if (mounted) setState(() => _hasAcceptedDocuments = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAcceptedDocuments = _hasAcceptedDocuments;
    if (hasAcceptedDocuments == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (hasAcceptedDocuments) {
      return HomeScreen(accentSettings: widget.accentSettings);
    }
    return FirstRunConsentScreen(
      onAccepted: () => setState(() => _hasAcceptedDocuments = true),
    );
  }
}
