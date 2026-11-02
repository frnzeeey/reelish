// Movie and series artwork from TMDB's image CDN, kept on disk so a launch
// does not download every poster again. API response caching is separate
// (TmdbResponseCache); this is images only.
import 'dart:async';
import 'dart:io';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// Where TMDB artwork is kept on disk: the OS cache directory (the system
/// may clear it), at most [maxObjects] files, each dropped after [stale]
/// without use. Posters (w342/w500) are about 30–80 KB and backdrops
/// (w1280) about 150–300 KB, so the limit is roughly 60–100 MB.
abstract final class ArtworkCache {
  static const key = 'reelishArtwork';
  static const maxObjects = 600;
  static const stale = Duration(days: 30);

  static CacheManager? _manager;
  static CacheManager get manager => _manager ??= CacheManager(
    Config(
      key,
      stalePeriod: stale,
      maxNrOfCacheObjects: maxObjects,
      fileService: downloader,
    ),
  );

  /// Downloads for the cache, and directly when the cache is unavailable.
  static FileService downloader = ArtworkFileService();

  /// Replaces the disk cache (tests).
  @visibleForTesting
  static set debugManager(CacheManager? value) => _manager = value;

  /// Turns the disk cache off, so artwork loads as plain network images
  /// (widget tests, where there is no file system plugin).
  @visibleForTesting
  static bool debugDisabled = false;

  /// Only TMDB's own HTTPS image host is cached on disk. Other images, such
  /// as add-on logos from third-party manifests, load as before.
  static bool caches(String url) {
    if (debugDisabled) return false;
    final uri = Uri.tryParse(url);
    return uri != null && isArtworkHost(uri);
  }

  /// HTTPS on TMDB's image host, the only place artwork is downloaded from
  /// into the disk cache (redirects included).
  static bool isArtworkHost(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'image.tmdb.org' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  /// Deletes the cached artwork files (not API responses or user data).
  static Future<void> clear() => manager.emptyCache();
}

/// [url] as an image provider: from the disk cache for TMDB artwork, from
/// the network otherwise, decoded at [cacheWidth] × [cacheHeight] when given
/// (as `Image.network` does), so memory use is unchanged.
ImageProvider artworkProvider(String url, {int? cacheWidth, int? cacheHeight}) {
  final ImageProvider source = ArtworkCache.caches(url)
      ? ArtworkImageProvider(url)
      : NetworkImage(url);
  return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, source);
}

/// TMDB artwork through [ArtworkCache], never worse than a plain network
/// image: when the disk cache itself fails (storage, its database or a
/// missing plugin), the image is downloaded directly, with the same limits,
/// and shown uncached; a cached file that does not decode is deleted and
/// downloaded again. Only a refusal from the server (such as 404) ends in
/// the widget's error builder, as it did with `Image.network`.
class ArtworkImageProvider extends ImageProvider<ArtworkImageProvider> {
  const ArtworkImageProvider(this.url);

  final String url;

