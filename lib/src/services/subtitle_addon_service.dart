import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/stream_source.dart';
import '../models/subtitle_addon.dart';
import '../models/subtitle_language.dart';
import 'network_target_policy.dart';
import 'storage_service.dart';

/// What to search subtitles for. Stremio subtitle addons are addressed by
/// the IMDb-based video id Nuvio takes from Cinemeta.
class SubtitleRequest {
  const SubtitleRequest._(this.type, this.imdbId, this.season, this.episode);

  /// Null when there is no IMDb id, or a series lacks season and episode.
  static SubtitleRequest? create({
    required String type,
    required String imdbId,
    int? season,
    int? episode,
  }) {
    final id = imdbId.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(id)) return null;
    final series = type == 'series' || type == 'tv';
    if (series && (season == null || episode == null)) return null;
    return SubtitleRequest._(
      series ? 'series' : 'movie',
      id,
      series ? season : null,
      series ? episode : null,
    );
  }

  final String type;
  final String imdbId;
  final int? season;
  final int? episode;

  /// `tt0111161`, or `tt0944947:2:3` for an episode.
  String get videoId => season == null ? imdbId : '$imdbId:$season:$episode';
}

class SubtitleSearchException implements Exception {
  const SubtitleSearchException(this.message);

  /// Short text safe to show in the player.
  final String message;

  @override
  String toString() => message;
}

/// Installed Stremio subtitle addons and their searches, mirroring Nuvio's
/// AddonSubtitleLoader: every enabled, compatible addon is asked for
/// `subtitles/{type}/{id}.json` in parallel, and each addon's results are
/// reported as they arrive. OpenSubtitles v3 is preinstalled.
class SubtitleAddonService {
  SubtitleAddonService({
    StorageService? storage,
    http.Client? testClient,
    NetworkDestinationValidator? network,
    DateTime Function()? clock,
    Future<void> Function(Duration)? wait,
  }) : _storage = storage ?? StorageService(),
       _testClient = testClient,
       _network = network ?? NetworkDestinationValidator(),
       _clock = clock ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  static const _storageKey = 'onfeed.subtitleAddons.v1';

  /// Results are kept for the session; addons serve them with multi-hour
  /// cache lifetimes.
  static const cacheTtl = Duration(minutes: 30);

  final StorageService _storage;
  final http.Client? _testClient;
  final NetworkDestinationValidator _network;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _wait;

  static final Map<String, ({DateTime at, List<SubtitleTrack> results})>
  _cache = {};
  static final Map<String, Future<List<SubtitleTrack>>> _inFlight = {};

  @visibleForTesting
  static void resetCache() {
    _cache.clear();
    _inFlight.clear();
  }

  // ---------------------------------------------------------------------
  // Installed addons

