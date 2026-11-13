// Discovery preferences on the Reelish API (GET/PUT
// /api/v1/discovery/preferences): picked genres, the genre step and
// personalisation on or off, one small record per account. The server keeps
// the newer change, ordered as progress sync orders them: by a per-device
// counter on one device, by the time of the change (corrected by the
// measured clock offset) between devices. DiscoveryController decides when
// to call it.

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../discovery/discovery_preferences.dart';
import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

class DiscoveryPreferencesSync implements DiscoveryPreferencesRemote {
  DiscoveryPreferencesSync({
    AccountApi? api,
    this._account,
    int Function()? clock,
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// SharedPreferences key: `{userId: {device, seq, offset}}`.
  static const storageKey = 'onfeed.discoveryPrefsSync.v1';

  final AccountApi _api;
  final AccountController? _account;
  final int Function() _clock;

  AccountController get _accountController =>
      _account ?? AccountController.instance;

  /// Whether this build can reach the Reelish API at all.
  bool get configured => _api.baseUrl != null;

  @override
  Future<DiscoveryPreferences?> fetch(String userId) async {
    final state = await _state(userId);
    final sent = _clock();
    final body = await _withToken(
      userId,
      (token) => _api.discoveryPreferences(token),
    );
    await _measure(userId, state, sent, body);
    return _stored(body);
  }

  @override
  Future<DiscoveryPreferences?> push(
    String userId,
    DiscoveryPreferences preferences,
    DateTime changedAt,
  ) async {
    final state = await _state(userId);
    state.seq++;
    // The counter is saved before sending, so a resend after a crash is
    // still newer than what this device sent before.
    await _save(userId, state);
    final local = changedAt.millisecondsSinceEpoch;
    final sent = _clock();
    final body = await _withToken(
      userId,
      (token) => _api.putDiscoveryPreferences(
        token,
        device: state.device,
        seq: state.seq,
        at: local <= 0 ? 0 : max(0, local + state.offset),
        preferences: preferences.toJson(),
      ),
    );
    await _measure(userId, state, sent, body);
    return _stored(body);
  }

  static DiscoveryPreferences? _stored(Map<String, dynamic> body) {
    final stored = body['stored'];
    if (stored is! Map) return null;
    return DiscoveryPreferences.fromJson(stored['preferences']);
  }

  Future<Map<String, dynamic>> _withToken(
    String userId,
    Future<Map<String, dynamic>> Function(String token) call,
  ) async {
    final account = _accountController;
    if (account.userId != userId) {
      throw const AccountApiException('signed_out', 'Another account.');
    }
    final token = await account.accessToken();
    if (token == null) {
      throw const AccountApiException('signed_out', 'Signed out.');
    }
    try {
      return await call(token);
    } on AccountApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      final fresh = await account.accessToken(forceRefresh: true);
      if (fresh == null || account.userId != userId) rethrow;
      return call(fresh);
    }
  }

  Future<void> _measure(
    String userId,
    _State state,
    int sent,
    Map<String, dynamic> body,
  ) async {
    final serverTime = body['serverTime'];
    if (serverTime is! int || serverTime <= 0) return;
    final received = _clock();
    state.offset = serverTime - (sent + received) ~/ 2;
    await _save(userId, state);
  }

  Future<_State> _state(String userId) async {
    final all = await _readAll();
    return _State.fromJson(all[userId]) ?? _State.fresh();
  }

  Future<Map<String, dynamic>> _readAll() async {
    final raw = (await SharedPreferences.getInstance()).getString(storageKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(String userId, _State state) async {
    final all = await _readAll();
    all[userId] = state.toJson();
    await (await SharedPreferences.getInstance()).setString(
      storageKey,
      jsonEncode(all),
    );
  }
}

class _State {
  _State({required this.device, this.seq = 0, this.offset = 0});

  /// A random id for this device's changes; not a hardware identifier.
  final String device;
  int seq;

  /// Server clock minus this device's clock, from the last request.
  int offset;

  static _State fresh() {
    final random = Random.secure();
    return _State(
      device: List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
  }

  static _State? fromJson(Object? json) {
    if (json is! Map) return null;
    final device = json['device'];
    if (device is! String ||
        !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(device)) {
      return null;
    }
    int number(Object? value) => value is int ? value : 0;
    return _State(
      device: device,
      seq: number(json['seq']),
      offset: number(json['offset']),
    );
  }

  Map<String, Object> toJson() => {
    'device': device,
    'seq': seq,
    'offset': offset,
  };
}
