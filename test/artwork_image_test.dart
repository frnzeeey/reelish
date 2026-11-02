import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/widgets/artwork_image.dart';

void main() {
  test('only TMDB artwork over HTTPS is cached on disk', () {
    ArtworkCache.debugDisabled = false;
    addTearDown(() => ArtworkCache.debugDisabled = true);
    expect(
      ArtworkCache.caches('https://image.tmdb.org/t/p/w342/poster.png'),
      isTrue,
    );
    expect(
      ArtworkCache.caches('http://image.tmdb.org/t/p/w342/a.png'),
      isFalse,
    );
    expect(ArtworkCache.caches('https://repo.example/logo.png'), isFalse);
    expect(ArtworkCache.caches('not a url'), isFalse);
  });

  group('ArtworkFileService', () {
    const poster = 'https://image.tmdb.org/t/p/w342/a.jpg';

    test('a Content-Type holding a path never becomes the file name', () async {
      final service = ArtworkFileService(
        client: MockClient(
          (request) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': r'image/..\..\..\AppData\evil.bat'},
          ),
        ),
      );
      final response = await service.get(poster);
      expect(response.fileExtension, '.img');

      final jpeg = ArtworkFileService(
        client: MockClient(
          (_) async => http.Response.bytes(
            [1],
            200,
            headers: {'content-type': 'image/jpeg'},
          ),
        ),
      );
      expect((await jpeg.get(poster)).fileExtension, '.jpg');
    });

    test('redirects stay on TMDB, at most three', () async {
      final requested = <String>[];
      final service = ArtworkFileService(
        client: MockClient((request) async {
          requested.add(request.url.toString());
          if (request.url.path.endsWith('a.jpg')) {
            return http.Response(
              '',
              302,
              headers: {'location': '/t/p/w342/b.jpg'},
            );
          }
          if (request.url.path.endsWith('b.jpg')) {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://evil.example/x.jpg'},
            );
          }
          return http.Response('image', 200);
        }),
      );
      await expectLater(
        service.get(poster),
        throwsA(isA<HttpExceptionWithStatus>()),
      );
      expect(requested, [poster, 'https://image.tmdb.org/t/p/w342/b.jpg']);

      final loop = ArtworkFileService(
        client: MockClient(
          (_) async =>
              http.Response('', 302, headers: {'location': '/t/p/w342/a.jpg'}),
        ),
      );
      await expectLater(
        loop.get(poster),
        throwsA(isA<HttpExceptionWithStatus>()),
      );
    });

    test('a file over the size limit is refused', () async {
      final service = ArtworkFileService(
        client: MockClient(
          (_) async => http.Response.bytes(
            List.filled(ArtworkFileService.maxBytes + 1, 0),
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );
      final response = await service.get(poster);
      await expectLater(response.content.drain<void>(), throwsA(anything));
    });

    test('other hosts are refused before any request', () async {
      var requests = 0;
      final service = ArtworkFileService(
        client: MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
      );
      await expectLater(
        service.get('https://evil.example/a.jpg'),
        throwsA(isA<HttpExceptionWithStatus>()),
      );
      await expectLater(
        service.get('http://image.tmdb.org/t/p/w342/a.jpg'),
        throwsA(isA<HttpExceptionWithStatus>()),
      );
      expect(requests, 0);
    });
  });

  testWidgets('ArtworkImage keeps the error builder of Image.network', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkImage.network(
          'https://repo.example/missing.png',
          errorBuilder: (_, _, _) => const Text('fallback'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fallback'), findsOneWidget);
  });
}
