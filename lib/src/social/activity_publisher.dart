// Watching now: tells friends what this account is playing, only while its
// owner shares activity and never during a Watch Party (the player creates no
// session then). Playback never waits for it: each call returns at once, the
// latest state is sent at most once a minute, and every failure is dropped,
// since the server's expiry ends a stale activity anyway. Stopping waits a
// moment before clearing, so the next episode opening does not flicker. A
// publish the app could not clear (it closed or crashed while playing) is
// noted on the device and cleared at the next launch.
// docs/friends-activity/TECHNICAL_ARCHITECTURE.md, Playback integration.
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../models/media_item.dart';
import 'recommendations_controller.dart';
import 'social_controller.dart';

/// One player's link to [ActivityPublisher]; null when nothing is shared.
class ActivitySession {
  ActivitySession._(this._publisher, this._state);

  final ActivityPublisher _publisher;
  final _ActivityState _state;
  bool _stopped = false;

  /// The stream is playing; [remaining] is how much of it is left, when
  /// known, so the server can end the activity on time.
  void playing({Duration? remaining}) {
    if (_stopped) return;
    _publisher._publish(
      _state.withRemaining(
        remaining == null || remaining.isNegative ? null : remaining,
      ),
    );
  }

  /// The player closed.
  void stopped() {
    if (_stopped) return;
    _stopped = true;
    _publisher._stop();
  }
}

class _ActivityState {
  const _ActivityState(this.card, this.season, this.episode, this.remaining);

  final Map<String, Object?> card;
  final int? season;
  final int? episode;
  final Duration? remaining;

  String get key => '${card['type']}:${card['id']}:$season:$episode';

  _ActivityState withRemaining(Duration? remaining) =>
      _ActivityState(card, season, episode, remaining);
}

class ActivityPublisher {
  ActivityPublisher({
    AccountController? account,
    AccountApi? api,
    SocialController? social,
    this.minInterval = const Duration(minutes: 1),
    this.clearDelay = const Duration(seconds: 20),
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _social = social ?? SocialController.instance;

  static final instance = ActivityPublisher();

  /// The account whose activity may still be published, saved on the
  /// device until it is cleared.
  static const leftoverKey = 'reelish.activity.published.v1';

  final AccountController _account;
  final AccountApi _api;
  final SocialController _social;

  /// Fewest time between two updates sent.
  final Duration minInterval;

  /// How long a stop waits before clearing, for the next episode to start.
  final Duration clearDelay;

  _ActivityState? _pending;
  String? _sentKey;
  bool _cooling = false;
  bool _published = false;
  Timer? _cooldown;
  Timer? _clearTimer;
  Future<void>? _sending;
  String? _checkedFor;

  /// At launch: follows the signed-in account, and for each account clears
  /// once what an earlier run published and never cleared.
  void attach() {
    _account.addListener(_checkLeftover);
    _checkLeftover();
  }

  void _checkLeftover() {
    final userId = _account.userId;
    if (userId == null || userId == _checkedFor) return;
    _checkedFor = userId;
    unawaited(_clearLeftover(userId));
  }

  Future<void> _clearLeftover(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getString(leftoverKey) != userId) return;
      // Something playing in this run has published since: it clears itself.
      if (_published) return;
      final token = await _account.accessToken();
      if (token == null) return;
      await _api.clearActivity(token);
      await preferences.remove(leftoverKey);
    } catch (_) {
      // Tried again at the next launch; it expires on its own meanwhile.
    }
  }

  Future<void> _remember(String? userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (userId == null) {
        await preferences.remove(leftoverKey);
      } else {
        await preferences.setString(leftoverKey, userId);
      }
    } catch (_) {
      // Only a convenience.
    }
  }

  /// Whether this account shares what it watches (as last known here).
  bool get sharing => _social.profile?.shareActivity == true;

  /// A session for a player opening [item], or null when nothing would be
  /// shared (sharing off, signed out, or not a TMDB title).
  ActivitySession? sessionFor(MediaItem item, {int? season, int? episode}) {
    if (!sharing || _account.userId == null) return null;
    final card = cardOf(item);
    if (card == null) return null;
    card.remove('year');
    return ActivitySession._(
      this,
      _ActivityState(
        card,
        item.type == 'series' ? season : null,
        item.type == 'series' ? episode : null,
        null,
      ),
    );
  }

  void _publish(_ActivityState state) {
    _clearTimer?.cancel();
    _clearTimer = null;
    if (state.key == _sentKey && _published) return;
    _pending = state;
    if (!_cooling) _sendPending();
  }

  void _sendPending() {
    final state = _pending;
    if (state == null) return;
    _pending = null;
    _cooling = true;
    _cooldown = Timer(minInterval, () {
      _cooling = false;
      _sendPending();
    });
    _sending = _send(state);
  }

  Future<void> _send(_ActivityState state) async {
    try {
      final token = await _account.accessToken();
      if (token == null) return;
      // A request that times out may still have arrived, so a stop clears
      // after any attempt, and a launch after a crash clears too.
      _published = true;
      await _remember(_account.userId);
      await _api.publishActivity(
        token,
        media: state.card,
        season: state.season,
        episode: state.episode,
        remainingMs: state.remaining?.inMilliseconds,
      );
      _sentKey = state.key;
    } catch (_) {
      // Best effort: the server's expiry ends what was not updated.
    }
  }

  void _stop() {
    _pending = null;
    _clearTimer?.cancel();
    _clearTimer = Timer(clearDelay, () => unawaited(_clear()));
  }

  Future<void> _clear() async {
    _clearTimer = null;
    await _sending;
    if (!_published) return;
    _published = false;
    _sentKey = null;
    try {
      final token = await _account.accessToken();
      if (token != null) {
        await _api.clearActivity(token);
        await _remember(null);
      }
    } catch (_) {
      // It expires on its own, or the next launch clears it.
    }
  }

  /// Stops every timer (tests).
  void dispose() {
    _account.removeListener(_checkLeftover);
    _cooldown?.cancel();
    _clearTimer?.cancel();
  }
}
