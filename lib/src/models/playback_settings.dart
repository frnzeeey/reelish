import 'dart:math' as math;

import 'package:flutter/painting.dart';

class PlaybackSettings {
  const PlaybackSettings({
    this.touchGestures = true,
    this.holdToSpeed = true,
    this.holdSpeed = 2,
    this.defaultPlaybackSpeed = 1,
    this.preferredVideoHeight = 0,
    this.showLoadingOverlay = true,
    this.showLoadingStatus = true,
    this.pauseOverlay = true,
    this.autoPlayNextEpisode = false,
    this.nextEpisodeThresholdPercent = 99,
    this.autoStreamSelection = true,
    this.streamSelectionTimeoutSeconds = 3,
    this.allowedProviderIds,
    this.p2pStreaming = true,
    this.reuseLastLink = false,
    this.lastLinkCacheHours = 24,
    this.preferredAudioLanguage = 'device',
    this.secondaryAudioLanguage = '',
    this.preferredSubtitleLanguage = '',
    this.secondarySubtitleLanguage = '',
    this.stripSdhSubtitles = false,
    this.useForcedSubtitles = false,
    this.showOnlyPreferredLanguages = false,
    this.subtitleSize = 18,
    this.subtitlePosition = 0,
    this.subtitleBold = false,
    this.subtitleTextColor = 0xFFFFFFFF,
    this.subtitleBackgroundColor = 0x00000000,
    this.subtitleOutline = true,
    this.subtitleOutlineColor = 0xFF000000,
  });

  final bool touchGestures;
  final bool holdToSpeed;
  final double holdSpeed;

  /// Default speed for newly opened player sessions. 0 video height means Auto.
  final double defaultPlaybackSpeed;
  final int preferredVideoHeight;
  final bool showLoadingOverlay;
  final bool showLoadingStatus;
  final bool pauseOverlay;
  final bool autoPlayNextEpisode;
  final int nextEpisodeThresholdPercent;
  final bool autoStreamSelection;
  final int streamSelectionTimeoutSeconds;

  /// Null means all enabled providers; an empty set means none.
  final Set<String>? allowedProviderIds;
  final bool p2pStreaming;
  final bool reuseLastLink;
  final int lastLinkCacheHours;
  final String preferredAudioLanguage;
  final String secondaryAudioLanguage;
  final String preferredSubtitleLanguage;
  final String secondarySubtitleLanguage;
  final bool stripSdhSubtitles;
  final bool useForcedSubtitles;
  final bool showOnlyPreferredLanguages;
  final double subtitleSize;

  /// How far subtitles sit above their default place, as a fraction of the
  /// player height (0 is the default, negative is lower). Relative, so one
  /// preference looks the same on phones, tablets and in either orientation.
  final double subtitlePosition;
  static const subtitlePositionMin = -.1;
  static const subtitlePositionMax = .4;

  final bool subtitleBold;
  final int subtitleTextColor;
  final int subtitleBackgroundColor;
  final bool subtitleOutline;
  final int subtitleOutlineColor;

