// Loads Reelish Wrapped: reads the account's whole synced progress record
// (GET /progress, the route the devices already sync with), looks up the
// finished titles' TMDB details through the app's own cached details
// request, computes the year (WrappedStats) and keeps the result on this
// device, per account and year, so a recap stays the same when the server's
// 400-day progress retention later drops the year's early rows.
//
// A year opens on 1 January of the next year. Nothing is uploaded: the
// summary lives in SharedPreferences, and the only requests are the
// existing sync and TMDB ones.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import 'wrapped_stats.dart';

class WrappedService {
  WrappedService({
    required this.account,
    required this.api,
    required this.details,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AccountController account;
  final AccountApi api;

  /// A title's TMDB details (`movie` or `series`, id); TmdbService.detailsJson.
  final Future<Map<String, dynamic>> Function(String type, int id) details;
  final DateTime Function() _clock;

  static const storageKey = 'reelish.wrapped.v1';

  /// Pages of 200 rows read at most: far more than a year of viewing.
  static const maxPages = 60;

  /// Titles looked up at most, and how many at once.
  static const maxTitles = 400;
  static const parallel = 4;

  /// The year whose recap is out: last year, from 1 January.
  int get latestYear => _clock().year - 1;

  /// Whether [year] may be shown: finished years only. Debug builds can
  /// preview the year so far, to test before January.
  bool isOpen(int year, {bool preview = false}) =>
      year <= latestYear || (preview && kDebugMode && year == _clock().year);

  /// The years with a recap kept on this device, and the latest year,
  /// newest first.
  Future<List<int>> years() async {
    final userId = account.userId;
    final Iterable<String> kept = userId == null
        ? const []
        : (await _all())[userId]?.keys ?? const [];
    return {latestYear, for (final y in kept) ?int.tryParse(y)}.toList()
      ..sort((a, b) => b.compareTo(a));
  }

  /// The recap kept for [year], without asking the server.
  Future<WrappedSummary?> saved(int year) async {
    final userId = account.userId;
    if (userId == null) return null;
    return WrappedSummary.fromJson((await _all())[userId]?['$year']);
  }

  /// [year]'s recap: the one kept, or computed now when there is none or
  /// [refresh]. [progress] hears 0–1 while it is computed. A refresh that
  /// finds less than the kept recap (rows the server has since dropped)
  /// keeps the kept one.
  Future<WrappedSummary> load(
    int year, {
    bool refresh = false,
    bool preview = false,
    void Function(double progress)? progress,
  }) async {
    final userId = account.userId;
    if (userId == null) throw StateError('Not signed in.');
    if (!isOpen(year, preview: preview)) {
      throw StateError('$year is not over yet.');
    }
    final kept = await saved(year);
    if (kept != null && !refresh) return kept;

    final rows = await _rows(progress);
    final info = await _titles(year, rows, progress);
    final summary = WrappedStats.compute(
      year: year,
      rows: rows,
      info: info,
      now: _clock(),
    );
    if (account.userId != userId) throw StateError('The account changed.');
    // A preview of a year in progress is never kept.
    if (year > latestYear) return summary;
    if (kept != null && kept.finished > summary.finished) return kept;
    await _save(userId, summary);
    return summary;
  }

  Future<List<WrappedRow>> _rows(void Function(double)? progress) async {
    final rows = <WrappedRow>[];
    var since = 0;
    for (var page = 0; page < maxPages; page++) {
      final token = await account.accessToken();
      if (token == null) throw const AccountApiException('missing_token', '');
      final result = await api.pullProgress(token, since);
      for (final item in result.items) {
        final row = WrappedRow.fromJson(item);
        if (row != null) rows.add(row);
      }
      progress?.call(.05 + .25 * (page + 1) / maxPages);
      if (!result.more || result.cursor <= since) break;
      since = result.cursor;
    }
    return rows;
  }

  /// The details of the titles finished in [year]: what genres, actors,
  /// seasons and missing names come from. A title that cannot be looked up
  /// still counts, without them.
  Future<Map<String, TitleInfo>> _titles(
    int year,
    List<WrappedRow> rows,
    void Function(double)? progress,
  ) async {
    final keys = <String>{};
    for (final r in rows) {
      if (!r.finished) continue;
      if (DateTime.fromMillisecondsSinceEpoch(r.at).year != year) continue;
      if (r.kind == 'movie') keys.add('movie:${r.tmdbId}');
      if (r.kind == 'episode') keys.add('series:${r.tmdbId}');
    }
    final wanted = keys.take(maxTitles).toList();
    final info = <String, TitleInfo>{};
    var done = 0;
    for (var i = 0; i < wanted.length; i += parallel) {
      await Future.wait(
        wanted.skip(i).take(parallel).map((key) async {
          final [type, id] = key.split(':');
          try {
            info[key] = TitleInfo.fromTmdb(await details(type, int.parse(id)));
          } catch (_) {
            // Counted without its details.
          }
          done++;
          progress?.call(.3 + .7 * done / wanted.length);
        }),
      );
    }
    return info;
  }

  Future<Map<String, Map<String, Object?>>> _all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(storageKey) ?? '{}');
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.value is Map)
            '${e.key}': Map<String, Object?>.from(e.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(String userId, WrappedSummary summary) async {
    final all = await _all();
    (all[userId] ??= {})['${summary.year}'] = summary.toJson();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(all));
    } catch (_) {
      // Only a convenience: it is computed again next time.
    }
  }
}
