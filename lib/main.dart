import 'package:flutter/material.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'src/screens/home_screen.dart';
import 'src/theme/glass_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Use libmpv on Android for better format, codec, and stream protocol
  // compatibility while retaining the existing video_player UI/controller.
  VideoPlayerMediaKit.ensureInitialized(android: true);
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
