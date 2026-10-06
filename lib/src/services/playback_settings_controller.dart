import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/playback_settings.dart';
import 'storage_service.dart';

class PlaybackSettingsController extends ChangeNotifier {
  PlaybackSettingsController({StorageService? storage})
    : _storage = storage ?? StorageService();

  static const _key = 'onfeed.playback.settings.v1';
  final StorageService _storage;
  PlaybackSettings _value = const PlaybackSettings();
  PlaybackSettings get value => _value;

  Future<void> load() async {
    final encoded = await _storage.readSetting(_key);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          _value = PlaybackSettings.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        // Ignore a malformed or older preference payload and use defaults.
      }
    }
    notifyListeners();
  }

  Future<void> update(PlaybackSettings value) async {
    _value = value;
    notifyListeners();
    await _storage.saveSetting(_key, jsonEncode(value.toJson()));
  }

  /// True when the cache was cleared now, false when it is cleared at the
  /// next launch (a torrent played this session).
  Future<bool> clearTorrentCache() => _storage.clearTorrentCache();
}