  PlaybackSettings copyWith({
    bool? touchGestures,
    bool? holdToSpeed,
    double? holdSpeed,
    double? defaultPlaybackSpeed,
    int? preferredVideoHeight,
    bool? showLoadingOverlay,
    bool? showLoadingStatus,
    bool? pauseOverlay,
    bool? autoPlayNextEpisode,
    int? nextEpisodeThresholdPercent,
    bool? autoStreamSelection,
    int? streamSelectionTimeoutSeconds,
    Set<String>? allowedProviderIds,
    bool clearAllowedProviderIds = false,
    bool? p2pStreaming,
    bool? reuseLastLink,
    int? lastLinkCacheHours,
    String? preferredAudioLanguage,
    String? secondaryAudioLanguage,
    String? preferredSubtitleLanguage,
    String? secondarySubtitleLanguage,
    bool? stripSdhSubtitles,
    bool? useForcedSubtitles,
    bool? showOnlyPreferredLanguages,
    double? subtitleSize,
    double? subtitlePosition,
    bool? subtitleBold,
    int? subtitleTextColor,
    int? subtitleBackgroundColor,
    bool? subtitleOutline,
    int? subtitleOutlineColor,
  }) => PlaybackSettings(
    touchGestures: touchGestures ?? this.touchGestures,
    holdToSpeed: holdToSpeed ?? this.holdToSpeed,
    holdSpeed: holdSpeed ?? this.holdSpeed,
    defaultPlaybackSpeed: defaultPlaybackSpeed ?? this.defaultPlaybackSpeed,
    preferredVideoHeight: preferredVideoHeight ?? this.preferredVideoHeight,
    showLoadingOverlay: showLoadingOverlay ?? this.showLoadingOverlay,
    showLoadingStatus: showLoadingStatus ?? this.showLoadingStatus,
    pauseOverlay: pauseOverlay ?? this.pauseOverlay,
    autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
    nextEpisodeThresholdPercent:
        nextEpisodeThresholdPercent ?? this.nextEpisodeThresholdPercent,
    autoStreamSelection: autoStreamSelection ?? this.autoStreamSelection,
    streamSelectionTimeoutSeconds:
        streamSelectionTimeoutSeconds ?? this.streamSelectionTimeoutSeconds,
    allowedProviderIds: clearAllowedProviderIds
        ? null
        : (allowedProviderIds ?? this.allowedProviderIds),
    p2pStreaming: p2pStreaming ?? this.p2pStreaming,
    reuseLastLink: reuseLastLink ?? this.reuseLastLink,
    lastLinkCacheHours: lastLinkCacheHours ?? this.lastLinkCacheHours,
    preferredAudioLanguage:
        preferredAudioLanguage ?? this.preferredAudioLanguage,
    secondaryAudioLanguage:
        secondaryAudioLanguage ?? this.secondaryAudioLanguage,
    preferredSubtitleLanguage:
        preferredSubtitleLanguage ?? this.preferredSubtitleLanguage,
    secondarySubtitleLanguage:
        secondarySubtitleLanguage ?? this.secondarySubtitleLanguage,
    stripSdhSubtitles: stripSdhSubtitles ?? this.stripSdhSubtitles,
    useForcedSubtitles: useForcedSubtitles ?? this.useForcedSubtitles,
    showOnlyPreferredLanguages:
        showOnlyPreferredLanguages ?? this.showOnlyPreferredLanguages,
    subtitleSize: subtitleSize ?? this.subtitleSize,
    subtitlePosition: subtitlePosition ?? this.subtitlePosition,
    subtitleBold: subtitleBold ?? this.subtitleBold,
    subtitleTextColor: subtitleTextColor ?? this.subtitleTextColor,
    subtitleBackgroundColor:
        subtitleBackgroundColor ?? this.subtitleBackgroundColor,
    subtitleOutline: subtitleOutline ?? this.subtitleOutline,
    subtitleOutlineColor: subtitleOutlineColor ?? this.subtitleOutlineColor,
  );

  Map<String, dynamic> toJson() => {
    'touchGestures': touchGestures,
    'holdToSpeed': holdToSpeed,
    'holdSpeed': holdSpeed,
    'defaultPlaybackSpeed': defaultPlaybackSpeed,
    'preferredVideoHeight': preferredVideoHeight,
    'showLoadingOverlay': showLoadingOverlay,
    'showLoadingStatus': showLoadingStatus,
    'pauseOverlay': pauseOverlay,
    'autoPlayNextEpisode': autoPlayNextEpisode,
    'nextEpisodeThresholdPercent': nextEpisodeThresholdPercent,
    'autoStreamSelection': autoStreamSelection,
    'streamSelectionTimeoutSeconds': streamSelectionTimeoutSeconds,
    'allowedProviderIds': allowedProviderIds?.toList(),
    'p2pStreaming': p2pStreaming,
    'reuseLastLink': reuseLastLink,
    'lastLinkCacheHours': lastLinkCacheHours,
    'preferredAudioLanguage': preferredAudioLanguage,
    'secondaryAudioLanguage': secondaryAudioLanguage,
    'preferredSubtitleLanguage': preferredSubtitleLanguage,
    'secondarySubtitleLanguage': secondarySubtitleLanguage,
    'stripSdhSubtitles': stripSdhSubtitles,
    'useForcedSubtitles': useForcedSubtitles,
    'showOnlyPreferredLanguages': showOnlyPreferredLanguages,
    'subtitleSize': subtitleSize,
    'subtitlePosition': subtitlePosition,
    'subtitleBold': subtitleBold,
    'subtitleTextColor': subtitleTextColor,
    'subtitleBackgroundColor': subtitleBackgroundColor,
    'subtitleOutline': subtitleOutline,
    'subtitleOutlineColor': subtitleOutlineColor,
  };

