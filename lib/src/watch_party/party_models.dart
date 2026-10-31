// What a watch party room shares, as the Reelish API sends it: the title,
// the room's settings, the playback timeline and who is in the room. Every
// parser tolerates missing or malformed fields, since the data is remote.

import '../models/media_item.dart';

int _int(Object? value, [int fallback = 0]) =>
    value is int ? value : (value is num ? value.round() : fallback);

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

/// The movie or episode a room plays, identified by TMDB id.
class PartyContent {
  const PartyContent({
    required this.tmdbId,
    required this.type,
    required this.title,
    this.season,
    this.episode,
    this.posterPath,
  });

  /// From a catalog title; [season] and [episode] for a series. Null when
  /// the title has no TMDB id (such as an entry from a provider only).
  static PartyContent? fromItem(MediaItem item, {int? season, int? episode}) {
    final id = int.tryParse(item.id);
    if (id == null || id <= 0) return null;
    if (item.type != 'movie' && item.type != 'series') return null;
    if (item.type == 'series' && (season == null || episode == null)) {
      return null;
    }
    // Only the file name travels; the room rebuilds the TMDB image URL.
    final poster = Uri.tryParse(item.poster)?.pathSegments;
    final file = poster == null || poster.isEmpty ? '' : poster.last;
    return PartyContent(
      tmdbId: id,
      type: item.type,
      title: item.name,
      season: item.type == 'series' ? season : null,
      episode: item.type == 'series' ? episode : null,
      posterPath: RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(file)
          ? '/$file'
          : null,
    );
  }

  static PartyContent? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['tmdbId']);
    final type = json['type'];
    if (id <= 0 || (type != 'movie' && type != 'series')) return null;
    final poster = json['posterPath'];
    return PartyContent(
      tmdbId: id,
      type: type as String,
      title: _string(json['title'], 'Untitled'),
      season: json['season'] is int ? json['season'] as int : null,
      episode: json['episode'] is int ? json['episode'] as int : null,
      posterPath:
          poster is String &&
              RegExp(r'^/[A-Za-z0-9._-]{1,100}$').hasMatch(poster)
          ? poster
          : null,
    );
  }

  final int tmdbId;
  final String type;
  final String title;
  final int? season;
  final int? episode;
  final String? posterPath;

  bool get isSeries => type == 'series';

  /// "S1 · E2" for an episode; empty for a movie.
  String get episodeLabel => isSeries && season != null && episode != null
      ? 'S$season · E$episode'
      : '';

  String get posterUrl =>
      posterPath == null ? '' : 'https://image.tmdb.org/t/p/w500$posterPath';

  /// The catalog title to search sources for, with what the room knows.
  MediaItem toItem() =>
      MediaItem(id: '$tmdbId', type: type, name: title, poster: posterUrl);

  Map<String, Object> toJson() => {
    'tmdbId': tmdbId,
    'type': type,
    'title': title,
    'season': ?season,
    'episode': ?episode,
    'posterPath': ?posterPath,
  };

  bool sameTitleAs(PartyContent other) =>
      tmdbId == other.tmdbId &&
      type == other.type &&
      season == other.season &&
      episode == other.episode;
}

class PartySettings {
  const PartySettings({
    this.capacity = 5,
    this.guestControl = false,
    this.waitForAll = true,
  });

  factory PartySettings.fromJson(Object? json) {
    if (json is! Map) return const PartySettings();
    return PartySettings(
      capacity: _int(json['capacity'], 5),
      guestControl: json['guestControl'] == true,
      waitForAll: json['waitForAll'] != false,
    );
  }

  final int capacity;

  /// Whether participants other than the host may play, pause and seek.
  final bool guestControl;

  /// Whether the host's player waits for everyone to be ready to start.
  final bool waitForAll;

  Map<String, Object> toJson() => {
    'capacity': capacity,
    'guestControl': guestControl,
    'waitForAll': waitForAll,
  };
}

enum PlaybackStatus { idle, playing, paused, ended }

/// The room's timeline: [positionMs] was true at server time [at].
class PartyPlayback {
  const PartyPlayback({
    required this.status,
    required this.positionMs,
    required this.at,
    required this.seq,
    this.rate = 1,
    this.by,
  });

  factory PartyPlayback.fromJson(Object? json) {
    if (json is! Map) return initial;
    return PartyPlayback(
      status: PlaybackStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => PlaybackStatus.idle,
      ),
      positionMs: _int(json['positionMs']).clamp(0, 24 * 60 * 60 * 1000),
      rate: json['rate'] is num ? (json['rate'] as num).toDouble() : 1,
      at: _int(json['at']),
      seq: _int(json['seq']),
      by: json['by'] is String ? json['by'] as String : null,
    );
  }

  static const initial = PartyPlayback(
    status: PlaybackStatus.idle,
    positionMs: 0,
    at: 0,
    seq: 0,
  );

  final PlaybackStatus status;
  final int positionMs;
  final double rate;
  final int at;
  final int seq;

  /// The participant id that made this change.
  final String? by;

  bool get playing => status == PlaybackStatus.playing;
}

