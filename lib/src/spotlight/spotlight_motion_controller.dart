// The Spotlight animation chosen on this device, and the one in effect. Like
// the app theme (AccentSettingsController) it is a device setting, and an
// exclusive preset applies only while the signed-in account has the supporter
// perk as the Reelish API decided it (SupporterController): the stored value
// only says what was chosen, never what is allowed, so editing it unlocks
// nothing. Without the perk Cinematic Depth shows, and the saved preset waits
// for the perk to return. Nothing is sent anywhere.
import 'package:flutter/foundation.dart';

import '../account/supporter_controller.dart';
import '../services/storage_service.dart';
import 'spotlight_motion.dart';

class SpotlightMotionController extends ChangeNotifier {
  SpotlightMotionController({
    StorageService? storage,
    SupporterController? supporters,
  }) : _storage = storage ?? StorageService(),
       _supporters = supporters ?? SupporterController.instance {
    _supporters.addListener(_supportersChanged);
  }

  static final instance = SpotlightMotionController();

  static const _key = 'onfeed.appearance.spotlight_motion';

  final StorageService _storage;
  final SupporterController _supporters;
  SpotlightMotion _saved = SpotlightMotion.fallback;
  SpotlightMotion _effective = SpotlightMotion.fallback;
  Future<void>? _loading;

  /// Whose perk decides the exclusive presets.
  SupporterController get supporters => _supporters;

  /// The preset chosen on this device, whether or not it applies now.
  SpotlightMotion get saved => _saved;

  /// The preset in effect: the saved one, while it is free or the account
  /// has the perk.
  SpotlightMotion get value => _effective;

  /// The account has the exclusive presets, as last known.
  bool get unlocked => _supporters.has(SupporterPerk.spotlightMotion);

  /// Whether the account may use [motion], as last known.
  bool mayUse(SpotlightMotion motion) => !motion.exclusive || unlocked;

  /// Reads the saved preset, once; later calls wait for the first.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    String? id;
    try {
      id = await _storage.readSetting(_key);
    } catch (_) {
      // Unreadable: the default.
    }
    // Unknown or retired ids open as the default.
    _saved = SpotlightMotion.byId(id) ?? SpotlightMotion.fallback;
    _update();
  }

  void _supportersChanged() => _update();

  void _update() {
    final next = mayUse(_saved) ? _saved : SpotlightMotion.fallback;
    if (next == _effective) return;
    _effective = next;
    notifyListeners();
  }

  /// Uses [motion] from now on and saves it; refused (false) for an
  /// exclusive preset without the perk.
  Future<bool> select(SpotlightMotion motion) async {
    if (!mayUse(motion)) return false;
    _saved = _effective = motion;
    notifyListeners();
    try {
      await _storage.saveSetting(_key, motion.id);
    } catch (_) {
      // Still used for this session.
    }
    return true;
  }

  @override
  void dispose() {
    _supporters.removeListener(_supportersChanged);
    super.dispose();
  }
}