  factory PlaybackSettings.fromJson(
    Map<String, dynamic> json,
  ) => PlaybackSettings(
    touchGestures: json['touchGestures'] != false,
    holdToSpeed: json['holdToSpeed'] != false,
    holdSpeed: _double(json['holdSpeed'], 2).clamp(1.25, 4),
    defaultPlaybackSpeed: _double(json['defaultPlaybackSpeed'], 1).clamp(.5, 2),
    preferredVideoHeight:
        const {
          0,
          480,
          720,
          1080,
          1440,
          2160,
        }.contains(_int(json['preferredVideoHeight'], 0))
        ? _int(json['preferredVideoHeight'], 0)
        : 0,
    showLoadingOverlay: json['showLoadingOverlay'] != false,
    showLoadingStatus: json['showLoadingStatus'] != false,
    pauseOverlay: json['pauseOverlay'] != false,
    autoPlayNextEpisode: json['autoPlayNextEpisode'] == true,
    nextEpisodeThresholdPercent: _int(
      json['nextEpisodeThresholdPercent'],
      99,
    ).clamp(50, 100),
    autoStreamSelection: json['autoStreamSelection'] != false,
    streamSelectionTimeoutSeconds: _int(
      json['streamSelectionTimeoutSeconds'],
      3,
    ).clamp(1, 15),
    allowedProviderIds: json['allowedProviderIds'] is List
        ? (json['allowedProviderIds'] as List).whereType<String>().toSet()
        : null,
    p2pStreaming: json['p2pStreaming'] != false,
    reuseLastLink: json['reuseLastLink'] == true,
    lastLinkCacheHours: _int(json['lastLinkCacheHours'], 24).clamp(1, 168),
    preferredAudioLanguage: '${json['preferredAudioLanguage'] ?? 'device'}',
    secondaryAudioLanguage: '${json['secondaryAudioLanguage'] ?? ''}',
    preferredSubtitleLanguage: '${json['preferredSubtitleLanguage'] ?? ''}',
    secondarySubtitleLanguage: '${json['secondarySubtitleLanguage'] ?? ''}',
    stripSdhSubtitles: json['stripSdhSubtitles'] == true,
    useForcedSubtitles: json['useForcedSubtitles'] == true,
    showOnlyPreferredLanguages: json['showOnlyPreferredLanguages'] == true,
    subtitleSize: _double(json['subtitleSize'], 18).clamp(12, 40),
    subtitlePosition: _subtitlePosition(json),
    subtitleBold: json['subtitleBold'] == true,
    subtitleTextColor: _int(json['subtitleTextColor'], 0xFFFFFFFF),
    subtitleBackgroundColor: _int(json['subtitleBackgroundColor'], 0x00000000),
    subtitleOutline: json['subtitleOutline'] != false,
    subtitleOutlineColor: _int(json['subtitleOutlineColor'], 0xFF000000),
  );

  /// Reads [subtitlePosition]. Saves from before it existed hold a pixel
  /// offset (`subtitleVerticalOffset`, 0-80, default 20) instead; that is
  /// converted against a typical 400-pixel-tall landscape phone player.
  static double _subtitlePosition(Map<String, dynamic> json) {
    final value = json.containsKey('subtitlePosition')
        ? _double(json['subtitlePosition'], 0)
        : json.containsKey('subtitleVerticalOffset')
        ? (_double(json['subtitleVerticalOffset'], 20).clamp(0, 80) - 20) / 400
        : 0.0;
    if (!value.isFinite) return 0;
    return value.clamp(subtitlePositionMin, subtitlePositionMax).toDouble();
  }

  /// Distance from the bottom of a player [height] tall to the bottom of
  /// the subtitles. Position 0 keeps the original place: 100 above the bottom
  /// edge, or 152 while the bottom controls show. The result stays inside
  /// the [padding] safe area and below the top bar, so subtitles can never
  /// be moved off screen.
  static double subtitleBottom({
    required double height,
    required EdgeInsets padding,
    required bool controlsVisible,
    required double position,
  }) {
    final base = (controlsVisible ? 132.0 : 80.0) + 20;
    final lowest = padding.bottom + 8;
    // Room above for the top bar and about two lines of text.
    final highest = math.max(lowest, height - padding.top - 120);
    return (base + position * height).clamp(lowest, highest).toDouble();
  }

  static int _int(dynamic value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

  static double _double(dynamic value, double fallback) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;
}

/// How [PlaybackSettings.subtitlePosition] is shown: `Default`, `Higher 6%`
/// or `Lower 4%`, in percent of the player height.
String subtitlePositionLabel(double position) {
  final percent = (position * 100).round();
  if (percent == 0) return 'Default';
  return percent > 0 ? 'Higher $percent%' : 'Lower ${-percent}%';
}
