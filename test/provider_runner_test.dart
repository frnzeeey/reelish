import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/provider_runner.dart';

// Needs the QuickJS library. On Windows, put
// third_party/flutter_js/windows/shared on PATH before running.
ProviderRunRequest _request(
  String code, {
  String? bundle,
  bool crypto = false,
}) => ProviderRunRequest(
  pluginId: 'test',
  code: code,
  codeUrl: 'https://repo.example/test.js',
  tmdbId: '603',
  mediaType: 'tv',
  season: 2,
  episode: 5,
  bundle: bundle,
  needsCryptoJs: crypto,
  // Limits are covered in quickjs_windows_limits_test.dart (Windows) and
  // integration_test/provider_runtime_test.dart (devices).
  memoryLimit: null,
);

void main() {
  test('runs getStreams on a background isolate with its arguments', () async {
    final streams = await ProviderRunner.run(
      _request('''
        module.exports.getStreams = async (id, type, season, episode) => {
          await new Promise(resolve => setTimeout(resolve, 10));
          return [{
            name: [id, type, season, episode].join('/'),
            url: 'https://cdn.example/video.m3u8',
            headers: { Referer: 'https://site.example/' }
          }];
        };
      '''),
    );
    expect(streams, hasLength(1));
    expect(streams.single['name'], '603/tv/2/5');
    expect(streams.single['headers'], {'Referer': 'https://site.example/'});
  });

  test(
    'scripts can require axios, read process.env and make random ids',
    () async {
      final streams = await ProviderRunner.run(
        _request('''
        const axios = require('axios');
        const esm = require('node:axios').default;
        module.exports.getStreams = async () => [{
          name: [typeof axios.get, typeof esm.create, typeof process.env.VIDSRC,
            crypto.randomUUID().length].join('/'),
          url: 'https://cdn.example/video.m3u8'
        }];
      '''),
      );
      expect(streams.single['name'], 'function/function/undefined/36');
    },
  );

  test('the calling isolate keeps running while a provider computes', () async {
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    addTearDown(timer.cancel);
    await ProviderRunner.run(
      _request('''
        module.exports.getStreams = async () => {
          const end = Date.now() + 600;
          while (Date.now() < end) {}
          return [];
        };
      '''),
    );
    // Run synchronously on this isolate, the busy loop would block every tick.
    expect(ticks, greaterThan(20));
  });

  test('loads the bundled CryptoJS module when requested', () async {
    final bundle = await File('assets/js/cheerio_bundle.js').readAsString();
    final streams = await ProviderRunner.run(
      _request(
        '''
        const CryptoJS = require('crypto-js');
        module.exports.getStreams = async () => [{
          name: CryptoJS.MD5('reelish').toString(),
          url: 'https://cdn.example/video.mp4'
        }];
      ''',
        bundle: bundle,
        crypto: true,
      ),
    );
    expect(streams.single['name'], matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('provider errors reach the caller with their message', () async {
    await expectLater(
      ProviderRunner.run(_request('throw new Error("site changed");')),
      throwsA(
        isA<ProviderRunException>().having(
          (e) => e.message,
          'message',
          contains('site changed'),
        ),
      ),
    );
    await expectLater(
      ProviderRunner.run(_request('module.exports = {};')),
      throwsA(isA<ProviderRunException>()),
    );
  });

  test(
    'a provider stuck in synchronous code still returns a timeout',
    () async {
      // The run's own 2 s ceiling ends the wait long before the interrupt
      // deadline, so the caller (and its runtime slot) never waits on a build
      // whose engine cannot stop the loop.
      final watch = Stopwatch()..start();
      await expectLater(
        ProviderRunner.run(
          _request('while (true) {}'),
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    },
  );

  group('abort', () {
    test('stops a provider waiting on its upstream', () async {
      // A lookup the viewer left: the run must end (and free its runtime
      // slot) now, not when the provider's 8 s request returns.
      final abort = Completer<void>();
      final watch = Stopwatch()..start();
      final run = ProviderRunner.run(
        _request(
          'module.exports.getStreams = () =>'
          '  new Promise(r => setTimeout(() => r([{ url: "https://cdn.example/a.m3u8" }]), 8000));',
        ),
        abort: abort.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      abort.complete();
      await expectLater(run, throwsA(isA<ProviderRunCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('before the runtime starts still stops the run', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        ProviderRunner.run(
          _request(
            'module.exports.getStreams = () => new Promise(r => setTimeout(() => r([]), 8000));',
          ),
          abort: Future.value(),
        ),
        throwsA(isA<ProviderRunCancelled>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a signal that never fires changes nothing', () async {
      final streams = await ProviderRunner.run(
        _request(
          'module.exports.getStreams = async (id, type, s, e) =>'
          '  [{ name: [id, type, s, e].join("/"), url: "https://cdn.example/a.m3u8" }];',
        ),
        abort: Completer<void>().future,
      );
      expect(streams.single['name'], '603/tv/2/5');
      await expectLater(
        ProviderRunner.run(
          _request('throw new Error("site changed");'),
          abort: Completer<void>().future,
        ),
        throwsA(
          isA<ProviderRunException>().having(
            (e) => e.message,
            'message',
            contains('site changed'),
          ),
        ),
      );
    });

    test('a stuck synchronous provider still returns a timeout', () async {
      await expectLater(
        ProviderRunner.run(
          _request('while (true) {}'),
          timeout: const Duration(seconds: 2),
          abort: Completer<void>().future,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
