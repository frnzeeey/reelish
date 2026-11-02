// The artwork disk cache on a real device or Windows, with the platform's
// own storage (SQLite index on Android, JSON index on Windows). Downloads
// one public TMDB poster, then reads it back from disk with a fresh cache
// manager, as after a restart. The file is removed afterwards.
//
//   flutter test integration_test/artwork_cache_test.dart -d <device|windows>
import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/widgets/artwork_image.dart';

const _poster =
    'https://image.tmdb.org/t/p/w342/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a poster is downloaded once, then served from disk', (_) async {
    final first = ArtworkCache.manager;
    await first.removeFile(_poster);

    final downloaded = await first.downloadFile(_poster);
    expect(downloaded.source, FileSource.Online);
    final bytes = await downloaded.file.length();

    // A new manager with the same key: what the next launch gets.
    PaintingBinding.instance.imageCache.clear();
    ArtworkCache.debugManager = null;
    final relaunched = CacheManager(
      Config(
        ArtworkCache.key,
        stalePeriod: ArtworkCache.stale,
        maxNrOfCacheObjects: ArtworkCache.maxObjects,
      ),
    );
    final cached = await relaunched.getFileFromCache(_poster);
    expect(cached, isNotNull);
    expect(cached!.source, FileSource.Cache);
    expect(await cached.file.length(), bytes);
    // ignore: avoid_print
    print('ARTWORK_CACHE ok bytes=$bytes path=${cached.file.parent.path}');

    // What the widgets use: the provider decodes the cached poster.
    ArtworkCache.debugManager = relaunched;
    final stream = artworkProvider(
      _poster,
      cacheWidth: 100,
    ).resolve(ImageConfiguration.empty);
    final width = Completer<int>();
    stream.addListener(
      ImageStreamListener(
        (info, _) => width.complete(info.image.width),
        onError: (error, _) => width.completeError(error),
      ),
    );
    expect(await width.future.timeout(const Duration(seconds: 20)), 100);

    await relaunched.removeFile(_poster);
    ArtworkCache.debugManager = null;
  });
}
