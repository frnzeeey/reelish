// Launcher icon presets and switching between them (Settings → Appearance
// → App icon). Android phones and tablets only: each preset is an activity
// alias (AndroidManifest.xml, AppIconSwitcher.kt), and the enabled alias is
// the only record of the choice, so what Settings shows is what the
// launcher shows. Windows embeds its icon in the executable and Android TV
// shows the banner, so neither offers this.
//
// Default and Slate are free for everyone. The rest, the Signature artwork and
// the colours, are a thank-you to Reelish Supporters: applying one asks the
// server first (SupporterController), so neither a saved status nor changed
// local data can unlock it. An icon already on the launcher is never changed
// behind the user's back (that can remove their home-screen shortcut), so one
// chosen while supporting stays until they choose another.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_capabilities.dart';
import '../account/supporter_controller.dart';
import '../analytics/analytics_events.dart';
import '../analytics/analytics_service.dart';

/// Which part of the collection an icon belongs to.
enum AppIconGroup {
  /// Free for everyone.
  free,

  /// The supporter collection's own artwork, matching the app themes
  /// (tool/branding/generate_signature_icons.mjs).
  signature,

  /// The supporter collection's colours of the Reelish tile.
  colour,
}

/// One launcher icon. [id] is shared with AppIconSwitcher.kt.
@immutable
class AppIconPreset {
  const AppIconPreset(this.id, this.label, [this.group = AppIconGroup.colour]);

  final String id;
  final String label;
  final AppIconGroup group;

  /// Free for everyone; otherwise for Reelish Supporters.
  bool get free => group == AppIconGroup.free;

  /// A 192 px preview (tool/branding/generate_icon_presets.ps1).
  String get preview => 'assets/images/app_icons/$id.png';

  static const defaultId = 'default';

  static const all = [
    AppIconPreset(defaultId, 'Default', AppIconGroup.free),
    AppIconPreset('slate', 'Slate', AppIconGroup.free),
    // One per app theme, in the themes' order. The ids are launcher aliases,
    // the saved choice, so the first five keep the ids of the themes they
    // replaced.
    AppIconPreset('royal_violet', 'Velvet Cinema', AppIconGroup.signature),
    AppIconPreset('aurora', 'Aurora', AppIconGroup.signature),
    AppIconPreset('ember', 'Ember', AppIconGroup.signature),
    AppIconPreset('celestial', 'Arctic', AppIconGroup.signature),
    AppIconPreset('ivory_studio', 'Ivory Studio', AppIconGroup.signature),
    AppIconPreset('golden_hour', 'Obsidian Gold', AppIconGroup.signature),
    AppIconPreset('rose_luxe', 'Rosé Noir', AppIconGroup.signature),
    AppIconPreset('amber', 'Amber'),
    AppIconPreset('orange', 'Orange'),
    AppIconPreset('rose', 'Rose'),
    AppIconPreset('violet', 'Violet'),
    AppIconPreset('indigo', 'Indigo'),
    AppIconPreset('blue', 'Blue'),
    AppIconPreset('teal', 'Teal'),
    AppIconPreset('green', 'Green'),
    AppIconPreset('lime', 'Lime'),
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

/// How an attempt to change the icon ended.
enum AppIconChange {
  /// The system confirms the icon is now the launcher's.
  applied,

  /// The system refused or failed; the previous icon stays.
  failed,

  /// The server says this account is not a supporter.
  supportersOnly,

  /// Supporter status could not be checked (offline, signed out, server
  /// down), so a supporter icon was not applied.
  unverified,
}

/// The selection for the settings screen.
class AppIconController extends ChangeNotifier {
  AppIconController({AppIconService? service, SupporterController? supporters})
    : _service = service ?? const AppIconService(),
      _supporters = supporters ?? SupporterController.instance {
    _supporters.addListener(notifyListeners);
  }

  final AppIconService _service;
  final SupporterController _supporters;

  /// Whether the supporter icons show as unlocked: the last status known
  /// for this account. Only for display; [select] asks the server.
  bool get supporter => _supporters.has(SupporterPerk.appIcons);

  /// The Founder, who has every supporter perk without donating.
  bool get founder => _supporters.entitlement == Entitlement.founder;

  /// Whether [preset] can be chosen from the screen as things stand.
  bool unlocked(AppIconPreset preset) => preset.free || supporter;

  @override
  void dispose() {
    _supporters.removeListener(notifyListeners);
    super.dispose();
  }

  String _current = AppIconPreset.defaultId;
  String get current => _current;

  /// The preset being applied, while the system works.
  String? _applying;
  String? get applying => _applying;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    // The status for the lock marks; nothing waits for it.
    unawaited(_supporters.refresh());
    try {
      _current = await _service.current();
    } catch (_) {
      // Unknown state: show the default, which is what a fresh install shows.
      _current = AppIconPreset.defaultId;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Applies [id]. A supporter icon is applied only once the server confirms
  /// the account is a supporter now.
  Future<AppIconChange> select(String id) async {
    if (id == _current) return AppIconChange.applied;
    if (_applying != null) return AppIconChange.failed;
    final preset = AppIconPreset.all.where((p) => p.id == id).firstOrNull;
    if (preset == null) return AppIconChange.failed;
    _applying = id;
    notifyListeners();
    try {
      if (!preset.free) {
        await _supporters.refresh();
        if (_supporters.failed) return AppIconChange.unverified;
        if (!_supporters.has(SupporterPerk.appIcons)) {
          return AppIconChange.supportersOnly;
        }
      }
      _current = await _service.select(id);
      if (_current == id) {
        AnalyticsService.instance.log(
          AnalyticsEvent.featureUsed(AnalyticsFeature.appIconChange),
        );
      }
      return _current == id ? AppIconChange.applied : AppIconChange.failed;
    } catch (_) {
      try {
        _current = await _service.current();
      } catch (_) {}
      return AppIconChange.failed;
    } finally {
      _applying = null;
      notifyListeners();
    }
  }
}
