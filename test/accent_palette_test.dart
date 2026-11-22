import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  tearDown(() => GlassTheme.setAccent(GlassTheme.defaultAccent));

  test('preset ids are unique and every preset reads on the background', () {
    final ids = GlassTheme.accents.map((accent) => accent.id).toSet();
    expect(ids.length, GlassTheme.accents.length);
    for (final accent in GlassTheme.accents) {
      expect(
        _contrast(accent.primary, GlassTheme.background),
        greaterThanOrEqualTo(4.5),
        reason: accent.id,
      );
    }
  });

  test('a custom accent of any hue reads on the background', () {
    for (var hue = 0.0; hue < 360; hue += 15) {
      for (final saturation in [.35, .7, 1.0]) {
        for (final lightness in [.1, .5, .95]) {
          final palette = AccentPalette.custom(
            HSLColor.fromAHSL(1, hue, saturation, lightness).toColor(),
          );
          expect(
            _contrast(palette.primary, GlassTheme.background),
            greaterThanOrEqualTo(4.5),
            reason: '$hue $saturation $lightness',
          );
        }
      }
    }
  });

  test('saved ids load back: presets, custom colours, and bad values', () {
    for (final accent in GlassTheme.accents) {
      expect(AccentPalette.fromId(accent.id), same(accent));
    }
    final custom = AccentPalette.custom(const Color(0xFF3D9EE0));
    expect(custom.isCustom, isTrue);
    expect(custom.id, matches(RegExp(r'^custom:[0-9a-f]{6}$')));
    final loaded = AccentPalette.fromId(custom.id)!;
    expect(loaded.id, custom.id);
    expect(loaded.primary, custom.primary);
    for (final bad in [
      null,
      '',
      'pink',
      'custom:',
      'custom:zzzzzz',
      'custom:12',
    ]) {
      expect(AccentPalette.fromId(bad), isNull, reason: '$bad');
    }
  });

  test('green is the default, first among the presets; a coral saved before '
      'green turns green once; one picked since stays coral', () async {
    expect(GlassTheme.defaultAccent, same(GlassTheme.green));
    expect(GlassTheme.accents.first, same(GlassTheme.green));
    // Classic chosen, no accent picked: green.
    SharedPreferences.setMockInitialValues({'onfeed.appearance.theme': ''});
    final classic = AccentSettingsController();
    await classic.load();
    expect(classic.theme, isNull);
    expect(classic.value, same(GlassTheme.green));
    expect(GlassTheme.primary, GlassTheme.green.primary);
    // Coral saved when it was Classic's default: green, and saved so.
    SharedPreferences.setMockInitialValues({
      'onfeed.appearance.theme': '',
      'onfeed.appearance.accent': 'coral',
    });
    final legacy = AccentSettingsController();
    await legacy.load();
    expect(legacy.value, same(GlassTheme.green));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('onfeed.appearance.accent'), 'green');

    // Coral picked after that: kept, launch after launch.
    await legacy.update(GlassTheme.coral);
    final relaunched = AccentSettingsController();
    await relaunched.load();
    expect(relaunched.value, same(GlassTheme.coral));
    final again = AccentSettingsController();
    await again.load();
    expect(again.value, same(GlassTheme.coral));

    // No accent saved, then coral picked: kept too.
    SharedPreferences.setMockInitialValues({'onfeed.appearance.theme': ''});
    final fresh = AccentSettingsController();
    await fresh.load();
    await fresh.update(GlassTheme.coral);
    final next = AccentSettingsController();
    await next.load();
    expect(next.value, same(GlassTheme.coral));
  });

  test('the controller restores a saved custom accent and falls back to '
      'green', () async {
    final custom = AccentPalette.custom(const Color(0xFF8E44AD));
    SharedPreferences.setMockInitialValues({});
    final writer = AccentSettingsController();
    await writer.update(custom);
    final reader = AccentSettingsController();
    await reader.load();
    expect(reader.value.id, custom.id);
    expect(GlassTheme.primary, custom.primary);

    SharedPreferences.setMockInitialValues({});
    final fresh = AccentSettingsController();
    await fresh.load();
    // The picked accent is the default, green; a fresh device shows Living
    // Room's own.
    expect(fresh.accent, same(GlassTheme.green));
    expect(fresh.theme, SupporterTheme.livingRoom);
    expect(fresh.value.primary, SupporterTheme.livingRoom.primary);
  });

  test('on Windows, a fresh device is Classic with the green accent; a '
      'theme picked there stays', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    SharedPreferences.setMockInitialValues({});
    final fresh = AccentSettingsController();
    await fresh.load();
    expect(fresh.theme, isNull);
    expect(fresh.value, same(GlassTheme.green));
    expect(GlassTheme.primary, GlassTheme.green.primary);

    SharedPreferences.setMockInitialValues({
      'onfeed.appearance.theme': SupporterTheme.livingRoom.id,
    });
    final chosen = AccentSettingsController();
    await chosen.load();
    expect(chosen.theme, SupporterTheme.livingRoom);
    expect(chosen.value.primary, SupporterTheme.livingRoom.primary);
  });
}
