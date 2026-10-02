import 'package:flutter/foundation.dart';

import '../theme/glass_theme.dart';
import 'storage_service.dart';

class AccentSettingsController extends ChangeNotifier {
  AccentSettingsController({StorageService? storage})
    : _storage = storage ?? StorageService();

  static const _key = 'onfeed.appearance.accent';
  final StorageService _storage;
  AccentPalette _value = GlassTheme.coral;
  AccentPalette get value => _value;

  Future<void> load() async {
    final id = await _storage.readSetting(_key);
    _value = GlassTheme.accents.firstWhere(
      (accent) => accent.id == id,
      orElse: () => GlassTheme.coral,
    );
    GlassTheme.setAccent(_value);
    notifyListeners();
  }

  Future<void> update(AccentPalette value) async {
    _value = value;
    GlassTheme.setAccent(value);
    notifyListeners();
    await _storage.saveSetting(_key, value.id);
  }
}
