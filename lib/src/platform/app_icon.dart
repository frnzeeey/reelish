// Launcher icon presets and switching between them (Settings → Appearance
// → App icon). Android phones and tablets only: each preset is an activity
// alias (AndroidManifest.xml, AppIconSwitcher.kt), and the enabled alias is
// the only record of the choice, so what Settings shows is what the
// launcher shows. Windows embeds its icon in the executable and Android TV
// shows the banner, so neither offers this.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_capabilities.dart';

/// One launcher icon. [id] is shared with AppIconSwitcher.kt.
@immutable
class AppIconPreset {
  const AppIconPreset(this.id, this.label);

  final String id;
  final String label;

  /// A 192 px preview (tool/branding/generate_icon_presets.ps1).
  String get preview => 'assets/images/app_icons/$id.png';

  static const defaultId = 'default';

  static const all = [
    AppIconPreset(defaultId, 'Default'),
    AppIconPreset('amber', 'Amber'),
    AppIconPreset('orange', 'Orange'),
    AppIconPreset('rose', 'Rose'),
    AppIconPreset('violet', 'Violet'),
    AppIconPreset('indigo', 'Indigo'),
    AppIconPreset('blue', 'Blue'),
    AppIconPreset('teal', 'Teal'),
    AppIconPreset('green', 'Green'),
    AppIconPreset('lime', 'Lime'),
    AppIconPreset('slate', 'Slate'),
  ];

  static AppIconPreset byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);
}

/// Talks to the Android side. Every answer is the system's own state.
class AppIconService {
  const AppIconService([
    this._channel = const MethodChannel('onfeed/app_icon'),
  ]);

  final MethodChannel _channel;

  /// Whether this device can switch launcher icons.
  static bool get supported =>
      !kIsWeb && Platform.isAndroid && !DeviceCapabilities.isTv;

  /// The preset the launcher shows now.
  Future<String> current() async =>
      AppIconPreset.byId(await _channel.invokeMethod<String>('current')).id;

  /// Switches to [id]; returns the preset active afterwards, as read back
  /// from the system (so a change it refused is never reported as done).
  Future<String> select(String id) async => AppIconPreset.byId(
    await _channel.invokeMethod<String>('select', {'id': id}),
  ).id;
}

/// The selection for the settings screen.
class AppIconController extends ChangeNotifier {
  AppIconController({AppIconService? service})
    : _service = service ?? const AppIconService();

  final AppIconService _service;

  String _current = AppIconPreset.defaultId;
  String get current => _current;

  /// The preset being applied, while the system works.
  String? _applying;
  String? get applying => _applying;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      _current = await _service.current();
    } catch (_) {
      // Unknown state: show the default, which is what a fresh install shows.
      _current = AppIconPreset.defaultId;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Applies [id]. True only when the system confirms that icon is now the
  /// launcher's.
  Future<bool> select(String id) async {
    if (_applying != null || id == _current) return id == _current;
    _applying = id;
    notifyListeners();
    try {
      _current = await _service.select(id);
      return _current == id;
    } catch (_) {
      try {
        _current = await _service.current();
      } catch (_) {}
      return false;
    } finally {
      _applying = null;
      notifyListeners();
    }
  }
}
