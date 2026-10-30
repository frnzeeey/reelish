// HTTP calls to the Reelish API's account routes, with timeouts and a
// typed error for every failure the UI distinguishes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A failed account request. [code] is the backend's stable error code,
/// or `network` / `unavailable` / `not_configured` from the client.
class AccountApiException implements Exception {
  const AccountApiException(this.code, this.message, {this.status});

  final String code;
  final String message;
  final int? status;

  /// The session itself is no longer valid: sign in again.
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'AccountApiException($code)';
}

/// The answer to one device-sign-in poll.
sealed class DevicePollResult {}

class DevicePending extends DevicePollResult {
  DevicePending(this.interval);
  final int interval;
}

class DeviceAuthorized extends DevicePollResult {
  DeviceAuthorized(this.session, this.user);
  final Map<String, dynamic> session;
  final Map<String, dynamic> user;
}

class DeviceCodeStart {
  const DeviceCodeStart({
    required this.pollToken,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String pollToken;
  final String userCode;
  final Uri verificationUrl;
  final int expiresIn;
  final int interval;
}

/// A started browser sign-in: the Trakt page to open, and a token to poll.
class WebSignInStart {
  const WebSignInStart({
    required this.pollToken,
    required this.authorizeUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String pollToken;
  final Uri authorizeUrl;
  final int expiresIn;
  final int interval;
}

/// Whether [url] is an HTTPS page on Trakt's own site, the only kind of
/// address the app opens from a sign-in response.
bool isTraktPage(Uri url) =>
    url.scheme == 'https' &&
    !url.hasPort &&
    url.userInfo.isEmpty &&
    (url.host == 'trakt.tv' || url.host.endsWith('.trakt.tv'));

class AccountApi {
  AccountApi({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  /// The API origin, or null when the build has none.
  final Uri? baseUrl;
  final http.Client _client;

  static const timeout = Duration(seconds: 15);

  Future<DeviceCodeStart> startDeviceSignIn({
    required String platform,
    required String deviceName,
  }) async {
    final body = await _send(
      'POST',
      '/auth/device/start',
      body: {'platform': platform, 'deviceName': deviceName},
    );
    final url = Uri.tryParse('${body['verificationUrl']}');
    if (url == null || !isTraktPage(url)) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    return DeviceCodeStart(
      pollToken: body['pollToken'] as String,
      userCode: body['userCode'] as String,
      verificationUrl: url,
      expiresIn: body['expiresIn'] as int,
      interval: body['interval'] as int,
    );
  }

  Future<WebSignInStart> startWebSignIn({
    required String platform,
    required String deviceName,
  }) async {
    final body = await _send(
      'POST',
      '/auth/web/start',
      body: {'platform': platform, 'deviceName': deviceName},
    );
    final url = Uri.tryParse('${body['authorizeUrl']}');
    if (url == null || !isTraktPage(url)) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    return WebSignInStart(
      pollToken: body['pollToken'] as String,
      authorizeUrl: url,
      expiresIn: body['expiresIn'] as int,
      interval: body['interval'] as int,
    );
  }

  Future<DevicePollResult> pollDeviceSignIn(String pollToken) =>
      _poll('/auth/device/poll', pollToken);

  Future<DevicePollResult> pollWebSignIn(String pollToken) =>
      _poll('/auth/web/poll', pollToken);

  Future<DevicePollResult> _poll(String path, String pollToken) async {
    final body = await _send('POST', path, body: {'pollToken': pollToken});
    if (body['status'] == 'authorized') {
      return DeviceAuthorized(
        Map<String, dynamic>.from(body['session'] as Map),
        Map<String, dynamic>.from(body['user'] as Map),
      );
    }
    return DevicePending((body['interval'] as int?) ?? 5);
  }

  Future<Map<String, dynamic>> refresh(String refreshToken) async {
    final body = await _send(
      'POST',
      '/auth/refresh',
      body: {'refreshToken': refreshToken},
    );
    return Map<String, dynamic>.from(body['session'] as Map);
  }

  /// The Trakt watchlist as `type:tmdbId` keys (`movie:550`,
  /// `series:1399`).
  Future<Set<String>> watchlist(String accessToken) async {
    final body = await _send('GET', '/trakt/watchlist', token: accessToken);
    final items = body['items'];
    return {
      for (final item in items is List ? items : const [])
        if (item is Map &&
            (item['type'] == 'movie' || item['type'] == 'series') &&
            item['tmdbId'] is int &&
            (item['tmdbId'] as int) > 0)
          '${item['type']}:${item['tmdbId']}',
    };
  }

  /// Adds and removes `type:tmdbId` keys on the Trakt watchlist (at most
  /// 100 of each); returns the keys Trakt could not find.
  Future<Set<String>> updateWatchlist(
    String accessToken, {
    Iterable<String> add = const [],
    Iterable<String> remove = const [],
  }) async {
    List<Map<String, Object>> entries(Iterable<String> keys) => [
      for (final key in keys)
        {
          'type': key.substring(0, key.indexOf(':')),
          'tmdbId': int.parse(key.substring(key.indexOf(':') + 1)),
        },
    ];
    final body = await _send(
      'POST',
      '/trakt/watchlist',
      token: accessToken,
      body: {'add': entries(add), 'remove': entries(remove)},
    );
    final missing = body['notFound'];
    return {
      for (final item in missing is List ? missing : const [])
        if (item is Map) '${item['type']}:${item['tmdbId']}',
    };
  }

  /// A token for background new-episode checks, tied to this session.
  Future<String> notificationToken(String accessToken) async {
    final body = await _send(
      'POST',
      '/notifications/token',
      token: accessToken,
      body: const {},
    );
    final token = body['token'];
    if (token is! String ||
        !RegExp(r'^rnt_[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    return token;
  }

  /// The latest aired episode of each series in [series] (TMDB ids), and
  /// of today's popular series when [popular]; uses a [notificationToken].
  Future<
    ({List<Map<String, dynamic>> series, List<Map<String, dynamic>> popular})
  >
  checkEpisodes(
    String alertToken,
    List<int> series, {
    bool popular = false,
  }) async {
    final body = await _send(
      'POST',
      '/notifications/episodes',
      token: alertToken,
      body: {'series': series, 'popular': popular},
    );
    List<Map<String, dynamic>> maps(Object? value) => [
      for (final entry in value is List ? value : const [])
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
    return (series: maps(body['series']), popular: maps(body['popular']));
  }

  Future<void> logout(String accessToken) =>
      _send('POST', '/auth/logout', token: accessToken);

  Future<void> logoutAll(String accessToken) =>
      _send('POST', '/auth/logout-all', token: accessToken);

  Future<void> deleteAccount(String accessToken) =>
      _send('DELETE', '/me', token: accessToken);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, Object>? body,
    String? token,
  }) async {
    final base = baseUrl;
    if (base == null) {
      throw const AccountApiException(
        'not_configured',
        'This build has no Reelish service configured.',
      );
    }
    final request = http.Request(method, Uri.parse('$base/api/v1$path'))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw const AccountApiException('network', 'The service did not answer.');
    } on SocketException {
      throw const AccountApiException('network', 'No connection.');
    } on http.ClientException {
      throw const AccountApiException('network', 'No connection.');
    }
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Handled below by status.
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final error = json['error'];
    final code = error is Map ? '${error['code']}' : 'unavailable';
    final message = error is Map ? '${error['message']}' : 'Request failed.';
    throw AccountApiException(code, message, status: response.statusCode);
  }
}
