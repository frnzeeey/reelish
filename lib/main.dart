import 'package:flutter/material.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/first_run_consent_screen.dart';
import 'src/services/player_engine.dart';
import 'src/theme/glass_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PlayerEngineBootstrap.initialize();
  runApp(const ReelishApp());
}

class ReelishApp extends StatelessWidget {
  const ReelishApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Reelish',
    debugShowCheckedModeBanner: false,
    theme: GlassTheme.dark,
    home: const _StartupScreen(),
  );
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

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
    if (hasAcceptedDocuments) return const HomeScreen();
    return FirstRunConsentScreen(
      onAccepted: () => setState(() => _hasAcceptedDocuments = true),
    );
  }
}