  @override
  Future<ArtworkImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ArtworkImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    ArtworkImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: 'artwork',
    informationCollector: () => [
      ErrorDescription('Artwork could not be loaded.'),
    ],
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? cached;
    try {
      cached = await (await ArtworkCache.manager.getSingleFile(
        url,
      )).readAsBytes();
    } on HttpExceptionWithStatus {
      // The server answered, and not with the image: retrying cannot help.
      rethrow;
    } catch (_) {
      // The disk cache is unavailable here; fall through to a download.
    }
    if (cached != null && cached.isNotEmpty) {
      try {
        return await decode(await ui.ImmutableBuffer.fromUint8List(cached));
      } catch (_) {
        // A damaged cache file: forget it and download a fresh copy.
        try {
          await ArtworkCache.manager.removeFile(url);
        } catch (_) {}
      }
    }
    final bytes = await _downloadDirect();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  /// The image straight from TMDB, bypassing the cache, through the same
  /// downloader (host, redirect and size limits).
  Future<Uint8List> _downloadDirect() async {
    final response = await ArtworkCache.downloader.get(url);
    if (response.statusCode != 200) {
      throw HttpExceptionWithStatus(
        response.statusCode,
        'Artwork download failed.',
        uri: Uri.tryParse(url),
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.content) {
      bytes.add(chunk);
    }
    if (bytes.isEmpty) throw const HttpException('Artwork was empty.');
    return bytes.takeBytes();
  }

  @override
  bool operator ==(Object other) =>
      other is ArtworkImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// A drop-in for `Image.network` that keeps TMDB artwork on disk. The same
/// placeholders, fade-ins and error builders apply.
abstract final class ArtworkImage {
  static Widget network(
    String url, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    int? cacheWidth,
    int? cacheHeight,
    ImageFrameBuilder? frameBuilder,
    ImageLoadingBuilder? loadingBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
    FilterQuality filterQuality = FilterQuality.medium,
    bool gaplessPlayback = false,
    Color? color,
    BlendMode? colorBlendMode,
    Animation<double>? opacity,
    String? semanticLabel,
    bool excludeFromSemantics = false,
  }) => Image(
    key: key,
    image: artworkProvider(
      url,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    ),
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    frameBuilder: frameBuilder,
    loadingBuilder: loadingBuilder,
    errorBuilder: errorBuilder,
    filterQuality: filterQuality,
    gaplessPlayback: gaplessPlayback,
    color: color,
    colorBlendMode: colorBlendMode,
    opacity: opacity,
    semanticLabel: semanticLabel,
    excludeFromSemantics: excludeFromSemantics,
  );
}

/// Downloads artwork for [ArtworkCache] with the limits the default
/// downloader lacks: only [ArtworkCache.isArtworkHost] addresses, redirects
/// included (at most 3); at most [maxBytes] per file; and a file extension
/// from a short image list. The default service names a file after the
/// response's Content-Type subtype, which may contain `../`, so a hostile
/// response could otherwise write outside the cache folder.
class ArtworkFileService extends FileService {
  ArtworkFileService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const maxBytes = 8 * 1024 * 1024;
  static const _maxRedirects = 3;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    var target = Uri.parse(url);
    for (var hop = 0; ; hop++) {
      if (!ArtworkCache.isArtworkHost(target)) {
        throw HttpExceptionWithStatus(
          400,
          'Artwork is only downloaded from TMDB.',
          uri: target,
        );
      }
      final request = http.Request('GET', target)..followRedirects = false;
      if (headers != null) request.headers.addAll(headers);
      final response = await _client.send(request);
      final location = response.headers['location'];
      if (response.isRedirect ||
          (response.statusCode >= 300 &&
              response.statusCode < 400 &&
              location != null)) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        if (location == null || hop >= _maxRedirects) {
          throw HttpExceptionWithStatus(
            response.statusCode,
            'Artwork redirected too often.',
            uri: target,
          );
        }
        target = target.resolve(location);
        continue;
      }
      return _BoundedArtworkResponse(HttpGetResponse(response));
    }
  }
}

class _BoundedArtworkResponse implements FileServiceResponse {
  _BoundedArtworkResponse(this._inner);

  final FileServiceResponse _inner;
  static const _extensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  @override
  Stream<List<int>> get content async* {
    final declared = _inner.contentLength;
    if (declared != null && declared > ArtworkFileService.maxBytes) {
      throw const HttpException('Artwork is too large.');
    }
    var received = 0;
    await for (final chunk in _inner.content) {
      received += chunk.length;
      if (received > ArtworkFileService.maxBytes) {
        throw const HttpException('Artwork is too large.');
      }
      yield chunk;
    }
  }

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;

  @override
  String? get eTag => _inner.eTag;

  /// Only a known image extension: never anything from the server that
  /// could hold a path.
  @override
  String get fileExtension {
    final extension = _inner.fileExtension.toLowerCase();
    return _extensions.contains(extension) ? extension : '.img';
  }
}
