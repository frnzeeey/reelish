import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/tv_season.dart';
import '../services/perf_timeline.dart';
import '../services/tmdb_service.dart';

/// Which part of a series' episode list could not be loaded.
enum EpisodeLoadError {
  /// The list of seasons.
  seasons,

  /// The episodes of the selected season.
  season,
}

/// The state behind a title's details page, shared by the mobile, TV and
/// Windows details screens: TMDB details, the seasons and the selected
/// season's episodes, and (on Windows) related titles.
///
/// Each screen keeps its own layout, focus handling and wording, and renders
/// from this. A late answer for a season that is no longer selected, or for
/// a page that has closed, is dropped.
class DetailsViewModel extends ChangeNotifier {
  DetailsViewModel({
    required this.item,
    required this._tmdb,
    this.loadsRelated = false,
    this.keepsEpisodesOnError = false,
  });

  final MediaItem item;
  final TmdbService _tmdb;

  /// Also loads TMDB's recommendations for [related] (the Windows page).
  final bool loadsRelated;

  /// Keeps the previous season's episodes on screen when a season fails to
  /// load (the Windows page); the other pages clear them.
  final bool keepsEpisodesOnError;

  MediaDetails? _details;
  bool _loadingDetails = true;
  bool _detailsFailed = false;
  List<TvSeason> _seasons = const [];
  List<TvEpisode> _episodes = const [];
  int? _selectedSeason;
  bool _loadingEpisodes = false;
  EpisodeLoadError? _episodeError;
  List<MediaItem> _related = const [];
  bool _disposed = false;

  MediaDetails? get details => _details;
  bool get loadingDetails => _loadingDetails;
  bool get detailsFailed => _detailsFailed;
  List<TvSeason> get seasons => _seasons;
  List<TvEpisode> get episodes => _episodes;
  int? get selectedSeason => _selectedSeason;
  bool get loadingEpisodes => _loadingEpisodes;
  EpisodeLoadError? get episodeError => _episodeError;
  List<MediaItem> get related => _related;
  bool get isSeries => item.type == 'series';

  /// Loads everything the page shows. Call once, when the page opens.
  void start() {
    unawaited(loadDetails());
    if (loadsRelated) unawaited(_loadRelated());
    if (isSeries) unawaited(loadSeasons());
  }

  Future<void> loadDetails() async {
    _update(() {
      _loadingDetails = true;
      _detailsFailed = false;
    });
    try {
      final details = await _tmdb.details(item);
      if (_disposed) return;
      PerfTimeline.end('DETAIL_OPEN', 'DETAIL_READY', finish: true);
      _update(() {
        _details = details;
        _loadingDetails = false;
      });
    } catch (_) {
      _update(() {
        _loadingDetails = false;
        _detailsFailed = true;
      });
    }
  }

  Future<void> _loadRelated() async {
    try {
      final related = await _tmdb.recommendations(item);
      _update(() => _related = related);
    } catch (_) {
      // An extra row; the page works without it.
    }
  }

  /// The seasons, then the first season's episodes.
  Future<void> loadSeasons() async {
    _update(() {
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final seasons = (await _tmdb.seasons(
        item,
      )).map(TvSeason.fromJson).toList();
      if (_disposed) return;
      final first = seasons.isEmpty ? null : seasons.first.number;
      _update(() {
        _seasons = seasons;
        _selectedSeason = first;
      });
      if (first != null) {
        await selectSeason(first);
      } else {
        _update(() => _loadingEpisodes = false);
      }
    } catch (_) {
      _update(() {
        _loadingEpisodes = false;
        _episodeError = EpisodeLoadError.seasons;
      });
    }
  }

  /// Shows [season]'s episodes, in broadcast order.
  Future<void> selectSeason(int season) async {
    _update(() {
      _selectedSeason = season;
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final episodes = (await _tmdb.episodes(
        item,
        season,
      )).map(TvEpisode.fromJson).toList()..sort(TvEpisode.byNumber);
      if (_disposed || _selectedSeason != season) return;
      _update(() {
        _episodes = episodes;
        _loadingEpisodes = false;
      });
    } catch (_) {
      if (_disposed || _selectedSeason != season) return;
      _update(() {
        if (!keepsEpisodesOnError) _episodes = const [];
        _loadingEpisodes = false;
        _episodeError = EpisodeLoadError.season;
      });
    }
  }

  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
