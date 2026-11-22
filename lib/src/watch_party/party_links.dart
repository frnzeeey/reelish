// Links handed over by the Android activity or the Windows runner on the
// "reelish/links" channel: watch party invitations (reelish://party/12345678)
// and every other Reelish Connect link (src/connect/share_target.dart).
// A link only says what to open: a party code fills in Join a party, which
// looks the room up and asks before joining, exactly as for a typed code;
// the rest wait in [ConnectLinks] for Home.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../connect/share_target.dart';

abstract final class PartyLinks {
  static const _channel = MethodChannel('reelish/links');

  /// The longest link accepted, as on the native side.
  static const maxLength = 128;

  /// The code of an invitation not yet opened; Home takes it.
  static final pending = ValueNotifier<String?>(null);

  static bool _started = false;

  /// Listens for links and reads the one Reelish was opened with.
  /// Platforms without the channel (iOS, tests) simply never send one.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link') receive(call.arguments);
    });
    try {
      receive(await _channel.invokeMethod<String>('initialLink'));
    } on MissingPluginException {
      // No native side on this platform.
    } on PlatformException {
      // Nothing to hand over.
    }
  }

  /// Keeps [link]'s code for Home when it is a party invitation, and any
  /// other Reelish link for [ConnectLinks]; anything else is ignored.
  @visibleForTesting
  static void receive(Object? link) {
    if (link is! String || link.length > maxLength) return;
    final uri = Uri.tryParse(link);
    final target = uri == null ? null : ShareTarget.parse(uri);
    switch (target) {
      case PartyShare(:final code):
        pending.value = code;
      case final ShareTarget other:
        ConnectLinks.pending.value = other;
      case null:
        break;
    }
  }

  /// The pending code, once; null when there is none.
  static String? take() {
    final code = pending.value;
    pending.value = null;
    return code;
  }
}

/// Reelish Connect links other than party invitations, waiting for Home.
abstract final class ConnectLinks {
  static final pending = ValueNotifier<ShareTarget?>(null);

  /// The pending link, once; null when there is none.
  static ShareTarget? take() {
    final target = pending.value;
    pending.value = null;
    return target;
  }
}
