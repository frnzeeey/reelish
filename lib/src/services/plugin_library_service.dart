import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/plugin_catalog.dart';
import 'network_target_policy.dart';
import 'update_config.dart';

/// Where the community plugin catalog comes from.
abstract final class PluginLibraryConfig {
  /// `assets/data/plugins.json` on the app repository's main branch, so the
  /// catalog can be updated by committing a regenerated file
  /// (`dart run tool/generate_plugin_catalog.dart`) without an app release.
  static Uri get remoteCatalogUri => Uri.https(
    'raw.githubusercontent.com',
    '/${UpdateConfig.githubOwner}/${UpdateConfig.githubRepository}/main/assets/data/plugins.json',
  );

  static const bundledCatalogAsset = 'assets/data/plugins.json';

  /// The library checks for a newer catalog at most this often unless the
  /// user refreshes.
  static const refreshInterval = Duration(hours: 6);
  static const requestTimeout = Duration(seconds: 15);
  static const maxCatalogBytes = 4 * 1024 * 1024;
  static const cacheFileName = 'plugin_catalog_cache.json';
}

enum PluginCatalogOrigin { remote, cache, bundled }

class PluginCatalogSnapshot {
  const PluginCatalogSnapshot({
    required this.catalog,
    required this.origin,
    this.checkedAt,
  });

  final PluginCatalog catalog;
  final PluginCatalogOrigin origin;

  /// When the remote catalog was last downloaded successfully.
  final DateTime? checkedAt;
}

/// Reads the catalog from the network, the on-device cache and the app
/// bundle. It holds no UI state; [PluginLibraryRepository] decides which
/// copy to show.
class PluginLibraryService {
  PluginLibraryService({
    Future<String> Function()? fetchRemote,
    Future<Directory> Function()? cacheDirectory,
    Future<String> Function()? loadBundled,
  }) : _fetchRemoteOverride = fetchRemote,
       _cacheDirectory = cacheDirectory ?? getApplicationSupportDirectory,
       _loadBundled =
           loadBundled ??
           (() => rootBundle.loadString(
             PluginLibraryConfig.bundledCatalogAsset,
             // The asset can be refreshed by a hot restart during development.
             cache: false,
           ));

  final Future<String> Function()? _fetchRemoteOverride;
  final Future<Directory> Function() _cacheDirectory;
  final Future<String> Function() _loadBundled;
  final NetworkDestinationValidator _network = NetworkDestinationValidator();

  Future<PluginCatalogSnapshot?> loadBundled() async {
    try {
      return PluginCatalogSnapshot(
        catalog: PluginCatalog.fromJson(jsonDecode(await _loadBundled())),
        origin: PluginCatalogOrigin.bundled,
      );
    } catch (_) {
      return null;
    }
  }

  /// The last downloaded catalog, or null when there is none or it is
  /// unreadable.
  Future<PluginCatalogSnapshot?> loadCached() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return PluginCatalogSnapshot(
        catalog: PluginCatalog.fromJson(decoded['catalog']),
        origin: PluginCatalogOrigin.cache,
        checkedAt: DateTime.tryParse('${decoded['checkedAt']}')?.toUtc(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads and validates the remote catalog, then stores it in the cache.
  /// Throws when the download or the document is unusable.
  Future<PluginCatalogSnapshot> fetchRemote() async {
    final body = await (_fetchRemoteOverride ?? _download)();
    final decoded = jsonDecode(body);
    final catalog = PluginCatalog.fromJson(decoded);
    final checkedAt = DateTime.now().toUtc();
    try {
      await _writeCache(decoded, checkedAt);
    } catch (_) {
      // A read-only or full disk only costs offline support.
    }
    return PluginCatalogSnapshot(
      catalog: catalog,
      origin: PluginCatalogOrigin.remote,
      checkedAt: checkedAt,
    );
  }

  Future<String> _download() async {
    final request = http.Request('GET', PluginLibraryConfig.remoteCatalogUri)
      ..followRedirects = false
      ..headers['accept'] = 'application/json'
      ..headers['user-agent'] = UpdateConfig.userAgent;
    final response = await _network.sendForBytes(
      request,
      allowedSchemes: const {'https'},
      maxResponseBytes: PluginLibraryConfig.maxCatalogBytes,
      timeout: PluginLibraryConfig.requestTimeout,
    );
    if (response.statusCode != 200) {
      throw HttpException(
        'Plugin catalog request failed (${response.statusCode}).',
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<void> _writeCache(Object? catalog, DateTime checkedAt) async {
    final file = await _cacheFile();
    await file.parent.create(recursive: true);
    // Write then rename, so an interrupted write never leaves a corrupt
    // cache behind.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'checkedAt': checkedAt.toIso8601String(),
        'catalog': catalog,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<File> _cacheFile() async {
    final directory = await _cacheDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}${PluginLibraryConfig.cacheFileName}',
    );
  }
}
