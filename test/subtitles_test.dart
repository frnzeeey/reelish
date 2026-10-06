import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/subtitle_language.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/models/subtitle_addon.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/subtitle_addon_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/src/services/subtitle_loader.dart';
import 'package:onfeed/src/widgets/player/subtitle_picker_sheet.dart';

const _os = 'OpenSubtitles v3';

NetworkDestinationValidator _network() => NetworkDestinationValidator(
  lookup: (_) async => [InternetAddress('8.8.8.8')],
);

/// Shapes returned by opensubtitles-v3.strem.io (fields captured from the
/// live addon: id, url, lang, subtitleFileName, season, episode, ...).
Map<String, Object?> _entry(
  String id,
  String lang, {
  String file = 'Show.S02E03.WEB.srt',
  int season = 2,
  int episode = 3,
  String? url,
}) => {
  'id': id,
  'url':
      url ??
      'https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/$id',
  'SubEncoding': 'UTF-8',
  'lang': lang,
  'm': 'i',
  'g': '11',
  'subtitleFileName': file,
  'movieReleaseName': 'Show',
  'fpsMilli': 23976,
  'season': season,
  'episode': episode,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubtitleAddonService.resetCache();
    SubtitleLoader.resetCache();
  });

  group('SubtitleLanguage normalization', () {
    test('normalizes OpenSubtitles and provider language values', () {
      const cases = {
        'eng': 'en',
        'pob': 'pt-BR',
        'por': 'pt',
        'spa': 'es',
        'ell': 'el',
        'cze': 'cs',
        'fre': 'fr',
        'fil': 'tl',
        'English': 'en',
        'English (Forced)': 'en',
        'Portuguese (Brazil)': 'pt-BR',
        'Spanish (Latin America)': 'es-419',
        'es_419': 'es-419',
        'zh_tw': 'zh-TW',
        'pt_BR': 'pt-BR',
        'de-AT': 'de-AT',
        '': 'unknown',
        'klingon dialect': 'unknown',
      };
      for (final MapEntry(key: raw, value: code) in cases.entries) {
        expect(SubtitleLanguage.normalize(raw), code, reason: raw);
      }
    });

    test('names languages for people, not codes', () {
      expect(SubtitleLanguage.name('en'), 'English');
      expect(SubtitleLanguage.name('tl'), 'Filipino');
      expect(SubtitleLanguage.name('pt-BR'), 'Portuguese (Brazil)');
      expect(SubtitleLanguage.name('ja'), 'Japanese');
      expect(SubtitleLanguage.name('unknown'), 'Unknown');
    });

    test('a plain preference accepts regional variants, not the reverse', () {
      expect(SubtitleLanguage.matches('pob', 'pt'), isTrue);
      expect(SubtitleLanguage.matches('por', 'pt-BR'), isFalse);
      expect(SubtitleLanguage.matches('eng', 'en'), isTrue);
      expect(SubtitleLanguage.matches('spa', 'en'), isFalse);
    });
  });

  group('OpenSubtitles request', () {
    test('needs an IMDb id, and season and episode for series', () {
      expect(SubtitleRequest.create(type: 'movie', imdbId: '603'), isNull);
      expect(
        SubtitleRequest.create(type: 'series', imdbId: 'tt0944947'),
        isNull,
      );
      final movie = SubtitleRequest.create(type: 'movie', imdbId: 'tt0111161')!;
      expect(movie.videoId, 'tt0111161');
      final episode = SubtitleRequest.create(
        type: 'series',
        imdbId: 'tt0944947',
        season: 2,
        episode: 3,
      )!;
      expect(episode.videoId, 'tt0944947:2:3');
      expect(episode.type, 'series');
    });

    test('encodes the video id as a URL path segment', () {
      expect(
        SubtitleAddon.openSubtitlesV3
            .resourceUri('series', 'tt0944947:2:3')
            .toString(),
        'https://opensubtitles-v3.strem.io/subtitles/series/tt0944947%3A2%3A3.json',
      );
      expect(SubtitleAddon.encodeSegment('a-b_c.d~e f'), 'a-b_c.d~e%20f');
    });
  });

  group('OpenSubtitles parsing', () {
    final s2e3 = SubtitleRequest.create(
      type: 'series',
      imdbId: 'tt0944947',
      season: 2,
      episode: 3,
    )!;

    test('keeps only the requested episode, HTTPS URLs and one copy each', () {
      final results = SubtitleAddonService.parse(
        {
          'subtitles': [
            _entry('1', 'eng'),
            _entry('1', 'eng'), // duplicate record
            _entry('2', 'eng', season: 1), // wrong season
            _entry('3', 'eng', episode: 2), // wrong episode
            _entry('4', 'eng', url: 'http://insecure.example/4.srt'),
            {'id': '5', 'lang': 'eng'}, // no url
            _entry('6', 'pob', file: 'Show.S02E03.HI.srt'),
          ],
        },
        s2e3,
        addonName: _os,
      );
      expect(results.map((track) => track.id), ['1', '6']);
      expect(results.first.lang, 'en');
      expect(results.first.source, SubtitleSource.addon);
      expect(results.first.detail, 'Show.S02E03.WEB.srt');
      expect(results.first.addonName, 'OpenSubtitles v3');
      expect(results.last.lang, 'pt-BR');
      expect(results.last.hearingImpaired, isTrue);
      expect(results.first.hearingImpaired, isFalse);
    });

    test('reads the language from fallback fields', () {
      final movie = SubtitleRequest.create(type: 'movie', imdbId: 'tt1')!;
      final results = SubtitleAddonService.parse(
        {
          'subtitles': [
            {
              'id': 'a',
              'url': 'https://x.example/a.srt',
              'language': 'Japanese',
            },
            {'id': 'b', 'url': 'https://x.example/b.srt', 'label': 'Korean'},
            {'id': 'c', 'url': 'https://x.example/c.srt'},
          ],
        },
        movie,
        addonName: _os,
      );
      expect(results.map((track) => track.lang), ['ja', 'ko', 'unknown']);
    });

    test('tolerates malformed responses', () {
      final movie = SubtitleRequest.create(type: 'movie', imdbId: 'tt1')!;
      expect(SubtitleAddonService.parse(null, movie, addonName: _os), isEmpty);
      expect(
        SubtitleAddonService.parse({'subtitles': 'x'}, movie, addonName: _os),
        isEmpty,
      );
      expect(
        SubtitleAddonService.parse([1, 2], movie, addonName: _os),
        isEmpty,
      );
    });
  });

  group('OpenSubtitles search', () {
    final movie = SubtitleRequest.create(type: 'movie', imdbId: 'tt0111161')!;

    SubtitleAddonService service(MockClient client, {List<Duration>? waits}) =>
        SubtitleAddonService(
          testClient: client,
          network: _network(),
          wait: (delay) async => waits?.add(delay),
        );

    test('shares concurrent searches and caches the result', () async {
      var requests = 0;
      Uri? requested;
      final client = MockClient((request) async {
        requests++;
        requested = request.url;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return http.Response(
          jsonEncode({
            'subtitles': [_entry('1', 'eng', season: 0, episode: 0)],
          }),
          200,
        );
      });
      final subtitles = service(client);
      final results = await Future.wait([
        subtitles.searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        subtitles.searchAddon(SubtitleAddon.openSubtitlesV3, movie),
      ]);
      expect(results.every((list) => list.length == 1), isTrue);
      expect(
        await subtitles.searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        hasLength(1),
      );
      expect(requests, 1);
      expect(requested?.path, '/subtitles/movie/tt0111161.json');
    });

    test('a missing title is an empty result, not an error', () async {
      final client = MockClient((_) async => http.Response('Not found', 404));
      expect(
        await service(client).searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        isEmpty,
      );
    });

    test('retries a 429 once only when asked for a short wait', () async {
      var requests = 0;
      final waits = <Duration>[];
      final client = MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response('', 429, headers: {'retry-after': '2'})
            : http.Response(jsonEncode({'subtitles': []}), 200);
      });
      expect(
        await service(
          client,
          waits: waits,
        ).searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        isEmpty,
      );
      expect(requests, 2);
      expect(waits, [const Duration(seconds: 2)]);
    });

    test('does not loop on rate limiting', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 429, headers: {'retry-after': '120'});
      });
      await expectLater(
        service(client).searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        throwsA(isA<SubtitleSearchException>()),
      );
      expect(requests, 1);
    });

    test('server and network failures give a short message', () async {
      final down = MockClient((_) async => http.Response('', 503));
      await expectLater(
        service(down).searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        throwsA(
          isA<SubtitleSearchException>().having(
            (e) => e.message,
            'message',
            'Subtitles are unavailable right now.',
          ),
        ),
      );
      SubtitleAddonService.resetCache();
      final offline = MockClient(
        (_) async => throw const SocketException('offline'),
      );
      await expectLater(
        service(offline).searchAddon(SubtitleAddon.openSubtitlesV3, movie),
        throwsA(isA<SubtitleSearchException>()),
      );
    });
  });

  group('subtitle files', () {
    test('decodes UTF-8 with BOM, UTF-16 and legacy Latin-1', () {
      expect(
        decodeSubtitleBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('日本語 é')]),
        '日本語 é',
      );
      final utf16 = [0xFF, 0xFE];
      for (final unit in '한국어'.codeUnits) {
        utf16
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      expect(decodeSubtitleBytes(utf16), '한국어');
      expect(decodeSubtitleBytes([0x63, 0x61, 0x66, 0xE9]), 'café');
    });

    test('parses SRT with CRLF, tags and multiple lines', () {
      final cues = parseSubtitles(
        '1\r\n00:00:00,993 --> 00:00:03,128\r\n<i>Tomorrow</i> you\'ll ride\r\n'
        'south &amp; west.\r\n\r\n2\r\n01:02:03,500 --> 01:02:04,000\r\nÑandú 中文\r\n',
      );
      expect(cues, hasLength(2));
      expect(cues.first.start, closeTo(.993, .0001));
      expect(cues.first.text, "Tomorrow you'll ride\nsouth & west.");
      expect(cues.last.start, closeTo(3723.5, .0001));
      expect(cues.last.text, 'Ñandú 中文');
    });

    test('parses WebVTT and ASS', () {
      final vtt = parseSubtitles(
        'WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nHello\n',
      );
      expect(vtt.single.start, 1.0);
      expect(vtt.single.end, 2.5);
      final ass = parseSubtitles(
        '[Script Info]\nTitle: x\n\n[Events]\n'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
        r'Dialogue: 0,0:00:05.10,0:00:07.00,Default,,0,0,0,,{\i1}Hi,{\i0} there\Nfriend',
      );
      expect(ass.single.start, closeTo(5.1, .0001));
      expect(ass.single.text, 'Hi, there\nfriend');
    });
  });

  group('SubtitleLoader', () {
    const track = SubtitleTrack(
      url: 'https://subs.example.com/file/1',
      source: SubtitleSource.addon,
    );
    const srt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';

    SubtitleLoader loader(MockClient client) =>
        SubtitleLoader(network: _network(), testClient: client);

    test('downloads once and reuses the parsed file', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response.bytes(utf8.encode(srt), 200);
      });
      final subtitles = loader(client);
      expect((await subtitles.load(track)).single.text, 'Hello');
      expect((await subtitles.load(track)).single.text, 'Hello');
      expect(requests, 1);
    });

    test('unpacks gzip and refuses archives and empty files', () async {
      final gzipped = MockClient(
        (_) async => http.Response.bytes(gzip.encode(utf8.encode(srt)), 200),
      );
      expect((await loader(gzipped).load(track)).single.text, 'Hello');

      SubtitleLoader.resetCache();
      final zip = MockClient(
        (_) async => http.Response.bytes([0x50, 0x4B, 0x03, 0x04, 1, 2], 200),
      );
      await expectLater(
        loader(zip).load(track),
        throwsA(isA<SubtitleLoadException>()),
      );

      SubtitleLoader.resetCache();
      final empty = MockClient(
        (_) async => http.Response('not subtitles', 200),
      );
      await expectLater(
        loader(empty).load(track),
        throwsA(isA<SubtitleLoadException>()),
      );
    });
  });

  group('subtitle menu', () {
    SubtitleTrack track(String id, String lang, {bool sdh = false}) =>
        SubtitleTrack(
          url: 'https://x.example/$id',
          id: id,
          lang: lang,
          hearingImpaired: sdh,
          source: SubtitleSource.addon,
          addonName: _os,
        );

    test('orders preferred languages first, then by name, unknown last', () {
      final ordered = SubtitleMenu.ordered(
        [
          track('1', 'spa'),
          track('2', 'unknown'),
          track('3', 'eng'),
          track('4', 'fil'),
          track('5', 'ell'),
          track('6', 'fil'),
        ],
        ['tl'],
      );
      expect(ordered.map((t) => t.id), ['4', '6', '3', '5', '1', '2']);
    });

    test('labels hearing-impaired subtitles', () {
      expect(
        SubtitleMenu.titleOf(track('1', 'eng', sdh: true)),
        'English (SDH)',
      );
      expect(SubtitleMenu.titleOf(track('2', 'pob')), 'Portuguese (Brazil)');
    });

    testWidgets('shows searching, then results as they arrive', (tester) async {
      final menu = ValueNotifier(
        const SubtitleMenu(status: ExternalSubtitleStatus.loading),
      );
      addTearDown(menu.dispose);
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SubtitlePickerSheet(menu: menu, onRetry: () => retries++),
          ),
        ),
      );
      expect(find.text('Searching subtitle addons…'), findsOneWidget);

      menu.value = menu.value.copyWith(
        status: ExternalSubtitleStatus.ready,
        addonSubtitles: [track('1', 'eng'), track('2', 'eng', sdh: true)],
        embedded: const [
          SubtitleTrack(
            url: '',
            id: '3',
            lang: 'ja',
            source: SubtitleSource.embedded,
          ),
        ],
      );
      await tester.pump();
      expect(find.text('Searching subtitle addons…'), findsNothing);
      expect(find.text('IN VIDEO'), findsOneWidget);
      expect(find.text('Japanese'), findsOneWidget);
      expect(find.text('OPENSUBTITLES V3'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('English (SDH)'), findsOneWidget);

      menu.value = const SubtitleMenu(
        status: ExternalSubtitleStatus.failed,
        message: 'Subtitle search is busy. Try again in a moment.',
      );
      await tester.pump();
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });
  });

  group('subtitle addons', () {
    test('reads manifests with plain and object resources', () {
      final plain = SubtitleAddon.fromManifest(
        'https://subs.example.com/manifest.json',
        {
          'id': 'plain',
          'name': 'Plain',
          'resources': ['subtitles'],
          'types': ['movie', 'series'],
          'idPrefixes': ['tt'],
        },
      );
      expect(plain.supports('series', 'tt1:1:2'), isTrue);
      expect(plain.supports('tv', 'tt1:1:2'), isTrue);
      expect(plain.supports('movie', 'kitsu:1'), isFalse);

      final scoped = SubtitleAddon.fromManifest(
        'https://subs.example.com/manifest.json',
        {
          'id': 'scoped',
          'name': 'Scoped',
          'types': ['movie', 'series'],
          'resources': [
            'stream',
            {
              'name': 'subtitles',
              'types': ['movie'],
              'idPrefixes': ['tt'],
            },
          ],
        },
      );
      expect(scoped.supports('movie', 'tt1'), isTrue);
      expect(scoped.supports('series', 'tt1:1:1'), isFalse);

      expect(
        () =>
            SubtitleAddon.fromManifest('https://x.example.com/manifest.json', {
              'id': 'streams',
              'resources': ['stream'],
            }),
        throwsFormatException,
      );
    });

    test('builds resource URLs, keeping configuration', () {
      const configured = SubtitleAddon(
        manifestUrl: 'https://subs.example.com/abc123/manifest.json?lang=en',
        id: 'x',
        name: 'X',
      );
      expect(
        configured.resourceUri('tv', 'tt0944947:2:3').toString(),
        'https://subs.example.com/abc123/subtitles/series/'
        'tt0944947%3A2%3A3.json?lang=en',
      );
    });

    test('searches every compatible addon and reports each one', () async {
      final storage = StorageService();
      await storage.saveSetting(
        'onfeed.subtitleAddons.v1',
        jsonEncode([
          SubtitleAddon.openSubtitlesV3.toJson(),
          const SubtitleAddon(
            manifestUrl: 'https://second.example.com/manifest.json',
            id: 'second',
            name: 'Second',
            types: ['movie', 'series'],
            idPrefixes: ['tt'],
          ).toJson(),
          const SubtitleAddon(
            manifestUrl: 'https://anime.example.com/manifest.json',
            id: 'anime',
            name: 'Anime only',
            idPrefixes: ['kitsu'],
          ).toJson(),
          const SubtitleAddon(
            manifestUrl: 'https://off.example.com/manifest.json',
            id: 'off',
            name: 'Disabled',
            enabled: false,
          ).toJson(),
        ]),
      );
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.host);
        if (request.url.host == 'second.example.com') {
          return http.Response('', 503);
        }
        return http.Response(
          jsonEncode({
            'subtitles': [_entry('1', 'eng', season: 0, episode: 0)],
          }),
          200,
        );
      });
      final service = SubtitleAddonService(
        storage: storage,
        testClient: client,
        network: _network(),
      );
      final reports = <String, String>{};
      final searched = await service.search(
        SubtitleRequest.create(type: 'movie', imdbId: 'tt0111161')!,
        onAddon: (addon, results, error) => reports[addon.name] = error == null
            ? '${results.length} results'
            : 'failed',
      );
      expect(searched.map((addon) => addon.id), [
        'org.stremio.opensubtitlesv3',
        'second',
      ]);
      expect(reports, {'OpenSubtitles v3': '1 results', 'Second': 'failed'});
      expect(requested, isNot(contains('anime.example.com')));
      expect(requested, isNot(contains('off.example.com')));
    });

    test('installs only https addons that provide subtitles', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'streams.example.com') {
          return http.Response(
            jsonEncode({
              'id': 'streams',
              'resources': ['stream'],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'org.example.subs',
            'name': 'Example Subs',
            'resources': ['subtitles'],
            'types': ['movie'],
            'idPrefixes': ['tt'],
          }),
          200,
        );
      });
      final service = SubtitleAddonService(
        testClient: client,
        network: _network(),
      );
      await expectLater(
        service.install('http://subs.example.com/manifest.json'),
        throwsFormatException,
      );
      await expectLater(
        service.install('https://streams.example.com/manifest.json'),
        throwsFormatException,
      );
      final addon = await service.install('https://subs.example.com/config');
      expect(
        addon.manifestUrl,
        'https://subs.example.com/config/manifest.json',
      );
      expect((await service.addons()).map((a) => a.name), [
        'OpenSubtitles v3',
        'Example Subs',
      ]);
      await expectLater(
        service.install('https://subs.example.com/config/manifest.json'),
        throwsFormatException,
      );
    });
  });

  group('remembered subtitle choice', () {
    test('round-trips Off and a language choice per title', () async {
      final storage = StorageService();
      await storage.rememberSubtitle(
        'series:1399',
        RememberedSubtitle.of(
          const SubtitleTrack(
            url: 'https://x.example.com/1',
            lang: 'pt-BR',
            source: SubtitleSource.addon,
            addonName: 'OpenSubtitles v3',
            hearingImpaired: true,
          ),
        ),
      );
      await storage.rememberSubtitle(
        'movie:603',
        const RememberedSubtitle.off(),
      );

      final series = await storage.rememberedSubtitle('series:1399');
      expect(series?.off, isFalse);
      expect(series?.language, 'pt-BR');
      expect(series?.source, SubtitleSource.addon);
      expect(series?.addonName, 'OpenSubtitles v3');
      expect(series?.hearingImpaired, isTrue);
      expect((await storage.rememberedSubtitle('movie:603'))?.off, isTrue);
      expect(await storage.rememberedSubtitle('movie:1'), isNull);
    });

    test('ignores unreadable stored data', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.player.subtitleChoice.v1': '{not json',
      });
      expect(await StorageService().rememberedSubtitle('movie:1'), isNull);
    });
  });
}
