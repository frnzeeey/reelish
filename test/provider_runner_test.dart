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
  // The Windows test DLL has no JS_SetMemoryLimit export.
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
}
