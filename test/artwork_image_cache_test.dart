// The artwork disk cache measured against plain network images. Its own
// file: NetworkImage keeps one static HttpClient per test process, and
// this test needs it to use real HTTP (a local server).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/artwork_image.dart';

/// A real 64×96 PNG, like a small poster.
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 64, 96),
    Paint()..color = const Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(64, 96);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Serves [bytes] for every URL and counts downloads.
class _CountingFileService extends FileService {
  _CountingFileService(this.bytes, {this.status = 200});
  final Uint8List bytes;
  final int status;
  int downloads = 0;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    downloads++;
    return _Response(bytes, status);
  }
}

class _Response implements FileServiceResponse {
  _Response(this.bytes, [this.status = 200]);
  final Uint8List bytes;
  final int status;
  @override
  Stream<List<int>> get content => Stream.value(bytes);
  @override
  int get contentLength => bytes.length;
  @override
  int get statusCode => status;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 30));
  @override
  String? get eTag => null;
  @override
  String get fileExtension => '.png';
}

/// Decodes [provider] the way an Image widget would; returns the width.
Future<int> _load(ImageProvider provider) async {
  final completer = Completer<int>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      completer.complete(info.image.width);
      stream.removeListener(listener);
    },
    onError: (error, _) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 10));
}

/// The app restarting: the decoded-image memory cache starts empty.
void _relaunch() {
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tmdbUrl = 'https://image.tmdb.org/t/p/w342/poster.png';

  testWidgets('before and after: downloads across two launches, and the '
      'decoded size stays the same', (tester) async {
    await tester.runAsync(() async {
      final png = await _png();

      // Before: a plain network image, from a local server. The test
      // binding's mock HTTP is put back afterwards.
      final mockHttp = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = mockHttp);
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var served = 0;
      server.listen((request) {
        served++;
        request.response
          ..headers.contentType = ContentType('image', 'png')
          ..add(png)
          ..close();
      });
      final plain = 'http://127.0.0.1:${server.port}/poster.png';
      for (var launch = 0; launch < 2; launch++) {
        _relaunch();
        expect(await _load(ResizeImage(NetworkImage(plain), width: 32)), 32);
      }
      await server.close(force: true);

      // After: the artwork provider with a disk cache that outlives a
      // launch (same index file and storage).
      final root = await Directory.systemTemp.createTemp('artwork-test-');
      final files = MemoryCacheSystem();
      final service = _CountingFileService(png);
      CacheManager managerForLaunch() => CacheManager(
        Config(
          'artwork-test',
          stalePeriod: ArtworkCache.stale,
          maxNrOfCacheObjects: ArtworkCache.maxObjects,
          repo: JsonCacheInfoRepository.withFile(
            File('${root.path}/index.json'),
          ),
          fileSystem: files,
          fileService: service,
        ),
      );
      ArtworkCache.debugDisabled = false;
      for (var launch = 0; launch < 2; launch++) {
        _relaunch();
        final manager = managerForLaunch();
        ArtworkCache.debugManager = manager;
        expect(await _load(artworkProvider(tmdbUrl, cacheWidth: 32)), 32);
        await manager.store.dispose();
      }
      ArtworkCache.debugManager = null;
      ArtworkCache.debugDisabled = true;
      await root.delete(recursive: true);

      // ignore: avoid_print
      print(
        'BENCH artwork downloads over 2 launches: '
        'before=$served after=${service.downloads}',
      );
      expect(served, 2, reason: 'no disk cache: every launch downloads');
      expect(service.downloads, 1, reason: 'the second launch reads disk');
    });
  });

  group('when the disk cache fails', () {
    const url = 'https://image.tmdb.org/t/p/w342/fallback.png';

    CacheManager working(Directory root, FileService service) => CacheManager(
      Config(
        'artwork-fallback-test',
        repo: JsonCacheInfoRepository.withFile(File('${root.path}/index.json')),
        fileSystem: MemoryCacheSystem(),
        fileService: service,
      ),
    );

    setUp(() {
      ArtworkCache.debugDisabled = false;
      _relaunch();
    });
    tearDown(() {
      ArtworkCache.debugDisabled = true;
      ArtworkCache.debugManager = null;
      ArtworkCache.downloader = ArtworkFileService();
    });

    testWidgets('a broken cache still shows the image, downloaded directly', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final direct = _CountingFileService(await _png());
        ArtworkCache.downloader = direct;
        ArtworkCache.debugManager = _BrokenCacheManager();
        expect(await _load(artworkProvider(url, cacheWidth: 32)), 32);
        expect(direct.downloads, 1);
      });
    });

    testWidgets('a damaged cached file is replaced by a fresh download', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('artwork-bad-');
        final direct = _CountingFileService(await _png());
        ArtworkCache.downloader = direct;
        final cache = working(root, direct);
        ArtworkCache.debugManager = cache;
        await cache.putFile(url, Uint8List.fromList([1, 2, 3, 4]));
        expect(await _load(artworkProvider(url)), 64);
        expect(direct.downloads, 1);
        expect(
          await cache.getFileFromCache(url),
          isNull,
          reason: 'the damaged file is forgotten',
        );
        await cache.store.dispose();
        await root.delete(recursive: true);
      });
    });

    testWidgets('a refusal from the server is not retried', (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('artwork-404-');
        final service = _CountingFileService(Uint8List(0), status: 404);
        ArtworkCache.downloader = service;
        final cache = working(root, service);
        ArtworkCache.debugManager = cache;
        await expectLater(_load(artworkProvider(url)), throwsA(anything));
        expect(service.downloads, 1, reason: 'one request, no second try');
        await cache.store.dispose();
        await root.delete(recursive: true);
      });
    });
  });
}

/// A cache whose storage throws, as a broken disk or a missing plugin would.
class _BrokenCacheManager extends CacheManager {
  _BrokenCacheManager()
    : super(
        Config(
          'artwork-broken-test',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
        ),
      );

  @override
  Future<Never> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => throw const FileSystemException('The disk cache is unavailable.');
}
