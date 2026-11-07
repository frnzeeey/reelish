// The app's look on this device: the accent colour, and for accounts with the
// supporter perk, an app theme. A theme sets the accent across Reelish and
// dresses the profile card. Like the accent it is a device setting, and it
// applies only while the signed-in account has the perk; otherwise the
// accent the user picked returns, and the saved theme waits.
import 'package:flutter/foundation.dart';

import '../account/supporter_controller.dart';
import '../theme/glass_theme.dart';
import '../theme/supporter_themes.dart';
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
  final StorageService _storage;
  final SupporterController _supporters;
  AccentPalette _accent = GlassTheme.coral;
  String? _themeId;

  /// Whose perks decide whether a theme applies.
  SupporterController get supporters => _supporters;

  /// The accent the user picked, used whenever no theme applies.
  AccentPalette get accent => _accent;

  /// The saved theme's id, whether or not it applies now.
  String? get themeId => _themeId;

  /// The theme in effect: the saved one, while the account has the perk.
  SupporterTheme? get theme => _supporters.has(SupporterPerk.appThemes)
      ? SupporterTheme.byId(_themeId)
      : null;

  /// The accent in effect across the app.
  AccentPalette get value => theme?.accent ?? _accent;

  Future<void> load() async {
    final id = await _storage.readSetting(_key);
    // A preset id, or `custom:rrggbb`; anything else falls back to coral.
    _accent = AccentPalette.fromId(id) ?? GlassTheme.coral;
    final theme = await _storage.readSetting(_themeKey);
    _themeId = SupporterTheme.byId(theme)?.id;
    _apply();
  }

  void _apply() {
    GlassTheme.setAccent(value);
    notifyListeners();
  }

  /// Uses [value] as the accent. Picking an accent turns a theme off, since
  /// the theme would hide it.
  Future<void> update(AccentPalette value) async {
    _accent = value;
    final hadTheme = _themeId != null;
    _themeId = null;
    _apply();
    AnalyticsService.instance.log(
      AnalyticsEvent.featureUsed(AnalyticsFeature.accentChange),
    );
    await _storage.saveSetting(_key, value.id);
    if (hadTheme) await _storage.saveSetting(_themeKey, '');
  }

  /// Uses the theme [id], or none for null. A theme is taken only when the
  /// account has the perk; the screen offers it to no one else.
  Future<void> setTheme(String? id) async {
    if (id != null &&
        (SupporterTheme.byId(id) == null ||
            !_supporters.has(SupporterPerk.appThemes))) {
      return;
    }
    _themeId = id;
    _apply();
    await _storage.saveSetting(_themeKey, id ?? '');
  }

  @override
  void dispose() {
    _supporters.removeListener(_apply);
    super.dispose();
  }
}
