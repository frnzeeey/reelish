// Keeps the Reelish session in the platform's secure storage (Android
// Keystore, Windows DPAPI), never in SharedPreferences.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One signed-in device's session as the backend issued it.
class StoredSession {
  const StoredSession({
    required this.sessionId,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
    required this.userId,
    required this.username,
  });

  final String sessionId;
  final String accessToken;

  /// Unix seconds.
  final int accessExpiresAt;
  final String refreshToken;
  final int refreshExpiresAt;
  final String userId;
  final String username;

  bool get refreshExpired =>
      refreshExpiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Whether the access token is expired or will be within a minute.
  bool get accessStale =>
      accessExpiresAt - 60 <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  StoredSession withTokens(Map<String, dynamic> session) => StoredSession(
    sessionId: session['sessionId'] as String,
    accessToken: session['accessToken'] as String,
    accessExpiresAt: session['accessExpiresAt'] as int,
    refreshToken: session['refreshToken'] as String,
    refreshExpiresAt: session['refreshExpiresAt'] as int,
    userId: userId,
    username: username,
  );

  static StoredSession fromResponse(
    Map<String, dynamic> session,
    Map<String, dynamic> user,
  ) => StoredSession(
    sessionId: session['sessionId'] as String,
    accessToken: session['accessToken'] as String,
    accessExpiresAt: session['accessExpiresAt'] as int,
    refreshToken: session['refreshToken'] as String,
    refreshExpiresAt: session['refreshExpiresAt'] as int,
    userId: user['id'] as String,
    username: user['username'] as String,
  );

  Map<String, Object> toJson() => {
    'sessionId': sessionId,
    'accessToken': accessToken,
    'accessExpiresAt': accessExpiresAt,
    'refreshToken': refreshToken,
    'refreshExpiresAt': refreshExpiresAt,
    'userId': userId,
    'username': username,
  };

  static StoredSession? tryParse(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return StoredSession(
        sessionId: json['sessionId'] as String,
        accessToken: json['accessToken'] as String,
        accessExpiresAt: json['accessExpiresAt'] as int,
        refreshToken: json['refreshToken'] as String,
        refreshExpiresAt: json['refreshExpiresAt'] as int,
        userId: json['userId'] as String,
        username: json['username'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Reads and writes the one stored session. Tests swap in [MemorySessionStore].
abstract class SessionStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'reelish.session.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<StoredSession?> read() async {
    try {
      return StoredSession.tryParse(await _storage.read(key: _key));
    } catch (_) {
      // Unreadable (e.g. the keystore was reset): sign in again.
      return null;
    }
  }

  @override
  Future<void> write(StoredSession session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Nothing more can be done; the backend session is revoked anyway.
    }
  }
}

class MemorySessionStore implements SessionStore {
  MemorySessionStore([this.session]);

  StoredSession? session;

  @override
  Future<StoredSession?> read() async => session;

  @override
  Future<void> write(StoredSession session) async => this.session = session;

  @override
  Future<void> clear() async => session = null;
}
