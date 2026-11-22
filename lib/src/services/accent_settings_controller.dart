// The app's look on this device: the accent colour and an app theme (the free
// Living Room look by default, the supporter themes for accounts with the
// perk). A theme sets the colours of every screen
// (GlassTheme's page tokens and accent) and dresses the profile card; an
// accent picked under a theme replaces only the theme's accent. Like the
// accent it is a device setting, and it applies only while the signed-in
// account has the perk (the Founder's own perk for the Founder Collection);
// otherwise Classic and the picked accent return, and the saved theme waits.
import 'package:flutter/foundation.dart';

import '../account/supporter_controller.dart';
import '../platform/device_capabilities.dart';
import '../theme/glass_theme.dart';
import '../theme/supporter_themes.dart';
import '../theme/theme_tokens.dart';
import 'storage_service.dart';
import '../analytics/analytics_events.dart';
import '../analytics/analytics_service.dart';

class AccentSettingsController extends ChangeNotifier {
  AccentSettingsController({
    StorageService? storage,
    SupporterController? supporters,
  }) : _storage = storage ?? StorageService(),
       _supporters = supporters ?? SupporterController.instance {
    _supporters.addListener(_apply);
  }

  static const _key = 'onfeed.appearance.accent';
  static const _themeKey = 'onfeed.appearance.theme';

  /// Set once a saved accent has been read under the green default, so a
  /// coral saved before then turns green only once (see [load]).
  static const _coralRetiredKey = 'onfeed.appearance.coral_retired';

  /// '0' when the picked accent replaces the theme's own; anything else
  /// (including no value, as every device had before) keeps the theme's.
  static const _themeAccentKey = 'onfeed.appearance.theme_accent';
  final StorageService _storage;
  final SupporterController _supporters;
  AccentPalette _accent = GlassTheme.defaultAccent;
  String? _themeId;
  bool _themeAccent = true;

  /// Whose perks decide whether a theme applies.
  SupporterController get supporters => _supporters;

  /// The accent the user picked, used whenever no theme applies.
  AccentPalette get accent => _accent;

  /// The saved theme's id, whether or not it applies now.
  String? get themeId => _themeId;

  /// The theme in effect: the saved one, while the account has its perk.
  SupporterTheme? get theme {
    final saved = SupporterTheme.byId(_themeId);
    return saved != null && mayUse(saved) ? saved : null;
  }

  /// Whether this account has [theme]'s perk, as last known: the supporter
  /// perk for the supporter themes, the Founder's own for the Founder
  /// Collection, which no donation unlocks.
  bool mayUse(SupporterTheme theme) => switch (theme.collection) {
    ThemeCollection.reelish => true,
    ThemeCollection.supporter => _supporters.has(SupporterPerk.appThemes),
    ThemeCollection.founder => _supporters.hasFounderPerk(
      FounderPerk.founderThemes,
    ),
  };

  /// Whether the theme's own accent shows, rather than the picked one.
  bool get usesThemeAccent => _themeAccent;

  /// The accent in effect across the app: the theme's, unless the user
  /// picked one to use with it.
  AccentPalette get value {
    final theme = this.theme;
    return theme != null && _themeAccent ? theme.accent : _accent;
  }

  /// The page colours in effect: the theme's, or Classic.
  ThemeSurfaces get surfaces => theme?.surfaces ?? ThemeSurfaces.classic;

  Future<void> load() async {
    final id = await _storage.readSetting(_key);
    // A preset id, or `custom:rrggbb`; anything else is the default (green).
    _accent = AccentPalette.fromId(id) ?? GlassTheme.defaultAccent;
    // Coral was Classic's default before green, so a saved coral is
    // switched to green, once. The mark keeps a coral picked after that.
    if (await _storage.readSetting(_coralRetiredKey) == null) {
      if (_accent == GlassTheme.coral) {
        _accent = GlassTheme.defaultAccent;
        await _storage.saveSetting(_key, _accent.id);
      }
      await _storage.saveSetting(_coralRetiredKey, '1');
    }
    // Retired theme ids open as the theme that replaced them. No value at
    // all means no theme was ever chosen: the Reelish look on phone and TV,
    // Classic (Reelish black with the green accent) on Windows. Classic
    // chosen in the picker is saved as '' and stays Classic; a theme picked
    // on Windows is saved, so it stays too.
    final theme = await _storage.readSetting(_themeKey);
    _themeId = theme == null
        ? (DeviceCapabilities.isDesktopPlatform
              ? null
              : SupporterTheme.standard.id)
        : SupporterTheme.byId(theme)?.id;
    final themeAccent = await _storage.readSetting(_themeAccentKey);
    // Someone who picked an accent before the Reelish look existed keeps
    // it on the new pages, until they choose the theme's own.
    _themeAccent = themeAccent == null
        ? theme != null || id == null
        : themeAccent != '0';
    _apply();
  }

  void _apply() {
    GlassTheme.setAccent(value);
    GlassTheme.setSurfaces(surfaces);
    notifyListeners();
  }

  /// Uses [value] as the accent. With a theme on, the theme stays and the
  /// accent replaces its own; [useThemeAccent] goes back to the theme's.
  Future<void> update(AccentPalette value) async {
    _accent = value;
    final hadThemeAccent = _themeAccent;
    if (theme != null) _themeAccent = false;
    _apply();
    AnalyticsService.instance.log(
      AnalyticsEvent.featureUsed(AnalyticsFeature.accentChange),
    );
    await _storage.saveSetting(_key, value.id);
    // A picked coral is a choice, never the retired default.
    await _storage.saveSetting(_coralRetiredKey, '1');
    if (hadThemeAccent != _themeAccent) {
      await _storage.saveSetting(_themeAccentKey, '0');
    }
  }

  /// Shows the theme's own accent again.
  Future<void> useThemeAccent() async {
    if (_themeAccent) return;
    _themeAccent = true;
    _apply();
    await _storage.saveSetting(_themeAccentKey, '1');
  }

  /// Uses the theme [id], or none for null, with its own accent, and says
  /// whether it did. A theme is taken only when the account has its perk;
  /// the screen lets everyone preview the supporter themes but applies one
  /// only for those accounts. A Founder Collection theme waits for a fresh
  /// answer from the server, so neither a saved status nor an offline
  /// device activates one.
  Future<bool> setTheme(String? id) async {
    final chosen = SupporterTheme.byId(id);
    if (id != null) {
      if (chosen == null) return false;
      if (chosen.collection == ThemeCollection.founder) {
        await _supporters.refresh();
        if (_supporters.failed) return false;
      }
      if (!mayUse(chosen)) return false;
    }
    _themeId = chosen?.id;
    _themeAccent = true;
    _apply();
    await _storage.saveSetting(_themeKey, _themeId ?? '');
    await _storage.saveSetting(_themeAccentKey, '1');
    return true;
  }

  @override
  void dispose() {
    _supporters.removeListener(_apply);
    super.dispose();
  }
}
