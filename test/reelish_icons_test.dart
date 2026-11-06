import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/icon_gallery.dart';
import 'package:onfeed/src/navigation/app_destination.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';

String _kebab(String name) => name.replaceAllMapped(
  RegExp('[A-Z0-9]+'),
  (match) => '-${match[0]!.toLowerCase()}',
);

Future<void> _loadFont() async {
  final bytes = File('assets/fonts/ReelishIcons.otf').readAsBytesSync();
  final loader = FontLoader('ReelishIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

void main() {
  group('The set', () {
    test('every icon has its own standalone SVG', () {
      for (final name in ReelishIcons.all.keys) {
        final file = File('assets/icons/svg/${_kebab(name)}.svg');
        expect(file.existsSync(), isTrue, reason: name);
        final svg = file.readAsStringSync();
        expect(svg, startsWith('<svg xmlns="http://www.w3.org/2000/svg"'));
        expect(svg, contains('viewBox="0 0 24 24"'), reason: name);
        expect(svg, contains('fill="currentColor"'), reason: name);
        // Nothing but vector paths: no raster, filter, mask or fixed colour.
        for (final banned in ['<image', '<filter', '<mask', 'data:', '#']) {
          expect(svg, isNot(contains(banned)), reason: '$name: $banned');
        }
      }
      expect(
        Directory('assets/icons/svg').listSync().length,
        ReelishIcons.all.length,
        reason: 'no stray SVGs',
      );
    });

    test('outlines stay light', () {
      for (final name in ReelishIcons.all.keys) {
        final size = File('assets/icons/svg/${_kebab(name)}.svg').lengthSync();
        expect(size, lessThan(4 * 1024), reason: name);
      }
    });

    test('code points are unique and in the private use area', () {
      final codes = ReelishIcons.all.values.map((icon) => icon.codePoint);
      expect(codes.toSet().length, ReelishIcons.all.length);
      for (final code in codes) {
        expect(code, inInclusiveRange(0xE000, 0xF8FF));
      }
    });

    test('each solid form belongs to an outline of the same name', () {
      for (final MapEntry(key: name, value: icon) in ReelishIcons.all.entries) {
        if (!name.endsWith('Filled')) continue;
        final outline = ReelishIcons.all[name.replaceAll('Filled', '')];
        expect(outline, isNotNull, reason: name);
        expect(ReelishIcons.filled(outline!), icon);
      }
    });

    test('an icon with no solid form stays itself', () {
      expect(ReelishIcons.filled(ReelishIcons.close), ReelishIcons.close);
      expect(ReelishIcons.filled(ReelishIcons.play), ReelishIcons.play);
    });

    test('a selected destination always changes shape', () {
      for (final destination in TvDestination.values) {
        expect(
          ReelishIcons.filled(destination.icon),
          isNot(destination.icon),
          reason: destination.name,
        );
      }
    });

    test('the font is declared, and the old icon set is gone', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: ReelishIcons'));
      expect(pubspec, contains('assets/fonts/ReelishIcons.otf'));
      expect(pubspec, isNot(contains('material_symbols_icons')));
      final strays = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) {
            final text = file.readAsStringSync();
            return RegExp(r'\b(Symbols|CupertinoIcons)\.').hasMatch(text) ||
                RegExp(r'\bIcons\.[a-z]').hasMatch(text);
          })
          .map((file) => file.path);
      expect(strays, isEmpty);
    });

    test('nothing in the app reaches the gallery', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('icon_gallery')));
    });
  });

  group('Rendering', () {
    testWidgets('color and size come from the theme, as any icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IconTheme(
            data: IconThemeData(color: Color(0xFF123456), size: 30),
            child: Icon(ReelishIcons.home),
          ),
        ),
      );
      final text = tester.widget<RichText>(find.byType(RichText));
      final style = text.text.style!;
      expect(style.fontFamily, 'ReelishIcons');
      expect(style.color, const Color(0xFF123456));
      expect(style.fontSize, 30);
    });

    testWidgets('a cut-out stays open in the font', (tester) async {
      await _loadFont();
      const key = Key('glyph');
      Future<int> alphaAtCentre(IconData icon) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: Icon(icon, size: 48, color: Colors.white),
              ),
            ),
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage();
          return image.toByteData();
        });
        return bytes!.getUint8((24 * 48 + 24) * 4 + 3);
      }

      // A hole running the same way as its ring would be filled in.
      expect(await alphaAtCentre(ReelishIcons.blockedFilled), 0);
      expect(await alphaAtCentre(ReelishIcons.dot), 255);
    });

    testWidgets('the gallery shows the whole set without a layout error', (
      tester,
    ) async {
      await _loadFont();
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const IconGalleryApp());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('home'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'volume');
      await tester.pump();
      expect(find.text('volumeUp'), findsOneWidget);
      expect(find.text('home'), findsNothing);
    });
  });
}
