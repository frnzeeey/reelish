import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/screens/splash_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/brand_logo.dart';

void main() {
  test('every brand image is bundled and decodes at 846 × 846', () async {
    for (final asset in [
      BrandAssets.appIcon,
      BrandAssets.primaryLogo,
      BrandAssets.logoIcon,
      BrandAssets.wordLogo,
    ]) {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 846, reason: asset);
      expect(frame.image.height, 846, reason: asset);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('the splash shows the primary logo', () {
    expect(SplashSpec.logoAsset, BrandAssets.primaryLogo);
  });

  for (final (name, widget, bounds) in [
    ('wordmark', const ReelishWordmark(height: 16), BrandAssets.wordLogoBounds),
    ('mark', const ReelishMark(height: 16), BrandAssets.logoIconBounds),
  ]) {
    testWidgets('the $name is drawn at its height, in its proportions, and '
        'reads as Reelish', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Center(child: widget)));
      final size = tester.getSize(find.byWidget(widget));
      expect(size.height, moreOrLessEquals(16, epsilon: .01));
      expect(
        size.width,
        moreOrLessEquals(16 * bounds.width / bounds.height, epsilon: .01),
      );
      expect(find.bySemanticsLabel('Reelish'), findsOneWidget);
    });
  }

  group('AccentAppIcon', () {
    tearDown(() => GlassTheme.setAccent(GlassTheme.coral));

    test('every built-in accent has icon artwork of its colour', () async {
      expect(AccentAppIcon.assetFor('coral'), BrandAssets.appIcon);
      for (final accent in GlassTheme.accents) {
        final asset = AccentAppIcon.assetFor(accent.id);
        expect(asset, isNotNull, reason: accent.id);
        // Bundled, so the icon never falls back to a broken image.
        await rootBundle.load(asset!);
      }
      expect(AccentAppIcon.assetFor('custom:123456'), isNull);
    });

    testWidgets('follows the accent, and draws a tile for a custom colour', (
      tester,
    ) async {
      GlassTheme.setAccent(GlassTheme.teal);
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: AccentAppIcon(size: 40))),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as ResizeImage).imageProvider,
        isA<AssetImage>().having(
          (a) => a.assetName,
          'asset',
          'assets/images/app_icons/teal.png',
        ),
      );

      GlassTheme.setAccent(AccentPalette.custom(const Color(0xFF123456)));
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: AccentAppIcon(key: ValueKey('c'), size: 40)),
        ),
      );
      expect(find.byType(ReelishMark), findsOneWidget);
      expect(find.bySemanticsLabel('Reelish'), findsOneWidget);
    });
  });
}
