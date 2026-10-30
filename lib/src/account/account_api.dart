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
    if (url == null || url.scheme != 'https') {
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

  Future<DevicePollResult> pollDeviceSignIn(String pollToken) async {
    final body = await _send(
      'POST',
      '/auth/device/poll',
      body: {'pollToken': pollToken},
    );
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
