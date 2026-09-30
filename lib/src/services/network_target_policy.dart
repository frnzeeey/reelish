import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

typedef HostAddressLookup = Future<List<InternetAddress>> Function(String host);

/// Resolves untrusted destinations, rejects non-public addresses, and pins
/// Dart HTTP connections to the addresses that passed validation.
///
/// Pinning matters here: validating DNS and then letting HttpClient resolve the
/// hostname again would leave a DNS-rebinding window between check and connect.
class NetworkDestinationValidator {
  NetworkDestinationValidator({
    HostAddressLookup? lookup,
    this.dnsTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 20),
  }) : _lookup = lookup ?? _lookupSystem;

  final HostAddressLookup _lookup;
  final Duration dnsTimeout;
  final Duration requestTimeout;

  static Future<List<InternetAddress>> _lookupSystem(String host) =>
      InternetAddress.lookup(host, type: InternetAddressType.any);

  /// Resolves the hostname once and rejects the destination if any returned
  /// address is local, private, special-use, malformed, or otherwise not GUA.
  Future<List<InternetAddress>> resolveDestination(
    Uri uri, {
    Set<String> allowedSchemes = const {'https'},
  }) async {
    final scheme = uri.scheme.toLowerCase();
    if (!allowedSchemes.contains(scheme) ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('Unsupported or malformed network URL.');
    }

    final host = _normalizeHostname(uri.host);
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null
        ? await _lookup(host).timeout(dnsTimeout)
        : [literal];
    if (addresses.isEmpty || addresses.any((address) => !_isPublic(address))) {
      throw const FormatException(
        'Network destination resolved to a non-public address.',
      );
    }
    return List.unmodifiable(addresses);
  }

  /// Validates each redirect as a new destination. Callers must disable the
  /// HTTP library's automatic redirects and use this before following one.
  Future<Uri> validateRedirect(
    Uri current,
    String location, {
    Set<String> allowedSchemes = const {'https'},
  }) async {
    final target = current.resolve(location);
    await resolveDestination(target, allowedSchemes: allowedSchemes);
    return target;
  }

  /// Creates an HTTP client whose TCP sockets connect to the validated IPs,
  /// while HttpClient retains the URL hostname for Host and TLS verification.
  Future<http.Client> createPinnedClient(
    Uri uri, {
    Set<String> allowedSchemes = const {'https'},
    bool autoUncompress = true,
  }) async {
    final addresses = await resolveDestination(
      uri,
      allowedSchemes: allowedSchemes,
    );
    final expectedHost = _normalizeHostname(uri.host);
    var nextAddress = 0;
    final client = HttpClient();
    client.autoUncompress = autoUncompress;
    client.connectionTimeout = requestTimeout;
    client.findProxy = (requestUri) => 'DIRECT';
    client.maxConnectionsPerHost = 4;
    client.connectionFactory = (requestUri, proxyHost, proxyPort) {
      if (proxyHost != null ||
          _normalizeHostname(requestUri.host) != expectedHost ||
          requestUri.port != uri.port ||
          requestUri.scheme.toLowerCase() != uri.scheme.toLowerCase()) {
        return Future.error(
          const FormatException('HTTP client destination changed.'),
        );
      }
      final address = addresses[nextAddress++ % addresses.length];
      final connection = Socket.startConnect(address, requestUri.port);
      if (requestUri.scheme.toLowerCase() != 'https') return connection;

      // HttpClient does not layer TLS over sockets returned by a custom
      // connectionFactory. Perform the standard verified TLS handshake here,
      // using the original URL hostname for SNI and certificate validation
      // while the underlying TCP connection stays pinned to the checked IP.
      return connection.then((task) {
        Socket? connectedSocket;
        final secureSocket = task.socket.then((socket) {
          connectedSocket = socket;
          return SecureSocket.secure(socket, host: requestUri.host);
        });
        return ConnectionTask.fromSocket<SecureSocket>(secureSocket, () {
          task.cancel();
          connectedSocket?.destroy();
        });
      });
    };
    return IOClient(client);
  }

  /// Sends one request with automatic redirects disabled and a bounded body.
  /// The caller is responsible for validating and following redirect targets.
  Future<http.Response> sendForBytes(
    http.Request request, {
    required Set<String> allowedSchemes,
    int maxRequestBytes = 2 * 1024 * 1024,
    int maxResponseBytes = 2 * 1024 * 1024,
    Duration? timeout,
    http.Client? testClient,
    bool autoUncompress = true,
  }) async {
    final uri = request.url;
    final effectiveTimeout = timeout ?? requestTimeout;
    if (request.followRedirects) {
      throw ArgumentError('Automatic redirects must remain disabled.');
    }
    if (request.bodyBytes.length > maxRequestBytes) {
      throw const FormatException('HTTP request body is too large.');
    }
    validateHeaders(request.headers);

    final http.Client client;
    if (testClient == null) {
      client = await createPinnedClient(
        uri,
        allowedSchemes: allowedSchemes,
        autoUncompress: autoUncompress,
      );
    } else {
      // Tests may replace the socket client, but they must exercise the same
      // destination policy as production calls.
      await resolveDestination(uri, allowedSchemes: allowedSchemes);
      client = testClient;
    }
    try {
      final streamed = await client.send(request).timeout(effectiveTimeout);
      final bytes = <int>[];
      await (() async {
        await for (final chunk in streamed.stream.timeout(effectiveTimeout)) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException('HTTP response is too large.');
          }
          bytes.addAll(chunk);
        }
      })().timeout(effectiveTimeout);
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        request: request,
        headers: streamed.headers,
        reasonPhrase: streamed.reasonPhrase,
      );
    } finally {
      if (testClient == null) client.close();
    }
  }

  static String _normalizeHostname(String rawHost) {
    final host = rawHost.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty || host.length > 253 || host.contains('%')) {
      throw const FormatException('Invalid destination hostname.');
    }
    if (InternetAddress.tryParse(host) != null) return host;

    // Require ASCII DNS names (including IDNA punycode). Rejecting ambiguous
    // numeric spellings avoids platform-specific interpretations such as 127.1.
    if (!host.contains('.') ||
        RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(r'^0x[0-9a-f]+(?:\.0x?[0-9a-f]+)*$').hasMatch(host) ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        host.endsWith('.home') ||
        host.endsWith('.home.arpa') ||
        host.endsWith('.test') ||
        host.endsWith('.invalid') ||
        host.endsWith('.example')) {
      throw const FormatException(
        'Local or ambiguous hostname is not allowed.',
      );
    }
    final labels = host.split('.');
    if (labels.any(
      (label) =>
          label.isEmpty ||
          label.length > 63 ||
          !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
    )) {
      throw const FormatException('Invalid destination hostname.');
    }
    return host;
  }

  static bool _isPublic(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final a = bytes[0], b = bytes[1], c = bytes[2];
      return !(a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 0) ||
          (a == 192 && b == 2) ||
          (a == 192 && b == 88 && c == 99) ||
          (a == 192 && b == 168) ||
          (a == 198 && (b == 18 || b == 19)) ||
          (a == 198 && b == 51 && c == 100) ||
          (a == 203 && b == 0 && c == 113) ||
          a >= 224);
    }
    if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
      return false;
    }

    // Only global-unicast 2000::/3 is accepted. This excludes unspecified,
    // loopback, link-local, ULA, multicast, and most special-use IPv6 space.
    if ((bytes[0] & 0xe0) != 0x20) return false;
    final is2001 = bytes[0] == 0x20 && bytes[1] == 0x01;
    final secondHextet = (bytes[2] << 8) | bytes[3];
    if (is2001 && secondHextet <= 0x01ff) {
      return false;
    }
    if (is2001 && secondHextet == 0x0db8) {
      return false;
    }
    // 6to4 embeds an IPv4 destination that cannot be validated from the IPv6
    // address alone, so it is rejected along with Teredo/special transition.
    if (bytes[0] == 0x20 && bytes[1] == 0x02) {
      return false;
    }
    return true;
  }

  /// Rejects routing and hop-by-hop headers that could defeat HTTP policy.
  /// Stream headers use the same checks before they enter native playback.
  static void validateHeaders(Map<String, String> headers) {
    if (headers.length > 64) {
      throw const FormatException('Too many HTTP headers.');
    }
    var totalBytes = 0;
    for (final entry in headers.entries) {
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$").hasMatch(entry.key) ||
          entry.key.toLowerCase() == 'host' ||
          const {
            'proxy-authorization',
            'connection',
            'keep-alive',
            'proxy-connection',
            'transfer-encoding',
            'upgrade',
            'te',
            'trailer',
          }.contains(entry.key.toLowerCase()) ||
          entry.value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]'))) {
        throw const FormatException('Invalid or restricted HTTP header.');
      }
      totalBytes += entry.key.length + entry.value.length;
      if (totalBytes > 32 * 1024) {
        throw const FormatException('HTTP headers are too large.');
      }
    }
  }
}