/// What a participant's player is doing, as shown to the room.
enum ParticipantStatus {
  joined,
  loading,
  ready,
  playing,
  paused,
  buffering,
  unavailable,
  error,
}

class PartyParticipant {
  const PartyParticipant({
    required this.pid,
    required this.name,
    required this.host,
    required this.status,
    this.avatar,
  });

  static PartyParticipant? fromJson(Object? json) {
    if (json is! Map || json['pid'] is! String) return null;
    return PartyParticipant(
      pid: json['pid'] as String,
      name: _string(json['name'], 'Viewer'),
      avatar: json['avatar'] is String ? json['avatar'] as String : null,
      host: json['host'] == true,
      status: ParticipantStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => ParticipantStatus.joined,
      ),
    );
  }

  /// A per-room id; never the account.
  final String pid;
  final String name;

  /// A preset avatar id, or null for the name's initial.
  final String? avatar;
  final bool host;
  final ParticipantStatus status;
}

List<PartyParticipant> participantsFrom(Object? json) => [
  for (final entry in json is List ? json : const [])
    ?PartyParticipant.fromJson(entry),
];

enum PartyPhase { lobby, watching }

/// The room as the server last described it.
class PartyRoom {
  const PartyRoom({
    required this.code,
    required this.phase,
    required this.content,
    required this.settings,
    required this.hostPid,
    required this.hostName,
    required this.hostConnected,
    required this.playback,
    required this.participants,
    this.hostAvatar,
  });

  static PartyRoom? fromJson(Object? json) {
    if (json is! Map) return null;
    final content = PartyContent.fromJson(json['content']);
    final code = json['code'];
    if (content == null || code is! String) return null;
    final host = json['host'] is Map ? json['host'] as Map : const {};
    return PartyRoom(
      code: code,
      phase: json['phase'] == 'watching'
          ? PartyPhase.watching
          : PartyPhase.lobby,
      content: content,
      settings: PartySettings.fromJson(json['settings']),
      hostPid: _string(host['pid']),
      hostName: _string(host['name'], 'Host'),
      hostAvatar: host['avatar'] is String ? host['avatar'] as String : null,
      hostConnected: json['hostConnected'] != false,
      playback: PartyPlayback.fromJson(json['playback']),
      participants: participantsFrom(json['participants']),
    );
  }

  final String code;
  final PartyPhase phase;
  final PartyContent content;
  final PartySettings settings;
  final String hostPid;
  final String hostName;
  final String? hostAvatar;
  final bool hostConnected;
  final PartyPlayback playback;
  final List<PartyParticipant> participants;

  PartyRoom copyWith({
    PartyPlayback? playback,
    List<PartyParticipant>? participants,
    bool? hostConnected,
  }) => PartyRoom(
    code: code,
    phase: phase,
    content: content,
    settings: settings,
    hostPid: hostPid,
    hostName: hostName,
    hostAvatar: hostAvatar,
    hostConnected: hostConnected ?? this.hostConnected,
    playback: playback ?? this.playback,
    participants: participants ?? this.participants,
  );
}

/// What a code opens, before joining.
class PartyPreview {
  const PartyPreview({
    required this.code,
    required this.phase,
    required this.content,
    required this.hostName,
    required this.participants,
    required this.capacity,
    this.hostAvatar,
  });

  static PartyPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final content = PartyContent.fromJson(json['content']);
    final code = json['code'];
    if (content == null || code is! String) return null;
    final host = json['host'] is Map ? json['host'] as Map : const {};
    return PartyPreview(
      code: code,
      phase: json['phase'] == 'watching'
          ? PartyPhase.watching
          : PartyPhase.lobby,
      content: content,
      hostName: _string(host['name'], 'Host'),
      hostAvatar: host['avatar'] is String ? host['avatar'] as String : null,
      participants: _int(json['participants']),
      capacity: _int(json['capacity'], 5),
    );
  }

  final String code;
  final PartyPhase phase;
  final PartyContent content;
  final String hostName;
  final String? hostAvatar;
  final int participants;
  final int capacity;

  bool get full => participants >= capacity;
}

/// The room's 8-digit code, from typed or pasted text; null until complete.
String? partyCodeFrom(String text) {
  final digits = text.replaceAll(RegExp(r'\D'), '');
  return digits.length == 8 ? digits : null;
}

/// "1234 5678": easier to read out and type.
String formatPartyCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;
