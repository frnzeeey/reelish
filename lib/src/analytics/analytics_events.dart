// The complete list of analytics events Reelish sends, in one place. Each
// event answers one product question (docs/features/analytics.md has the
// catalog).
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

/// Where the source a player session started with came from.
enum SourceOrigin {
  /// The saved last link (Playback settings: reuse last link).
  cache,

  /// Chosen automatically from a provider lookup.
  auto,

  /// The viewer picked it from the source list.
  manual,
}

/// How a Play that never opened the player ended, for
/// [AnalyticsEvent.sourceLookup].
enum LookupOutcome {
  /// The lookup finished without a playable source.
  noSource,

  /// The viewer stopped the search before a source was chosen.
  cancelled,

  /// Sources were found and the viewer closed the list without picking.
  declined,
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
    String sourceType = '',
    SourceOrigin? origin,
    int? firstSourceMs,
    int? resolveMs,
    int? lookupStalled,
    int? prepareMs,
    int? openMs,
    int opens = 0,
    int recoveryMs = 0,
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
    if (sourceType.isNotEmpty) 'source_type': sourceType,
    // Where the start-up time went (PB-10). A stage that did not run is
    // left out, never sent as zero.
    if (origin != null) 'source_origin': origin.name,
    'first_source_ms': ?firstSourceMs,
    'resolve_ms': ?resolveMs,
    'lookup_stalled': ?lookupStalled,
    'prepare_ms': ?prepareMs,
    'open_ms': ?openMs,
    'opens': opens,
    'recovery_ms': recoveryMs,
  });

  /// A Play that never opened the player: no source was found, or the
  /// viewer stopped waiting. Sent once per Play; counts and times only,
  /// never which providers or what title.
  factory AnalyticsEvent.sourceLookup({
    required String contentType,
    required LookupOutcome outcome,
    required int lookupMs,
    required int runs,
    required int failed,
    required int stalled,
  }) => AnalyticsEvent._('source_lookup', {
    'content_type': _kind(contentType),
    'outcome': _snake(outcome.name),
    'lookup_ms': lookupMs,
    'lookup_runs': runs,
    'lookup_failed': failed,
    'lookup_stalled': stalled,
  });

  /// One party, sent when this device's part in it ends. How long parties
  /// last and whether connections hold; never the code or who was there.
  factory AnalyticsEvent.watchPartySession({
    required bool host,
    required String endReason,
    required int minutes,
    required int reconnects,
  }) => AnalyticsEvent._('watch_party_session', {
    'role': host ? 'host' : 'guest',
    'end_reason': _snake(endReason),
    'minutes': minutes,
    'reconnects': reconnects,
  });

  /// A party that could not be created or joined. [step] is `create` or
  /// `join`; [reason] is a fixed code, never the room's code.
  factory AnalyticsEvent.watchPartyFailed({
    required String step,
    required String reason,
  }) => AnalyticsEvent._('watch_party_failed', {
    'step': step,
    'reason': _snake(reason),
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
