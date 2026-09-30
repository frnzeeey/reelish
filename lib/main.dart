import 'package:flutter/material.dart';
import 'src/screens/home_screen.dart';
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
    title: 'reelish',
    debugShowCheckedModeBanner: false,
    theme: GlassTheme.dark,
    home: const HomeScreen(),
  );
}
