import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/services/network_target_policy.dart';

void main() {
  group('NetworkDestinationValidator', () {
    final validator = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );

    test('rejects private and local IP literals and hostnames', () async {
      for (final url in [
        'http://127.0.0.1',
        'http://localhost',
        'http://10.0.0.1',
        'http://172.16.0.1',
        'http://192.168.1.1',
        'http://169.254.169.254',
        'http://[::1]',
        'http://[fe80::1]',
        'http://[fc00::1]',
        'http://127.1',
      ]) {
        await expectLater(
          validator.resolveDestination(
            Uri.parse(url),
            allowedSchemes: const {'http', 'https'},
          ),
          throwsFormatException,
          reason: url,
        );
      }
    });

    test(
      'rejects hostnames if any IPv4 or IPv6 DNS answer is private',
      () async {
        final mixedIpv4 = NetworkDestinationValidator(
          lookup: (_) async => [
            InternetAddress('93.184.216.34'),
            InternetAddress('192.168.1.10'),
          ],
        );
        final privateIpv6 = NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('fd00::1')],
        );

        await expectLater(
          mixedIpv4.resolveDestination(Uri.https('provider.example.org', '/')),
          throwsFormatException,
        );
        await expectLater(
          privateIpv6.resolveDestination(
            Uri.https('provider.example.org', '/'),
          ),
          throwsFormatException,
        );
      },
    );

    test('fails closed when hostname resolution fails', () async {
      final brokenDns = NetworkDestinationValidator(
        lookup: (_) => Future.error(const SocketException('DNS failed')),
      );
      await expectLater(
        brokenDns.resolveDestination(Uri.https('provider.example.org', '/')),
        throwsA(isA<SocketException>()),
      );
    });

    test('allows validated public destinations and HTTPS by default', () async {
      final addresses = await validator.resolveDestination(
        Uri.https('provider.example.org', '/manifest.json'),
      );
      expect(addresses.single.address, '93.184.216.34');
      await expectLater(
        validator.resolveDestination(Uri.http('provider.example.org', '/')),
        throwsFormatException,
      );
      await expectLater(
        validator.resolveDestination(
          Uri.http('provider.example.org', '/'),
          allowedSchemes: const {'http', 'https'},
        ),
        completes,
      );
    });

    test('validates every redirect destination', () async {
      final privateHost = NetworkDestinationValidator(
        lookup: (host) async => [
          InternetAddress(
            host == 'private.example.org' ? '10.0.0.7' : '93.184.216.34',
          ),
        ],
      );
      final origin = Uri.https('provider.example.org', '/start');

      expect(
        await validator.validateRedirect(
          origin,
          'https://cdn.example.org/video.m3u8',
        ),
        Uri.https('cdn.example.org', '/video.m3u8'),
      );
      await expectLater(
        validator.validateRedirect(origin, 'http://127.0.0.1/admin'),
        throwsFormatException,
      );
      await expectLater(
        privateHost.validateRedirect(
          origin,
          'https://private.example.org/admin',
        ),
        throwsFormatException,
      );
    });

    test('bounds response bytes and rejects automatic redirects', () async {
      final mock = MockClient((request) async => http.Response('12345', 200));
      final tooLarge = http.Request(
        'GET',
        Uri.https('provider.example.org', '/'),
      )..followRedirects = false;
      await expectLater(
        validator.sendForBytes(
          tooLarge,
          allowedSchemes: const {'https'},
          maxResponseBytes: 4,
          testClient: mock,
        ),
        throwsFormatException,
      );

      final redirectRequest = http.Request(
        'GET',
        Uri.https('provider.example.org', '/'),
      );
      await expectLater(
        validator.sendForBytes(
          redirectRequest,
          allowedSchemes: const {'https'},
          testClient: mock,
        ),
        throwsArgumentError,
      );
      mock.close();
    });
  });
}
