// How the waiting room opens the player. Home registers the same flow its
// Play buttons use, so each participant finds a source with their own
// plugins and the title plays exactly as it would alone.

import 'package:flutter/widgets.dart';

import '../../watch_party/party_models.dart';

abstract final class PartyPlayerLauncher {
  /// Opens the player for [content]; completes when the player closes (or
  /// when no source was found). Null until Home is up.
  static Future<void> Function(BuildContext context, PartyContent content)?
  open;
}
