// Watch party invitation links (reelish://party/12345678) handed over by the
// Android activity or the Windows runner on the "reelish/links" channel.
// A link only fills in a code: Home opens Join a party with it, which looks
// the room up and asks before joining, exactly as for a typed code.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'party_models.dart';

abstract final class PartyLinks {
  static const _channel = MethodChannel('reelish/links');

  /// The code of an invitation not yet opened; Home takes it.
  static final pending = ValueNotifier<String?>(null);

  static bool _started = false;

  /// Listens for invitations and reads the one Reelish was opened with.
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

  /// Keeps [link]'s code for Home when it is an invitation; anything else
  /// is ignored.
  @visibleForTesting
  static void receive(Object? link) {
    if (link is! String || link.length > 64) return;
    final uri = Uri.tryParse(link);
    final code = uri == null ? null : partyCodeFromLink(uri);
    if (code != null) pending.value = code;
  }

  /// The pending code, once; null when there is none.
  static String? take() {
    final code = pending.value;
    pending.value = null;
    return code;
  }
}
