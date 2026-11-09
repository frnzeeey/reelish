// The player's settings: the values a session can change (speed, quality,
// audio track, subtitles and their timing, picture fit), and the sheet that
// changes them, organised in categories.
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/stream_source.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import 'audio_track_sheet.dart';
import 'player_sheet.dart';

class PlayerSettings {
  const PlayerSettings({
    this.speed = 1,
    this.fit = BoxFit.contain,
    this.ratio = 0,
    this.subtitle,
    this.subtitleDelay = 0,
    this.videoTrack,
    this.audioTrackId,
    this.adjustSubtitlePosition = false,
    this.switchEngine = false,
  });
  final double speed;
  final BoxFit fit;
  final double ratio;
  final SubtitleTrack? subtitle;
  final double subtitleDelay;
  final VideoTrack? videoTrack;
  final String? audioTrackId;

  /// Set when the viewer asked to move subtitles; the player then shows its
  /// position panel, where the subtitles stay visible.
  final bool adjustSubtitlePosition;

  /// Set when the viewer asked to reopen the stream on the other playback
  /// engine, the recovery for a picture that stays black while audio plays.
  final bool switchEngine;
  PlayerSettings copyWith({
    double? speed,
    BoxFit? fit,
    double? ratio,
    SubtitleTrack? subtitle,
    bool clearSubtitle = false,
    double? subtitleDelay,
    VideoTrack? videoTrack,
    bool clearVideoTrack = false,
    String? audioTrackId,
    bool? adjustSubtitlePosition,
    bool? switchEngine,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    fit: fit ?? this.fit,
    ratio: ratio ?? this.ratio,
    subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
    subtitleDelay: subtitleDelay ?? this.subtitleDelay,
    videoTrack: clearVideoTrack ? null : (videoTrack ?? this.videoTrack),
    audioTrackId: audioTrackId ?? this.audioTrackId,
    adjustSubtitlePosition:
        adjustSubtitlePosition ?? this.adjustSubtitlePosition,
    switchEngine: switchEngine ?? this.switchEngine,
  );
}

/// Playback settings: a root page of categories, each showing its current
/// value, and a page per category with the choices the stream really has.
/// A choice applies at once: the sheet closes with the new [PlayerSettings].
/// Back on a category page returns to the categories; on the root it closes.
class PlayerSettingsSheet extends StatefulWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.value,
    required this.subtitles,
    this.videoTracks = const [],
    this.audioTracks = const [],
    this.alternateEngine,
  });
  final PlayerSettings value;
  final List<SubtitleTrack> subtitles;
  final List<VideoTrack> videoTracks;
  final List<VideoAudioTrack> audioTracks;

  /// Name of the other playback engine, when it can open this stream.
  final String? alternateEngine;

  /// The speeds offered; every engine Reelish uses plays all of them.
  static const speeds = [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0];

  static Future<PlayerSettings?> show(
    BuildContext context,
    PlayerSettings value,
    List<SubtitleTrack> subtitles, [
    List<VideoTrack> videoTracks = const [],
    List<VideoAudioTrack> audioTracks = const [],
    String? alternateEngine,
  ]) => showModalBottomSheet<PlayerSettings>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => PlayerSettingsSheet(
      value: value,
      subtitles: subtitles,
      videoTracks: videoTracks,
      audioTracks: audioTracks,
      alternateEngine: alternateEngine,
    ),
  );

  /// `1.5×`, or `Normal` at 1.
  static String speedLabel(double speed) => speed == 1
      ? 'Normal'
      : '${speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed}×';

  /// A quality's name as the stream gives it, else its height.
  static String qualityLabel(VideoTrack track) =>
      track.label?.isNotEmpty == true
      ? track.label!
      : track.height == null
      ? 'Track'
      : '${track.height}p';

  /// What the stream says about a quality: size, frame rate, bitrate.
  static String qualityDetail(VideoTrack track) => [
    if (track.width != null && track.height != null)
      '${track.width}×${track.height}',
    if (track.frameRate case final fps? when fps > 0)
      '${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 2)} fps',
    if (track.bitrate case final bits? when bits > 0)
      '${(bits / 1e6).toStringAsFixed(1)} Mbps',
  ].join(' · ');

  /// `+0.50 s`, `-0.25 s`, or `No delay`.
  static String delayLabel(double delay) => delay == 0
      ? 'No delay'
      : '${delay > 0 ? '+' : '−'}${delay.abs().toStringAsFixed(2)} s';

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

