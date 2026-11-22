// Reelish Connect's sharing actions, the same for everything shared: the
// web link for a ShareTarget, its message, copying it, the system share
// sheet (Android phones and tablets), and sharing or saving its QR card
// (through the Wrapped export, which already handles both platforms).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../account/backend_config.dart';
import '../platform/device_capabilities.dart';
import '../watch_party/party_models.dart' show formatPartyCode;
import '../wrapped/wrapped_export.dart';
import 'reelish_qr.dart';
import 'share_target.dart';

abstract final class ShareService {
  static const _channel = MethodChannel('onfeed/share');

  /// The link for [target] on the share address (the website, which
  /// forwards it to the Reelish API), or null when the build has no Reelish
  /// API (nothing it shares could be opened then).
  static Uri? link(ShareTarget target, {Uri? base}) {
    final host =
        base ?? (BackendConfig.apiUrl == null ? null : BackendConfig.shareUrl);
    return host == null ? null : target.webUri(host);
  }

  /// What a share says around [link], in Reelish's voice.
  static String message(ShareTarget target, Uri link) => switch (target) {
    AppInvite() =>
      'Come watch with me on Reelish: discover movies and series, share '
          'them with friends and watch together in sync. Free, with no ads. '
          '$link',
    FriendShare(:final code) =>
      'Add me on Reelish: $link (friend code '
          '${code.substring(0, 4)}-${code.substring(4)})',
    TitleShare(:final name) =>
      name.isEmpty
          ? 'Have a look at this on Reelish: $link'
          : '$name: have a look on Reelish. $link',
    PartyShare(:final code) =>
      'Movie night? Join my watch party on Reelish with code '
          '${formatPartyCode(code)}: $link',
  };

  /// The card's title and line under it.
  static (String, String) cardText(ShareTarget target) => switch (target) {
    AppInvite() => (
      'Join me on Reelish',
      'Scan to get Reelish and watch together.',
    ),
    FriendShare(:final code) => (
      'Add me on Reelish',
      'Friend code ${code.substring(0, 4)}-${code.substring(4)}',
    ),
    TitleShare(:final name) => (
      name.isEmpty ? 'Watch this on Reelish' : name,
      'Scan to open it in Reelish.',
    ),
    PartyShare(:final code) => (
      'Join my watch party',
      'Code ${formatPartyCode(code)}',
    ),
  };

  /// A file name for [target]'s card: letters, digits and dashes only.
  static String fileName(ShareTarget target) => switch (target) {
    AppInvite() => 'reelish-invite',
    FriendShare() => 'reelish-friend-code',
    TitleShare(:final type, :final tmdbId) => 'reelish-$type-$tmdbId',
    PartyShare() => 'reelish-watch-party',
  };

  static Future<void> copy(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  /// The system share sheet: Android phones and tablets only. TVs have
  /// none, and Windows shares by copying the link or saving the card.
  static bool get canShare => WrappedExport.canShare;

  static Future<bool> shareText(String text) async {
    if (!canShare) return false;
    try {
      return await _channel.invokeMethod<bool>('shareText', {'text': text}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// [target]'s QR card as a PNG.
  static Future<Uint8List> card(ShareTarget target, Uri link) {
    final (title, subtitle) = cardText(target);
    return ReelishQrCard.render(
      link: link.toString(),
      title: title,
      subtitle: subtitle,
    );
  }

  static Future<bool> shareCard(ShareTarget target, Uri link) async {
    if (!canShare) return false;
    return WrappedExport.share(
      await card(target, link),
      fileName(target),
      text: message(target, link),
    );
  }

  /// Whether a card can be saved here: Windows, and Android 10 and later
  /// on phones and tablets.
  static Future<bool> canSave() => WrappedExport.canSave();

  /// Saves [target]'s card; where it went (a folder or file), or null.
  static Future<String?> saveCard(ShareTarget target, Uri link) async =>
      WrappedExport.save(await card(target, link), fileName(target));

  /// Whether this device shows codes to be scanned rather than sharing:
  /// a TV, which has no share sheet and is seen from across the room.
  static bool get showsOnly =>
      DeviceCapabilities.isTv ||
      (!kIsWeb && !Platform.isAndroid && !Platform.isWindows);
}
