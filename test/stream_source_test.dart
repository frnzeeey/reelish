import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';

void main() {
  group('StreamSource.fromJson', () {
    test('unwraps a URL object and merges its playback headers', () {
      final source = StreamSource.fromJson({
        'name': 'Example',
        'url': {
          'url': 'https://media.example/video.m3u8',
          'headers': {'Referer': 'https://site.example/'},
        },
        'headers': {'User-Agent': 'Test player'},
        'behaviorHints': {
          'proxyHeaders': {
            'request': {'Cookie': 'session=abc'},
          },
        },
      });

      expect(source.url, 'https://media.example/video.m3u8');
      expect(source.headers, {
        'Referer': 'https://site.example/',
        'User-Agent': 'Test player',
        'Cookie': 'session=abc',
      });
    });

    test('recognizes a torrent info hash without a URL', () {
      final source = StreamSource.fromJson({'infoHash': 'ABC123'});

      expect(source.isTorrent, isTrue);
    });
  });
}