enum _Page { root, speed, quality, audio, subtitles, timing, picture }

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  _Page _page = _Page.root;

  /// The timing page steps this and applies it once.
  late double _delay = widget.value.subtitleDelay;

  PlayerSettings get _value => widget.value;

  void _apply(PlayerSettings result) => Navigator.pop(context, result);

  void _open(_Page page) => setState(() => _page = page);

  void _up() => setState(
    () => _page = _page == _Page.timing ? _Page.subtitles : _Page.root,
  );

  VideoAudioTrack? get _currentAudio => widget.audioTracks
      .where(
        (track) =>
            track.id == _value.audioTrackId ||
            (_value.audioTrackId == null && track.isSelected),
      )
      .firstOrNull;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _page == _Page.root,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _up();
    },
    child: AnimatedSwitcher(
      duration: AppMotion.resolve(context, AppMotion.standard),
      switchInCurve: AppMotion.enter,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(key: ValueKey(_page), child: _pageFor(_page)),
    ),
  );

  Widget _pageFor(_Page page) => switch (page) {
    _Page.root => _root(),
    _Page.speed => _choices(
      title: 'Speed',
      icon: ReelishIcons.speed,
      children: [
        for (final speed in PlayerSettingsSheet.speeds)
          PlayerSheetOption(
            title: PlayerSettingsSheet.speedLabel(speed),
            selected: _value.speed == speed,
            onTap: () => _apply(_value.copyWith(speed: speed)),
          ),
      ],
    ),
    _Page.quality => _choices(
      title: 'Quality',
      icon: ReelishIcons.quality,
      subtitle: 'The qualities this stream offers.',
      children: [
        PlayerSheetOption(
          title: 'Auto',
          detail: 'Adjusts to your connection',
          selected: _value.videoTrack == null,
          trailing: 'Playing',
          onTap: () => _apply(_value.copyWith(clearVideoTrack: true)),
        ),
        for (final track in widget.videoTracks)
          PlayerSheetOption(
            title: PlayerSettingsSheet.qualityLabel(track),
            detail: PlayerSettingsSheet.qualityDetail(track),
            selected: _value.videoTrack == track,
            trailing: 'Playing',
            onTap: () => _apply(_value.copyWith(videoTrack: track)),
          ),
      ],
    ),
    _Page.audio => _choices(
      title: AudioTrackSheet.title,
      icon: ReelishIcons.audioWave,
      children: [
        for (final (index, track) in widget.audioTracks.indexed)
          PlayerSheetOption(
            title: AudioTrackLabel.title(track, index),
            detail: AudioTrackLabel.detail(widget.audioTracks, index),
            selected: identical(track, _currentAudio),
            trailing: 'Playing',
            onTap: () => _apply(_value.copyWith(audioTrackId: track.id)),
          ),
      ],
    ),
    _Page.subtitles => _choices(
      title: 'Subtitles',
      icon: ReelishIcons.subtitles,
      children: [
        _CategoryRow(
          icon: ReelishIcons.clock,
          title: 'Timing',
          value: PlayerSettingsSheet.delayLabel(_value.subtitleDelay),
          onTap: () => _open(_Page.timing),
        ),
        _CategoryRow(
          icon: ReelishIcons.alignCenter,
          title: 'Position',
          value: 'Move them on screen',
          onTap: () => _apply(_value.copyWith(adjustSubtitlePosition: true)),
        ),
        const _SectionLabel('Track'),
        PlayerSheetOption(
          title: 'Off',
          selected: _value.subtitle == null,
          onTap: () => _apply(_value.copyWith(clearSubtitle: true)),
        ),
        for (final track in widget.subtitles)
          PlayerSheetOption(
            title: track.lang,
            detail: [
              if (track.hearingImpaired) 'SDH',
              if (track.addonName.isNotEmpty) track.addonName,
              track.format.isNotEmpty
                  ? track.format.toUpperCase()
                  : track.url.split('/').last,
            ].join(' · '),
            selected: _value.subtitle?.key == track.key,
            trailing: 'Showing',
            onTap: () => _apply(_value.copyWith(subtitle: track)),
          ),
      ],
    ),
    _Page.timing => _choices(
      title: 'Subtitle timing',
      icon: ReelishIcons.clock,
      subtitle: 'Earlier if subtitles appear late; later if they come early.',
      children: [_timing()],
    ),
    _Page.picture => _choices(
      title: 'Picture',
      icon: ReelishIcons.tune,
      children: [
        const _SectionLabel('Aspect ratio'),
        for (final (ratio, label, detail) in const [
          (0.0, 'Auto', 'As the video is made'),
          (16 / 9, '16:9', 'Widescreen'),
          (4 / 3, '4:3', 'Classic TV'),
        ])
          PlayerSheetOption(
            title: label,
            detail: detail,
            selected: _value.ratio == ratio,
            onTap: () => _apply(_value.copyWith(ratio: ratio)),
          ),
        const _SectionLabel('Fill the screen'),
        for (final (fit, label, detail) in const [
          (BoxFit.contain, 'Fit', 'The whole picture, with bars if needed'),
          (BoxFit.cover, 'Fill', 'No bars; the edges may be cut'),
          (BoxFit.fill, 'Stretch', 'No bars; the picture is stretched'),
        ])
          PlayerSheetOption(
            title: label,
            detail: detail,
            selected: _value.fit == fit,
            onTap: () => _apply(_value.copyWith(fit: fit)),
          ),
      ],
    ),
  };

  Widget _root() {
    final audio = _currentAudio;
    final ratio = switch (_value.ratio) {
      0 => 'Auto',
      final r when (r - 16 / 9).abs() < .001 => '16:9',
      final r when (r - 4 / 3).abs() < .001 => '4:3',
      _ => 'Custom',
    };
    final fit = switch (_value.fit) {
      BoxFit.cover => 'Fill',
      BoxFit.fill => 'Stretch',
      _ => 'Fit',
    };
    final engine = widget.alternateEngine;
    return PlayerSheetFrame(
      icon: ReelishIcons.settings,
      title: 'Playback settings',
      children: [
        _CategoryRow(
          icon: ReelishIcons.speed,
          title: 'Speed',
          value: PlayerSettingsSheet.speedLabel(_value.speed),
          onTap: () => _open(_Page.speed),
          // The remote starts at the top of the list.
          autofocus: DeviceCapabilities.usesTvLayout,
        ),
        if (widget.videoTracks.isNotEmpty)
          _CategoryRow(
            icon: ReelishIcons.quality,
            title: 'Quality',
            value: _value.videoTrack == null
                ? 'Auto'
                : PlayerSettingsSheet.qualityLabel(_value.videoTrack!),
            onTap: () => _open(_Page.quality),
          ),
        if (widget.audioTracks.length > 1)
          _CategoryRow(
            icon: ReelishIcons.audioWave,
            title: AudioTrackSheet.title,
            value: audio == null
                ? 'Default'
                : AudioTrackLabel.title(
                    audio,
                    widget.audioTracks.indexOf(audio),
                  ),
            onTap: () => _open(_Page.audio),
          ),
        _CategoryRow(
          icon: ReelishIcons.subtitles,
          title: 'Subtitles',
          value: [
            _value.subtitle?.lang ?? 'Off',
            if (_value.subtitleDelay != 0)
              PlayerSettingsSheet.delayLabel(_value.subtitleDelay),
          ].join(' · '),
          onTap: () => _open(_Page.subtitles),
        ),
        _CategoryRow(
          icon: ReelishIcons.tune,
          title: 'Picture',
          value: '$ratio · $fit',
          onTap: () => _open(_Page.picture),
        ),
        if (engine != null) ...[
          const _SectionLabel('Trouble playing'),
          _CategoryRow(
            icon: ReelishIcons.swapHorizontal,
            title: 'Switch to $engine',
            value: 'Try this if the picture stays black while audio plays.',
            onTap: () => _apply(_value.copyWith(switchEngine: true)),
          ),
        ],
      ],
    );
  }

  Widget _choices({
    required String title,
    required IconData icon,
    required List<Widget> children,
    String? subtitle,
  }) => PlayerSheetFrame(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onBack: _up,
    children: children,
  );

  Widget _timing() {
    final muted = GlassTheme.playerSurfaces.textSecondary;
    void step(double by) =>
        setState(() => _delay = (_delay + by).clamp(-5, 5).toDouble());
    return Column(
      children: [
        const SizedBox(height: AppSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: 'Earlier by a quarter second',
              onPressed: _delay <= -5 ? null : () => step(-.25),
              icon: const Icon(ReelishIcons.minus),
            ),
            SizedBox(
              width: 140,
              child: Column(
                children: [
                  Text(
                    PlayerSettingsSheet.delayLabel(_delay),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _delay < 0
                        ? 'Earlier'
                        : _delay > 0
                        ? 'Later'
                        : 'As the file has them',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Later by a quarter second',
              onPressed: _delay >= 5 ? null : () => step(.25),
              icon: const Icon(ReelishIcons.add),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Row(
          children: [
            TextButton.icon(
              onPressed: _delay == 0 ? null : () => setState(() => _delay = 0),
              icon: const Icon(ReelishIcons.restore, size: 18),
              label: const Text('Reset'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _delay == _value.subtitleDelay
                  ? null
                  : () => _apply(_value.copyWith(subtitleDelay: _delay)),
              child: const Text('Apply'),
            ),
          ],
        ),
      ],
    );
  }
}

/// A category on the root page (or a link on a category page): its icon,
/// name and current value, and a chevron. At least 56 high for touch.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final s = GlassTheme.playerSurfaces;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: s.textPrimary.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          autofocus: autofocus,
          child: Semantics(
            button: true,
            label: '$title, $value',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: GlassTheme.playerPrimary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: s.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      ReelishIcons.chevronRight,
                      size: 20,
                      color: s.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: GlassTheme.playerSurfaces.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    ),
  );
}
