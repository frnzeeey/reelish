// Live compatibility sweep of the community plugin catalog. Skipped unless
// REELISH_PROVIDER_COMPAT=1, because it downloads third-party scripts and
// lets them reach the internet (through the normal sandbox: QuickJS limits,
// the fetch bridge and NetworkDestinationValidator).
//
//   $env:REELISH_PROVIDER_COMPAT = '1'
//   $env:REELISH_PROVIDER_COMPAT_OUT = 'C:\path\report.json'   # optional
//   flutter test test/provider_compat/provider_compat_test.dart
//
// Every available repository is installed into an in-memory profile (the
// app's real settings are never read or written), every scraper is
// switched on, and each one runs alone for a movie and, where supported, an
// episode. The report holds counts and redacted messages only: no stream
// URLs or headers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/services/provider_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _movie = MediaItem(
  id: '550',
  type: 'movie',
  name: 'Fight Club',
  year: '1999',
);
const _series = MediaItem(
  id: '1399',
  type: 'series',
  name: 'Game of Thrones',
  year: '2011',
);

void main() {
  final enabled = Platform.environment['REELISH_PROVIDER_COMPAT'] == '1';

  test(
    'every catalog scraper, switched on, runs in the sandbox',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // The test binding answers HTTP with 400s; this sweep needs the real
      // network (still filtered by the app's own destination policy).
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});

      final catalog =
          jsonDecode(await rootBundle.loadString('assets/data/plugins.json'))
              as Map<String, dynamic>;
      final service = ProviderPluginService();
      await service.load();

      final repos = <Map<String, Object?>>[];
      for (final entry in (catalog['providers'] as List).cast<Map>()) {
        if (entry['available'] != true) continue;
        final url = '${entry['manifestUrl']}';
        try {
          final repo = await service.install(url);
          repos.add({
            'id': entry['id'],
            'installed': true,
            'scrapers': repo.plugins.length,
          });
        } catch (error) {
          repos.add({
            'id': entry['id'],
            'installed': false,
            'error': ProviderRunner.safeProviderDiagnostic(error),
          });
        }
      }

      // "Turn on all providers": every scraper, including ones a manifest
      // ships switched off.
      for (final repo in List.of(service.repositories)) {
        for (final plugin in repo.plugins) {
          if (!plugin.enabled) {
            await service.setPluginEnabled(repo, plugin, true);
          }
        }
      }

      final jobs = <(String, String, String, String, MediaItem)>[];
      for (final repo in service.repositories) {
        for (final plugin in repo.plugins) {
          final key = '${repo.url}|${plugin.id}';
          if (plugin.supportedTypes.contains('movie')) {
            jobs.add((repo.name, plugin.id, plugin.name, key, _movie));
          }
          if (plugin.supportedTypes.contains('tv')) {
            jobs.add((repo.name, plugin.id, plugin.name, key, _series));
          }
        }
      }

      final results = <Map<String, Object?>>[];
      var next = 0;
      Future<void> worker() async {
        while (next < jobs.length) {
          final (repoName, id, name, key, item) = jobs[next++];
          final watch = Stopwatch()..start();
          var candidates = 0;
          String? message;
          try {
            final sources = await service.streams(
              item,
              season: item.type == 'series' ? 1 : null,
              episode: item.type == 'series' ? 1 : null,
              allowedPluginIds: {key},
              onCandidate: () => candidates++,
              onMessage: (value) => message = value,
            );
            final torrents = sources.where((s) => s.isTorrent).length;
            results.add({
              'repo': repoName,
              'id': id,
              'name': name,
              'type': item.type,
              'ms': watch.elapsedMilliseconds,
              'candidates': candidates,
              'playable': sources.length - torrents,
              'torrents': torrents,
              if (message != null)
                'message': ProviderRunner.safeProviderDiagnostic(message),
            });
          } catch (error) {
            results.add({
              'repo': repoName,
              'id': id,
              'name': name,
              'type': item.type,
              'ms': watch.elapsedMilliseconds,
              'thrown': ProviderRunner.safeProviderDiagnostic(error),
            });
          }
          // ignore: avoid_print
          print('[compat] ${results.length}/${jobs.length} $repoName/$id');
        }
      }

      // The service's scheduler still bounds live QuickJS runtimes.
      await Future.wait(List.generate(4, (_) => worker()));

      final report = const JsonEncoder.withIndent('  ').convert({
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.operatingSystem,
        'repositories': repos,
        'pendingReview': service.pendingScriptUpdates.length,
        'results': results,
      });
      final out = Platform.environment['REELISH_PROVIDER_COMPAT_OUT'];
      if (out != null && out.isNotEmpty) File(out).writeAsStringSync(report);
      expect(results, hasLength(jobs.length));
    },
    skip: enabled ? false : 'Set REELISH_PROVIDER_COMPAT=1 to run the sweep.',
    timeout: const Timeout(Duration(hours: 3)),
  );
}
