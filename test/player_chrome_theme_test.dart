import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/intro_skip/skip_segments.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/theme/theme_tokens.dart';
import 'package:onfeed/src/widgets/player/skip_segment_button.dart';

/// The player's panels take the theme's own dark surface, never a fixed
/// colour, and stay dark in every theme (CLAUDE.md: GlassTheme.playerSurfaces).
void main() {
  tearDown(() => GlassTheme.setSurfaces(ThemeSurfaces.classic));

  Future<Color?> skipBackground(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.player(tv: false),
        home: Scaffold(
          body: Center(
            child: SkipSegmentButton(
              segment: const SkipSegment(
                kind: SkipKind.intro,
                start: Duration(seconds: 5),
                end: Duration(seconds: 60),
                confidence: 1,
                submissions: 3,
              ),
              onSkip: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    return button.style?.backgroundColor?.resolve(const {});
  }

  testWidgets('Skip follows the theme\'s dark surface', (tester) async {
    GlassTheme.setSurfaces(SupporterTheme.livingRoom.surfaces);
    expect(
      await skipBackground(tester),
      SupporterTheme.livingRoom.surfaces.surface.withValues(alpha: .9),
    );
  });

  testWidgets('and on a light theme stays dark', (tester) async {
    GlassTheme.setSurfaces(SupporterTheme.ivoryStudio.surfaces);
    final color = (await skipBackground(tester))!;
    expect(color, GlassTheme.playerSurfaces.surface.withValues(alpha: .9));
    expect(color.computeLuminance(), lessThan(.1));
  });
}
