// Reelish Connect's unified share model: everything Reelish can share (an
// app invitation, a friend code, a movie or series, a watch party), the web
// link and app link each one travels as, and the parsing of links coming
// back in. The Worker's link resolver (backend/src/links.ts) serves the same
// paths. docs/features/reelish-connect.md.

import '../models/media_item.dart';

/// Codes Reelish issues (invite and friend codes): no 0/O or 1/I.
final _shareCode = RegExp(r'^[A-HJ-NP-Z2-9]{8}$');
final _tmdbId = RegExp(r'^[1-9]\d{0,9}$');
final _partyCode = RegExp(r'^\d{8}$');

/// Something shared as a link and a QR code. Nothing private travels in it:
/// a code is only a way in, checked by the server when it is used.
sealed class ShareTarget {
  const ShareTarget();

  /// The link's path on the Reelish API host, e.g. `/movie/550`.
  String get path;

  /// What opens it in the app, e.g. `reelish://movie/550`.
  Uri get appUri;

  /// The link and QR code for [this], on the API host [base]: `$base$path`.
  Uri webUri(Uri base) => base.replace(path: '${base.path}$path');

  /// The shared resource in an incoming link: a `reelish://` link, or a
  /// shared web link on any host (the host is not trusted for anything; the
  /// app only learns what to open). Null for anything else.
  static ShareTarget? parse(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final String kind;
    final List<String> rest;
    if (uri.scheme == 'reelish') {
      // reelish://movie/550: the kind is the host.
      kind = uri.host.toLowerCase();
      rest = segments;
      if (kind == 'open' && rest.isEmpty) return const AppInvite();
    } else if (uri.scheme == 'https') {
      // The party page shipped before Reelish Connect: …/api/v1/join/12345678.
      final join = segments.indexOf('join');
      if (join >= 0 && join == segments.length - 2) {
        return _party(segments.last);
      }
      // A QR code carries its link in capitals (see ReelishQrData).
      if (segments.length == 1 && segments.single.toLowerCase() == 'download') {
        return const AppInvite();
      }
      if (segments.length != 2) return null;
      kind = segments.first.toLowerCase();
      rest = segments.sublist(1);
    } else {
      return null;
    }
    if (rest.length != 1) return null;
    final value = rest.single;
    switch (kind) {
      case 'invite':
        final code = value.toUpperCase();
        return _shareCode.hasMatch(code) ? AppInvite(code) : null;
      case 'add':
        final code = value.toUpperCase();
        return _shareCode.hasMatch(code) ? FriendShare(code) : null;
      case 'movie' || 'tv':
        return _tmdbId.hasMatch(value)
            ? TitleShare(
                type: kind == 'tv' ? 'series' : 'movie',
                tmdbId: int.parse(value),
              )
            : null;
      case 'party':
        return _party(value);
      default:
        return null;
    }
  }

  static PartyShare? _party(String value) =>
      _partyCode.hasMatch(value) ? PartyShare(value) : null;
}

/// An invitation to Reelish, with the inviter's code when there is one.
final class AppInvite extends ShareTarget {
  const AppInvite([this.code]);

  final String? code;

  @override
  String get path => code == null ? '/download' : '/invite/$code';

  @override
  Uri get appUri =>
      Uri.parse(code == null ? 'reelish://open' : 'reelish://invite/$code');

  @override
  bool operator ==(Object other) => other is AppInvite && other.code == code;

  @override
  int get hashCode => Object.hash('invite', code);
}

/// A person's friend code: opens Add a friend with it filled in. The server
/// still checks that the code may be found (Friends & privacy) and that
/// neither side has blocked the other.
final class FriendShare extends ShareTarget {
  const FriendShare(this.code);

  final String code;

  @override
  String get path => '/add/$code';

  @override
  Uri get appUri => Uri.parse('reelish://add/$code');

  @override
  bool operator ==(Object other) => other is FriendShare && other.code == code;

  @override
  int get hashCode => Object.hash('add', code);
}

/// A movie or series by TMDB id: its details page. [type] is Reelish's
/// ('movie' or 'series'); the link says `movie` or `tv`, as TMDB does, so
/// a movie and a series with the same number never meet.
final class TitleShare extends ShareTarget {
  const TitleShare({required this.type, required this.tmdbId, this.name = ''});

  /// [item] as shared, or null when it has no TMDB id to share.
  static TitleShare? of(MediaItem item) {
    final id = int.tryParse(item.id);
    if (id == null || id <= 0) return null;
    if (item.type != 'movie' && item.type != 'series') return null;
    return TitleShare(type: item.type, tmdbId: id, name: item.name);
  }

  final String type;
  final int tmdbId;

  /// Shown beside the code; never part of the link.
  final String name;

  String get _kind => type == 'series' ? 'tv' : 'movie';

  @override
  String get path => '/$_kind/$tmdbId';

  @override
  Uri get appUri => Uri.parse('reelish://$_kind/$tmdbId');

  @override
  bool operator ==(Object other) =>
      other is TitleShare && other.type == type && other.tmdbId == tmdbId;

  @override
  int get hashCode => Object.hash(type, tmdbId);
}

/// A watch party's 8-digit code: opens Join a party with it, which looks the
/// room up and asks before joining, exactly as for a typed code.
final class PartyShare extends ShareTarget {
  const PartyShare(this.code);

  final String code;

  @override
  String get path => '/party/$code';

  @override
  Uri get appUri => Uri.parse('reelish://party/$code');

  @override
  bool operator ==(Object other) => other is PartyShare && other.code == code;

  @override
  int get hashCode => Object.hash('party', code);
}
