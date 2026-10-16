@TestOn('windows')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/provider_runner.dart';

// The Windows QuickJS bridge (third_party/flutter_js/windows/shared) exports
// JS_SetMemoryLimit and JS_SetInterruptHandler, so desktop runs get the same
// sandbox limits as Android: the 64 MiB heap cap and the interrupt deadline.
ProviderRunRequest _request(String code, {Duration? interruptAfter}) =>
    ProviderRunRequest(
      pluginId: 'windows-limits',
      code: code,
      codeUrl: 'https://repo.example/windows-limits.js',
      tmdbId: '603',
      mediaType: 'movie',
      interruptAfter: interruptAfter ?? const Duration(seconds: 40),
    );

void main() {
  test('a provider runs with the default 64 MiB memory limit', () async {
    final request = _request('''
      module.exports.getStreams = async (id, type) =>
        [{ name: type, url: 'https://cdn.example/' + id + '.m3u8' }];
    ''');
    expect(request.memoryLimit, 64 * 1024 * 1024);
    final streams = await ProviderRunner.run(request);
    expect(streams.single['url'], 'https://cdn.example/603.m3u8');
  });

  test('a script that exceeds the heap cap fails instead of growing', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      ProviderRunner.run(
        _request('''
          module.exports.getStreams = async () => {
            const hoard = [];
            while (true) hoard.push(new Array(1 << 20).fill(1.5));
          };
        '''),
        timeout: const Duration(seconds: 30),
      ),
      throwsA(isA<ProviderRunException>()),
    );
    // QuickJS reports out-of-memory as soon as the cap is reached; this is
    // not the run's timeout ending the wait.
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('the interrupt deadline stops a synchronous loop', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      ProviderRunner.run(
        _request('while (true) {}', interruptAfter: const Duration(seconds: 2)),
        timeout: const Duration(seconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // Well before the 30 s ceiling: the script itself was stopped, so its
    // isolate does not keep a CPU core busy afterwards.
    expect(watch.elapsed, lessThan(const Duration(seconds: 12)));
  });

  test('a loop inside getStreams is interrupted too', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      ProviderRunner.run(
        _request('''
          module.exports.getStreams = async () => { for (;;) {} };
        ''', interruptAfter: const Duration(seconds: 2)),
        timeout: const Duration(seconds: 30),
      ),
      throwsA(anyOf(isA<TimeoutException>(), isA<ProviderRunException>())),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 12)));
  });

  test('the runtime is usable again after an interrupted run', () async {
    await expectLater(
      ProviderRunner.run(
        _request('while (true) {}', interruptAfter: const Duration(seconds: 1)),
        timeout: const Duration(seconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    final streams = await ProviderRunner.run(
      _request('''
        module.exports.getStreams = async () => [{ url: 'https://cdn.example/ok' }];
      '''),
    );
    expect(streams.single['url'], 'https://cdn.example/ok');
  });
}
