import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the player in picture in picture is told by Android.
abstract interface class PlayerPipListener {
  /// The player's window became, or stopped being, picture in picture.
  void onPipChanged(bool inPip);

  /// The play/pause button of the picture-in-picture window.
  void onPipTogglePlay();
}

/// Picture in picture on Android, through the `onfeed/player` channel: the
/// active player reports its state, so leaving the app continues its video
/// in a small window with a play/pause button, and hears when that window
/// opens and closes. Does nothing on other platforms.
abstract final class PlayerPip {
  @visibleForTesting
  static const channel = MethodChannel('onfeed/player');

  static PlayerPipListener? _active;
  static bool _inPip = false;

  /// Whether the app is in picture in picture now. A player that opens
  /// there (the next episode, started by its countdown) starts compact, as
  /// Android does not announce the window again.
  static bool get inPip => _inPip;
  static ({bool autoEnter, bool playing, double ratio})? _reported;

  /// Makes [listener] the player Android talks to. Switching episodes
  /// briefly overlaps two players; the one attached last is the active one.
  static void attach(PlayerPipListener listener) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _active = listener;
    channel.setMethodCallHandler(_onCall);
  }

  /// Lets go of [listener] if it is still the active player, and stops
  /// leaving the app from opening picture in picture.
  static void detach(PlayerPipListener listener) {
    if (!identical(_active, listener)) return;
    _active = null;
    channel.setMethodCallHandler(null);
    report(autoEnter: false, playing: false, ratio: _reported?.ratio ?? 0);
  }

  /// The active player's state. Sent only when it changes.
  static void report({
    required bool autoEnter,
    required bool playing,
    required double ratio,
  }) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // Ratio changes below a percent are not worth a round trip.
    final rounded = (ratio * 100).roundToDouble() / 100;
    final state = (autoEnter: autoEnter, playing: playing, ratio: rounded);
    if (state == _reported) return;
    _reported = state;
    channel
        .invokeMethod<void>('setPipState', {
          'autoEnter': autoEnter,
          'playing': playing,
          'ratio': rounded,
        })
        .catchError((Object _) {});
  }

  static Future<void> _onCall(MethodCall call) async {
    if (call.method == 'pipChanged') _inPip = call.arguments == true;
    final listener = _active;
    if (listener == null) return;
    switch (call.method) {
      case 'pipChanged':
        listener.onPipChanged(_inPip);
      case 'pipTogglePlay':
        listener.onPipTogglePlay();
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _active = null;
    _reported = null;
    _inPip = false;
  }
}
