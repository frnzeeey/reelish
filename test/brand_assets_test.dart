import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/screens/splash_screen.dart';
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
}
