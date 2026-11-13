// Keeps each account's discovery data apart on this device: its viewing
// activity, feedback and picked genres in SharedPreferences under a key of
// its own, and its last computed rows in a private file outside backup.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'discovery_data.dart';
import 'discovery_engine.dart';

/// Rows as last computed, with what they were computed from.
class CachedDiscovery {
  const CachedDiscovery({
    required this.sections,
    required this.computedAt,
    required this.fingerprint,
  });

  final List<DiscoverySection> sections;
  final DateTime computedAt;

  /// Identifies the profile the rows were built from; a different one means
  /// the rows are out of date whatever their age.
  final String fingerprint;
}

class DiscoveryStore {
  DiscoveryStore({Future<Directory> Function()? filesDirectory})
    : _filesDirectory = filesDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _filesDirectory;

  static const _dataPrefix = 'onfeed.discovery.v1.';

  /// The account that the device's watch history (kept before discovery
  /// existed, and not per account) was read into. Only that account ever
  /// reads it, so a second account on the device does not inherit the
  /// first one's tastes.
  static const historyOwnerKey = 'onfeed.discovery.historyOwner.v1';

  /// Writes run one at a time, so two saves cannot each write back data
  /// missing the other's change.
  static Future<void> _writes = Future.value();

  @visibleForTesting
  static void debugResetWrites() => _writes = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<DiscoveryData> load(String userId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_dataPrefix$userId',
    );
    if (raw == null) return DiscoveryData.empty;
    try {
      return DiscoveryData.fromJson(jsonDecode(raw));
    } on FormatException {
      return DiscoveryData.empty;
    }
  }

  /// Applies [change] to the account's stored data and saves the result.
  Future<DiscoveryData> update(
    String userId,
    DiscoveryData Function(DiscoveryData current) change,
  ) => _serialized(() async {
    final next = change(await load(userId));
    await (await SharedPreferences.getInstance()).setString(
      '$_dataPrefix$userId',
      jsonEncode(next.toJson()),
    );
    return next;
  });

  /// Whether [userId] may read the device's watch history into its
  /// activity: true for the first account to ask, which then owns it.
  Future<bool> claimDeviceHistory(String userId) => _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    final owner = preferences.getString(historyOwnerKey);
    if (owner != null) return owner == userId;
    await preferences.setString(historyOwnerKey, userId);
    return true;
  });

  // Cached rows ------------------------------------------------------------

  static String _safe(String userId) =>
      userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<File> _resultsFile(String userId) async => File(
    '${(await _filesDirectory()).path}/discovery_${_safe(userId)}.v1.json',
  );

  Future<CachedDiscovery?> cachedSections(String userId) async {
    try {
      final file = await _resultsFile(userId);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final at = DateTime.tryParse('${decoded['at'] ?? ''}');
      final sections = decoded['sections'];
      if (at == null || sections is! List) return null;
      return CachedDiscovery(
        sections: [for (final raw in sections) ?DiscoverySection.fromJson(raw)],
        computedAt: at,
        fingerprint: '${decoded['fingerprint'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSections(String userId, CachedDiscovery value) =>
      _serialized(() async {
        final file = await _resultsFile(userId);
        await file.parent.create(recursive: true);
        // Write then rename, so an interrupted write never leaves a corrupt
        // file.
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({
            'at': value.computedAt.toUtc().toIso8601String(),
            'fingerprint': value.fingerprint,
            'sections': [for (final s in value.sections) s.toJson()],
          }),
          flush: true,
        );
        await temporary.rename(file.path);
      });

  Future<void> clearSections(String userId) => _serialized(() async {
    try {
      final file = await _resultsFile(userId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  });
}
