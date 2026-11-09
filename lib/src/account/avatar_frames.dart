// The signed-in account's avatar frames: the one it wears, the ones it may
// equip and the limited editions it collected. The Reelish API decides all
// three (backend/src/frames.ts) and they follow the account to every device;
// this reads them from GET /me and keeps a copy per account so they show at
// once and offline. The copy only chooses what to draw: equipping asks the
// server, which refuses a frame the account may not wear.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

/// Why equipping a frame did not happen.
enum FrameChange {
  /// The server confirms it: the frame is worn on every device.
  applied,

  /// Not a Supporter, or the Founder's Sovereign frame for anyone else.
  notAllowed,

  /// A limited edition that can no longer be collected.
  unavailable,

  /// The server could not be reached or nobody is signed in.
  failed,
}

@immutable
class FrameState {
  const FrameState({
    this.equipped,
    this.available = const {},
    this.collected = const {},
  });

  /// The frame worn now, or null for none.
  final String? equipped;
  final Set<String> available;
  final Set<String> collected;

  static const empty = FrameState();

  static FrameState parse(Object? value) {
    if (value is! Map) return empty;
    Set<String> ids(Object? list) => {
      if (list is List)
        for (final id in list)
          if (id is String) id,
    };
    final equipped = value['equipped'];
    return FrameState(
      equipped: equipped is String ? equipped : null,
      available: ids(value['available']),
      collected: ids(value['collected']),
    );
  }

  Map<String, Object?> toJson() => {
    'equipped': equipped,
    'available': available.toList(),
    'collected': collected.toList(),
  };
}

class AvatarFrames extends ChangeNotifier {
  AvatarFrames({AccountController? account, AccountApi? api})
    : _account = account ?? AccountController.instance,
      _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);

  static final instance = AvatarFrames();

  static const _cachePrefix = 'reelish.frames.v1.';

  final AccountController _account;
  final AccountApi _api;

  FrameState _state = FrameState.empty;
  String? _loadedFor;
  bool _saving = false;

  FrameState get state => _state;

  /// The frame worn now, as last known for this account.
  String? get equipped => _state.equipped;

  /// While an equip waits for the server.
  bool get saving => _saving;

  bool mayEquip(String id) => _state.available.contains(id);

  /// Shows the saved frames for this account, then reads GET /me. Called
  /// beside AccountBadges.refresh, so both share one request.
  Future<void> refresh() async {
    final userId = _account.userId;
    if (userId == null) {
      _loadedFor = null;
      _set(FrameState.empty);
      return;
    }
    if (_loadedFor != userId) {
      _loadedFor = userId;
      _set(await _readCache(userId));
    }
    try {
      final body = await _account.fetchMe();
      if (body == null || _account.userId != userId) return;
      if (!body.containsKey('frames')) return; // An API from before frames.
      await _accept(userId, FrameState.parse(body['frames']));
    } catch (_) {
      // Offline: the saved frames stay. A frame is never worth an error.
    }
  }

  /// Wears [id], or none for null, on every device of this account.
  Future<FrameChange> equip(String? id) async {
    final userId = _account.userId;
    if (userId == null || _saving) return FrameChange.failed;
    _saving = true;
    notifyListeners();
    try {
      final token = await _account.accessToken();
      if (token == null) return FrameChange.failed;
      final body = await _api.setAvatarFrame(token, id);
      if (_account.userId != userId) return FrameChange.failed;
      await _accept(userId, FrameState.parse(body['frames']));
      return FrameChange.applied;
    } on AccountApiException catch (error) {
      return switch (error.code) {
        'supporter_required' || 'founder_only' => FrameChange.notAllowed,
        'frame_unavailable' => FrameChange.unavailable,
        _ => FrameChange.failed,
      };
    } catch (_) {
      return FrameChange.failed;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> _accept(String userId, FrameState next) async {
    _set(next);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_cachePrefix$userId',
        jsonEncode(next.toJson()),
      );
    } catch (_) {
      // Only a convenience.
    }
  }

  void _set(FrameState next) {
    _state = next;
    notifyListeners();
  }

  Future<FrameState> _readCache(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$_cachePrefix$userId');
      return saved == null
          ? FrameState.empty
          : FrameState.parse(jsonDecode(saved));
    } catch (_) {
      return FrameState.empty;
    }
  }
}