  Future<List<SubtitleAddon>> addons() async {
    final raw = await _storage.readSetting(_storageKey);
    if (raw == null) return const [SubtitleAddon.openSubtitlesV3];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [for (final entry in decoded) ?SubtitleAddon.fromJson(entry)];
      }
    } on FormatException {
      // Fall back to the default list below.
    }
    return const [SubtitleAddon.openSubtitlesV3];
  }

  Future<void> _save(List<SubtitleAddon> addons) => _storage.saveSetting(
    _storageKey,
    jsonEncode([for (final addon in addons) addon.toJson()]),
  );

  /// Installs the addon at [rawUrl] (a manifest URL, or its base URL).
  /// Throws [FormatException] with a user-facing message.
  Future<SubtitleAddon> install(String rawUrl) async {
    var url = rawUrl.trim();
    if (url.startsWith('stremio://')) {
      url = 'https://${url.substring('stremio://'.length)}';
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      throw const FormatException('Use an HTTPS addon manifest link.');
    }
    if (!parsed.path.endsWith('/manifest.json')) {
      final path = parsed.path.endsWith('/')
          ? '${parsed.path}manifest.json'
          : '${parsed.path}/manifest.json';
      url = parsed.replace(path: path).toString();
    }
    final current = await addons();
    if (current.any((addon) => addon.manifestUrl == url)) {
      throw const FormatException('This addon is already installed.');
    }
    final http.Response response;
    try {
      response = await _get(Uri.parse(url));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Could not reach that addon.');
    }
    if (response.statusCode != 200) {
      throw FormatException(
        'The addon did not respond (HTTP ${response.statusCode}).',
      );
    }
    final Object? manifest;
    try {
      manifest = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const FormatException('That link is not an addon manifest.');
    }
    final addon = SubtitleAddon.fromManifest(url, manifest);
    if (current.any((existing) => existing.id == addon.id)) {
      throw FormatException('${addon.name} is already installed.');
    }
    await _save([...current, addon]);
    _log('[Subtitle][Addon] installed id=${addon.id}');
    return addon;
  }

  Future<void> remove(SubtitleAddon addon) async {
    final current = await addons();
    await _save([
      for (final existing in current)
        if (existing.manifestUrl != addon.manifestUrl) existing,
    ]);
  }

  Future<void> setEnabled(SubtitleAddon addon, bool enabled) async {
    final current = await addons();
    await _save([
      for (final existing in current)
        existing.manifestUrl == addon.manifestUrl
            ? existing.copyWith(enabled: enabled)
            : existing,
    ]);
  }

  // ---------------------------------------------------------------------
  // Searching

  /// Searches every enabled addon that supports [request], in parallel.
  /// [onAddon] receives each addon's results (or its error) as it finishes.
  /// Returns the addons that were searched; empty when none applies.
  Future<List<SubtitleAddon>> search(
    SubtitleRequest request, {
    required void Function(
      SubtitleAddon addon,
      List<SubtitleTrack> results,
      SubtitleSearchException? error,
    )
    onAddon,
  }) async {
    final compatible = [
      for (final addon in await addons())
        if (addon.enabled && addon.supports(request.type, request.videoId))
          addon,
    ];
    await Future.wait([
      for (final addon in compatible)
        searchAddon(addon, request).then(
          (results) => onAddon(addon, results, null),
          onError: (Object error) => onAddon(
            addon,
            const [],
            error is SubtitleSearchException
                ? error
                : const SubtitleSearchException('Unable to load subtitles.'),
          ),
        ),
    ]);
    return compatible;
  }

  /// One addon's subtitles. Cached for the session; concurrent identical
  /// searches share one request.
  Future<List<SubtitleTrack>> searchAddon(
    SubtitleAddon addon,
    SubtitleRequest request,
  ) {
    final key = '${addon.manifestUrl}|${request.type}/${request.videoId}';
    final cached = _cache[key];
    if (cached != null && _clock().difference(cached.at) < cacheTtl) {
      return Future.value(cached.results);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _search(addon, request).then((results) {
      _cache[key] = (at: _clock(), results: results);
      return results;
    });
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key)).ignore();
    return future;
  }

  Future<List<SubtitleTrack>> _search(
    SubtitleAddon addon,
    SubtitleRequest request,
  ) async {
    final clock = Stopwatch()..start();
    final uri = addon.resourceUri(request.type, request.videoId);
    for (var attempt = 0; ; attempt++) {
      final http.Response response;
      try {
        response = await _get(uri);
      } catch (error) {
        // Addon URLs can carry configuration tokens: log the id only.
        _log(
          '[Subtitle][Search] addon=${addon.id} network error '
          '${error.runtimeType}',
        );
        throw const SubtitleSearchException(
          'Unable to load subtitles. Check your connection.',
        );
      }
      final status = response.statusCode;
      if (status == 200) {
        final Object? body;
        try {
          body = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          throw const SubtitleSearchException('Unable to load subtitles.');
        }
        final results = parse(body, request, addonName: addon.name);
        _log(
          '[Subtitle][Search] addon=${addon.id} type=${request.type} '
          'id=${request.videoId} results=${results.length} '
          'duration=${clock.elapsedMilliseconds}ms',
        );
        return results;
      }
      if (status == 404) return const [];
      if (status == 429) {
        // One bounded retry, only when the server asks for a short wait.
        final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
        if (attempt == 0 && retryAfter != null && retryAfter <= 5) {
          _log('[Subtitle][Search] addon=${addon.id} rate limited; retry');
          await _wait(Duration(seconds: retryAfter));
          continue;
        }
        throw const SubtitleSearchException(
          'Subtitle search is busy. Try again in a moment.',
        );
      }
      _log('[Subtitle][Search] addon=${addon.id} HTTP $status');
      throw const SubtitleSearchException(
        'Subtitles are unavailable right now.',
      );
    }
  }

  Future<http.Response> _get(Uri uri) async {
    var current = uri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final response = await _network.sendForBytes(
        request,
        allowedSchemes: const {'https'},
        maxResponseBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 15),
        testClient: _testClient,
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      if (location == null) break;
      current = await _network.validateRedirect(
        current,
        location,
        allowedSchemes: const {'https'},
      );
    }
    throw const HttpException('Invalid subtitle redirect.');
  }

  static final _hearingImpaired = RegExp(
    r'(^|[\s._\-\[(])(hi|sdh|cc)([\s._\-\])]|$)|hearing[\s._-]?impaired',
    caseSensitive: false,
  );

  /// Parses an addon `subtitles` response (Nuvio's parseAddonSubtitles):
  /// `url` required (HTTPS only here), language from `lang`, `language`,
  /// `languageCode`, `locale` or `label`. Entries labeled with another
  /// season or episode, and duplicates, are dropped.
  static List<SubtitleTrack> parse(
    Object? body,
    SubtitleRequest request, {
    required String addonName,
  }) {
    final entries = body is Map ? body['subtitles'] : null;
    if (entries is! List) return const [];
    final seen = <String>{};
    final results = <SubtitleTrack>[];
    for (final (index, entry) in entries.indexed) {
      if (entry is! Map) continue;
      String text(String field) => '${entry[field] ?? ''}'.trim();
      final url = text('url');
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
      if (request.season != null) {
        final season = int.tryParse(text('season'));
        final episode = int.tryParse(text('episode'));
        if ((season != null && season > 0 && season != request.season) ||
            (episode != null && episode > 0 && episode != request.episode)) {
          continue;
        }
      }
      final rawLanguage = [
        'lang',
        'language',
        'languageCode',
        'locale',
        'label',
      ].map(text).firstWhere((value) => value.isNotEmpty, orElse: () => '');
      final fileName = text('subtitleFileName');
      final release = text('movieReleaseName');
      final track = SubtitleTrack(
        url: url,
        lang: SubtitleLanguage.normalize(rawLanguage),
        id: text('id').isEmpty ? 'addon-$index' : text('id'),
        format: fileName.contains('.')
            ? fileName.split('.').last.toLowerCase()
            : 'srt',
        source: SubtitleSource.addon,
        detail: fileName.isNotEmpty ? fileName : release,
        hearingImpaired: _hearingImpaired.hasMatch(fileName),
        addonName: addonName,
      );
      if (seen.add(track.key)) results.add(track);
    }
    return results;
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
