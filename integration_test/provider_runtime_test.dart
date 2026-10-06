// Checks the provider sandbox on a real device or emulator, where the
// platform's own QuickJS build runs (desktop `flutter test` uses another):
//
//   flutter test integration_test/provider_runtime_test.dart -d <device-id>
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/services/provider_runner.dart';

ProviderRunRequest _request(String code, {Duration? interruptAfter}) =>
    ProviderRunRequest(
      pluginId: 'device-test',
      code: code,
      codeUrl: 'https://repo.example/device-test.js',
      tmdbId: '603',
      mediaType: 'movie',
      interruptAfter: interruptAfter,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a provider runs with the memory limit applied', () async {
    final streams = await ProviderRunner.run(
      _request('''
        module.exports.getStreams = async (id, type) =>
          [{ name: type, url: 'https://cdn.example/' + id + '.m3u8' }];
      '''),
    );
    expect(streams.single['url'], 'https://cdn.example/603.m3u8');
  });

  test('the interrupt deadline stops a synchronous loop', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      ProviderRunner.run(
        _request('while (true) {}', interruptAfter: const Duration(seconds: 3)),
        timeout: const Duration(seconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // Well before the 30 second ceiling: the script itself was stopped.
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
  });

  test('without the deadline, whether the engine stops a loop', () async {
    final watch = Stopwatch()..start();
    Object? outcome;
    try {
      await ProviderRunner.run(
        _request('while (true) {}'),
        timeout: const Duration(seconds: 35),
      );
    } catch (error) {
      outcome = error;
    }
    // Informational: under 35 s means the native 20 s timeout interrupted
    // the loop; 35 s means only the Dart ceiling ended the wait.
    // ignore: avoid_print
    print(
      'NATIVE_TIMEOUT_PROBE ${watch.elapsed.inSeconds}s '
      '${outcome.runtimeType}: $outcome',
    );
    expect(outcome, isA<Exception>());
  }, timeout: const Timeout(Duration(seconds: 60)));
}
