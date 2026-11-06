// The complete list of analytics events Reelish sends, in one place. Each
// event answers one product question (docs/analytics.md has the catalog).
//
// Rules: no account ids, names, tokens, search text, stream addresses,
// provider or plugin names, or file paths. Titles are identified only by
// their public TMDB id and kind. Values are short and low-cardinality.

/// Features whose use is counted with [AnalyticsEvent.featureUsed].
enum AnalyticsFeature {
  myListAdd,
  myListRemove,
  watchPartyCreate,
  watchPartyJoin,
  pluginRepositoryInstall,
  accentChange,
  appIconChange,
  episodeAlertsOn,
  updateAccepted,
}

/// Why a search page settled, for [AnalyticsEvent.search].
enum SearchOutcome { results, noResults, failed }

/// How a player session ended, for [AnalyticsEvent.playbackSession].
enum PlaybackOutcome {
  /// A first frame was shown.
  played,

  /// No first frame, and at least one source failed.
  failed,

  /// Closed before a first frame, without a failure.
  abandoned,

  /// A first frame was shown, then playback failed for good.
  interrupted,
}

class AnalyticsEvent {
  AnalyticsEvent._(this.name, Map<String, Object> parameters)
    : parameters = _clean(parameters) {
    assert(_namePattern.hasMatch(name), 'Invalid analytics event name: $name');
  }

  /// Firebase's own `screen_view`: Reelish has one Android activity, so
  /// pages are reported by hand.
  factory AnalyticsEvent.screenView(String screen) => AnalyticsEvent._(
    'screen_view',
    {'screen_name': screen, 'screen_class': 'Flutter'},
  );

  /// Firebase's recommended `select_content`: a details page opened.
  /// Which titles people look at, and movies versus series.
  factory AnalyticsEvent.selectContent({
    required String contentType,
    required String itemId,
    String? from,
  }) => AnalyticsEvent._('select_content', {
    'content_type': _kind(contentType),
    'item_id': itemId,
    'origin': ?from,
  });

  /// A search settled. Whether search finds things; never the text typed.
  factory AnalyticsEvent.search(SearchOutcome outcome, {int results = 0}) =>
      AnalyticsEvent._('search_performed', {
        'outcome': _snake(outcome.name),
        'results': results > 20 ? 21 : results,
      });

  /// One player session, sent when the player closes. Startup time,
  /// failures, buffering and how much was watched, without a stream of
  /// position updates.
  factory AnalyticsEvent.playbackSession({
    required String contentType,
    required String itemId,
    required PlaybackOutcome outcome,
    String engine = '',
    int? firstFrameMs,
    int rebuffers = 0,
    int rebufferMs = 0,
    int stalls = 0,
    int? playToFrameMs,
    int? rebufferPercent,
    int recoveries = 0,
    int recovered = 0,
    String failure = '',
    int? watchedPercent,
    bool watchParty = false,
  }) => AnalyticsEvent._('playback_session', {
    'content_type': _kind(contentType),
    'item_id': itemId,
    'outcome': outcome.name,
    if (engine.isNotEmpty) 'engine': engine,
    'first_frame_ms': ?firstFrameMs,
    'rebuffers': rebuffers,
    'rebuffer_ms': rebufferMs,
    'stalls': stalls,
    'play_to_frame_ms': ?playToFrameMs,
    'rebuffer_pct': ?rebufferPercent,
    'recoveries': recoveries,
    'recovered': recovered,
    if (failure.isNotEmpty) 'failure': failure,
    'watched_pct': ?watchedPercent,
    'watch_party': watchParty ? 1 : 0,
  });

  /// Which features are used, and which are ignored.
  factory AnalyticsEvent.featureUsed(AnalyticsFeature feature) =>
      AnalyticsEvent._('feature_used', {'feature': _snake(feature.name)});

  /// The viewer turned sharing on; marks where their data starts.
  factory AnalyticsEvent.analyticsEnabled() =>
      AnalyticsEvent._('analytics_enabled', const {});

  final String name;
  final Map<String, Object> parameters;

  static final _namePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$');

  static String _kind(String type) => type == 'series' ? 'series' : 'movie';

  /// `watchPartyCreate` → `watch_party_create`.
  static String _snake(String value) => value.replaceAllMapped(
    RegExp('[A-Z]'),
    (match) => '_${match[0]!.toLowerCase()}',
  );

  /// Firebase limits: at most 25 parameters, names of 40 characters,
  /// string values of 100. Anything else is dropped or shortened here.
  static Map<String, Object> _clean(Map<String, Object> parameters) {
    final result = <String, Object>{};
    for (final MapEntry(:key, :value) in parameters.entries) {
      if (result.length == 25 || !_namePattern.hasMatch(key)) continue;
      result[key] = switch (value) {
        final String text => text.length > 100 ? text.substring(0, 100) : text,
        final bool flag => flag ? 1 : 0,
        final num number => number,
        _ => '$value',
      };
    }
    return result;
  }
}
