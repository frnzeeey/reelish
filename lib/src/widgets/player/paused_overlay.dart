import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/episode_context.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/glass_theme.dart';
import 'player_controls.dart';

/// What the pause screen shows for the playing title. Everything comes from
/// data the player already has; a missing value is left out, never invented.
@immutable
class PauseCardContent {
  const PauseCardContent({
    required this.title,
    this.metadata = const [],
    this.rating = '',
    this.synopsis = '',
    this.artwork = const [],
  });

  /// Movie title, or the series name for an episode.
  final String title;

  /// Short facts: `2014`, `Sci-Fi`, `2h 49m` for a movie, or `S02 E04`,
  /// `The Awakening`, `48 min` for an episode.
  final List<String> metadata;

  /// Average rating such as `7.8`; empty when the title is unrated.
  final String rating;

  /// Movie synopsis, or the episode's own synopsis (the series synopsis when
  /// the episode has none); empty when neither exists.
  final String synopsis;

  /// Artwork URLs, best first. The next one is tried if one fails to load.
  final List<String> artwork;

  factory PauseCardContent.resolve({
    required MediaItem item,
    EpisodeRef? episode,
    int? season,
    int? episodeNumber,
    MediaDetails? details,
    Duration? duration,
  }) {
    // The stream's own length is exact; the listed runtime covers live or
    // not-yet-known durations.
    final streamLength = duration != null && duration > Duration.zero
        ? formatRuntime(duration)
        : '';
    final titleSynopsis = _firstText([item.description, details?.overview]);
    if (item.type == 'series') {
      final seasonNumber = episode?.season ?? season;
      final number = episode?.episode ?? episodeNumber;
      final listedRuntime = episode?.runtimeMinutes;
      return PauseCardContent(
        title: _clean(item.name),
        metadata: _nonEmpty([
          if (seasonNumber != null && number != null)
            'S${_twoDigits(seasonNumber)} E${_twoDigits(number)}',
          _clean(episode?.title),
          streamLength.isNotEmpty || listedRuntime == null
              ? streamLength
              : formatRuntime(Duration(minutes: listedRuntime)),
        ]),
        synopsis: _firstText([episode?.overview, titleSynopsis]),
        artwork: _unique([episode?.still, item.background, item.poster]),
      );
    }
    final listedRuntime = details?.runtimeMinutes;
    return PauseCardContent(
      title: _clean(item.name),
      metadata: _nonEmpty([
        _clean(item.year),
        (details?.genres ?? const <String>[])
            .map(_clean)
            .where((genre) => genre.isNotEmpty)
            .take(2)
            .join(', '),
        streamLength.isNotEmpty || listedRuntime == null || listedRuntime <= 0
            ? streamLength
            : formatRuntime(Duration(minutes: listedRuntime)),
      ]),
      rating: _rating(item.rating).isNotEmpty
          ? _rating(item.rating)
          : _rating(details?.rating),
      synopsis: titleSynopsis,
      artwork: _unique([item.background, item.poster]),
    );
  }

  /// `48 min`, `2h`, or `2h 49m`; empty under a minute.
  static String formatRuntime(Duration duration) {
    final minutes = (duration.inSeconds / 60).round();
    if (minutes < 1) return '';
    if (minutes < 60) return '$minutes min';
    final rest = minutes % 60;
    return rest == 0 ? '${minutes ~/ 60}h' : '${minutes ~/ 60}h ${rest}m';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  /// Trimmed single-line text; serialized nulls count as missing.
  static String _clean(String? value) {
    final text = (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return const {'null', 'undefined'}.contains(text.toLowerCase()) ? '' : text;
  }

  static String _firstText(List<String?> values) => values
      .map(_clean)
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');

  static List<String> _nonEmpty(List<String> values) =>
      values.where((value) => value.isNotEmpty).toList();

  static List<String> _unique(List<String?> urls) =>
      urls.map(_clean).where((url) => url.isNotEmpty).toSet().toList();

  static String _rating(String? value) {
    final rating = double.tryParse(_clean(value));
    return rating == null || rating <= 0 ? '' : rating.toStringAsFixed(1);
  }
}

/// The decoded artwork image. Precaching and the overlay share it, so they
/// share one image cache entry and the artwork is downloaded once.
ImageProvider pauseArtworkImage(String url, int decodeWidth) =>
    ResizeImage(NetworkImage(url), width: decodeWidth);

/// Reelish's pause screen: the paused title's artwork, a large play button,
/// and the title, details and synopsis. It sits between the video and the
/// playback controls and never owns playback; [onPlay] resumes through the
/// player's own controller.
class ReelishPausedOverlay extends StatefulWidget {
  const ReelishPausedOverlay({
    super.key,
    required this.visible,
    required this.scrubbing,
    required this.content,
    required this.artworkWidth,
    required this.onPlay,
    this.playFocusNode,
  });

  /// Whether playback is paused long enough to show the pause screen.
  final ValueListenable<bool> visible;

  /// While the viewer drags the progress bar the artwork steps aside, so the
  /// frame being sought to stays visible.
  final ValueListenable<bool> scrubbing;
  final PauseCardContent content;

  /// Decode width for the artwork, in physical pixels.
  final int artworkWidth;
  final VoidCallback onPlay;

  /// Focus of the resume button, where a remote lands while paused.
  final FocusNode? playFocusNode;

  @override
  State<ReelishPausedOverlay> createState() => _ReelishPausedOverlayState();
}

class _ReelishPausedOverlayState extends State<ReelishPausedOverlay>
    with SingleTickerProviderStateMixin {
  static const _enter = Duration(milliseconds: 460);
  static const _exit = Duration(milliseconds: 280);

  /// One controller drives the whole sequence: artwork, then the play
  /// button, then the title and details, then the synopsis. Reversing it
  /// clears the text first and lets the artwork fade off the video last.
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _enter,
    reverseDuration: _exit,
    value: widget.visible.value ? 1 : 0,
  );
  late final Animation<double> _artwork = _interval(0, .75, Curves.easeOut);
  late final Animation<double> _artworkScale = Tween(
    begin: 1.05,
    end: 1.0,
  ).animate(_interval(0, 1, Curves.easeOutCubic));
  late final Animation<double> _scrim = _interval(0, .6, Curves.easeOut);
  late final Animation<double> _button = _interval(.25, .8, Curves.easeOut);
  late final Animation<double> _buttonScale = Tween(
    begin: .8,
    end: 1.0,
  ).animate(_interval(.25, .85, Curves.easeOutBack));
  late final Animation<double> _details = _interval(
    .4,
    .9,
    Curves.easeOutCubic,
  );
  late final Animation<double> _synopsis = _interval(
    .52,
    1,
    Curves.easeOutCubic,
  );
  late final Animation<Offset> _detailsSlide = Tween(
    begin: const Offset(0, .12),
    end: Offset.zero,
  ).animate(_details);
  late final Animation<Offset> _synopsisSlide = Tween(
    begin: const Offset(0, .15),
    end: Offset.zero,
  ).animate(_synopsis);

  /// Built only while shown or animating; hidden, it costs nothing.
  late bool _shown = _motion.value > 0;

  Animation<double> _interval(double begin, double end, Curve curve) =>
      CurvedAnimation(
        parent: _motion,
        curve: Interval(begin, end, curve: curve),
      );

  @override
  void initState() {
    super.initState();
    widget.visible.addListener(_sync);
    _motion.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _motion
      ..duration = reduceMotion ? Duration.zero : _enter
      ..reverseDuration = reduceMotion ? Duration.zero : _exit;
  }

  @override
  void didUpdateWidget(ReelishPausedOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible.removeListener(_sync);
      widget.visible.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.visible.removeListener(_sync);
    _motion.dispose();
    super.dispose();
  }

  void _sync() {
    if (widget.visible.value) {
      _motion.forward();
    } else {
      _motion.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    final shown = !status.isDismissed;
    if (shown != _shown && mounted) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    return LayoutBuilder(builder: _layout);
  }

  Widget _layout(BuildContext context, BoxConstraints constraints) {
    final content = widget.content;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final padding = MediaQuery.paddingOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final safe = Rect.fromLTRB(
      padding.left,
      padding.top,
      math.max(padding.left, width - padding.right),
      math.max(padding.top, height - padding.bottom),
    );
    final wide = width > height;
    // Overscan-safe margins on real TVs only; Windows shares the TV
    // interface but not its cropped edges.
    final tv = DeviceCapabilities.isTv;
    // Picture-in-picture and other tiny windows get the artwork and the
    // play button only.
    final compact = safe.height < 260 || safe.width < 300;
    // Text, column and button grow with the screen's height, so a large or
    // ultrawide window is not a small block pinned to one edge.
    final scale = (safe.height / 720).clamp(1.0, 1.5);
    final playSize = compact
        ? 56.0
        : (wide ? safe.height * .2 : safe.width * .2).clamp(64.0, 92.0 * scale);

    // The text keeps to the controls' edges: their left edge, and clear of
    // their top and bottom bars (all within TV-safe margins on a TV).
    final edge = PlayerControlsLayout.contentEdge(tv: tv);
    final topBarSpace = PlayerControlsLayout.topBarExtent(tv: tv);
    final bottomBarSpace = PlayerControlsLayout.bottomBarExtent(tv: tv);
    var center = safe.center;
    Rect? info;
    if (!compact) {
      if (wide) {
        // The text gets a share of the screen rather than whatever the
        // centered button leaves: on a phone that was barely a third, which
        // broke titles early and cut the details line short. Where the text
        // needs the room, the button moves right of center to keep a clear
        // gap; on larger screens it stays centered.
        const gap = 40.0;
        final right = math.min(
          safe.left + edge + math.max(safe.width * .44, 260.0),
          safe.left + edge + 560 * scale,
        );
        final buttonX = math.min(
          math.max(center.dx, right + gap + playSize / 2),
          safe.right - edge - playSize / 2,
        );
        center = Offset(buttonX, center.dy);
        info = Rect.fromLTRB(
          safe.left + edge,
          safe.top + topBarSpace,
          math.min(right, buttonX - playSize / 2 - gap),
          safe.bottom - bottomBarSpace,
        );
      } else {
        info = Rect.fromLTRB(
          safe.left + 24,
          center.dy + playSize / 2 + 28,
          safe.right - 24,
          safe.bottom - bottomBarSpace,
        );
      }
      if (info.width < 180 || info.height < 72) info = null;
    }

    final artwork = _Artwork(
      urls: content.artwork,
      decodeWidth: widget.artworkWidth,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: FadeTransition(
            opacity: _artwork,
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.scrubbing,
              builder: (context, scrubbing, child) => AnimatedOpacity(
                opacity: scrubbing ? 0 : 1,
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                child: child,
              ),
              child: reduceMotion
                  ? artwork
                  : ScaleTransition(scale: _artworkScale, child: artwork),
            ),
          ),
        ),
        IgnorePointer(
          child: FadeTransition(
            opacity: _scrim,
            child: _Scrim(
              wide: wide,
              // The accent glow sits behind the play button.
              glow: Alignment(
                width == 0 ? 0 : center.dx / width * 2 - 1,
                height == 0 ? 0 : center.dy / height * 2 - 1,
              ),
            ),
          ),
        ),
        if (info != null)
          Positioned.fromRect(
            rect: info,
            child: IgnorePointer(
              child: Align(
                alignment: wide ? Alignment.centerLeft : Alignment.topCenter,
                // Never scrolls; it clips instead of overflowing if large
                // text still does not fit after the line budget below.
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: _detailsColumn(
                    content,
                    info,
                    wide,
                    width,
                    scale,
                    textScaler,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: center.dx - playSize / 2,
          top: center.dy - playSize / 2,
          width: playSize,
          height: playSize,
          child: ValueListenableBuilder<bool>(
            valueListenable: widget.visible,
            // Not tappable while fading out.
            builder: (context, visible, child) => IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(excluding: !visible, child: child!),
            ),
            child: FadeTransition(
              opacity: _button,
              child: ScaleTransition(
                scale: _buttonScale,
                child: _PausePlayButton(
                  size: playSize,
                  onPressed: widget.onPlay,
                  focusNode: widget.playFocusNode,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _detailsColumn(
    PauseCardContent content,
    Rect info,
    bool wide,
    double width,
    double scale,
    TextScaler textScaler,
  ) {
    final titleSize = wide
        ? (width * .032).clamp(22.0, 40.0 * scale)
        : (width * .068).clamp(22.0, 34.0);
    final large = wide && width >= 1000;
    final synopsisSize = (large ? 15.5 : 14.0) * scale;
    final metaSize = 13.5 * scale;
    final maxSynopsisLines = large ? 4 : 3;
    double lineHeight(double size, double height) =>
        textScaler.scale(size) * height;
    // Characters that fit on one line of [size] text, roughly.
    double charsPerLine(double size, double em) =>
        math.max(1.0, info.width / (textScaler.scale(size) * em));

    // A line budget from the room available, so the synopsis shortens on
    // short screens instead of pushing into the controls.
    final titleLines = content.title.length > charsPerLine(titleSize, .56)
        ? 2
        : 1;
    // The details line may wrap once rather than cut off what comes last
    // (often the rating). Room is kept for the second line whenever it
    // might be needed (a generous width per character), so the synopsis
    // never has to give way to it afterwards.
    final metadataText = [
      ...content.metadata,
      if (content.rating.isNotEmpty) '* ${content.rating}',
    ].join('  ·  ');
    final metadataLines = metadataText.isEmpty
        ? 0
        : (metadataText.length > charsPerLine(metaSize, .65) ? 2 : 1);
    final used =
        lineHeight(11 * scale, 1.3) +
        10 +
        titleLines * lineHeight(titleSize, 1.12) +
        (metadataLines == 0
            ? 0
            : metadataLines * lineHeight(metaSize, 1.35) + 10) +
        14;
    final synopsisLines = content.synopsis.isEmpty
        ? 0
        : math.min(
            maxSynopsisLines,
            ((info.height - used) / lineHeight(synopsisSize, 1.45)).floor(),
          );
    final align = wide ? TextAlign.start : TextAlign.center;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        FadeTransition(
          opacity: _details,
          child: SlideTransition(
            position: _detailsSlide,
            child: _PauseHeading(
              content: content,
              titleSize: titleSize,
              scale: scale,
              // Two lines may always be used; text that fits uses one.
              metadataLines: 2,
              wide: wide,
              align: align,
            ),
          ),
        ),
        // Fewer than two lines reads as a fragment; leave it out instead.
        if (synopsisLines >= 2)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: FadeTransition(
              opacity: _synopsis,
              child: SlideTransition(
                position: _synopsisSlide,
                child: Text(
                  content.synopsis,
                  maxLines: synopsisLines,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: TextStyle(
                    color: const Color(0xD9FFFFFF),
                    fontSize: synopsisSize,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The eyebrow, title and metadata line.
class _PauseHeading extends StatelessWidget {
  const _PauseHeading({
    required this.content,
    required this.titleSize,
    required this.scale,
    required this.metadataLines,
    required this.wide,
    required this.align,
  });

  final PauseCardContent content;
  final double titleSize;

  /// How much larger than on a 720-high screen the smaller text is drawn.
  final double scale;

  /// Lines the details line may take.
  final int metadataLines;
  final bool wide;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final metaStyle = TextStyle(
      color: const Color(0xCCFFFFFF),
      fontSize: 13.5 * scale,
      height: 1.35,
      fontWeight: FontWeight.w600,
      shadows: const [Shadow(color: Colors.black54, blurRadius: 10)],
    );
    final hasMetadata =
        content.metadata.isNotEmpty || content.rating.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (wide) ...[
              Container(
                width: 18,
                height: 2,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              'PAUSED',
              style: TextStyle(
                color: accent,
                fontSize: 11 * scale,
                height: 1.3,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          content.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: TextStyle(
            color: Colors.white,
            fontSize: titleSize,
            height: 1.12,
            fontWeight: FontWeight.w800,
            letterSpacing: -.4,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 18)],
          ),
        ),
        if (hasMetadata)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text.rich(
              TextSpan(
                children: [
                  for (final (index, fact) in content.metadata.indexed) ...[
                    if (index > 0) const TextSpan(text: '  ·  '),
                    TextSpan(text: fact),
                  ],
                  if (content.rating.isNotEmpty) ...[
                    if (content.metadata.isNotEmpty)
                      const TextSpan(text: '  ·  '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Icon(
                          Symbols.star_rounded,
                          fill: 1,
                          size: 15 * scale,
                          color: accent,
                        ),
                      ),
                    ),
                    TextSpan(
                      text: content.rating,
                      semanticsLabel: 'Rated ${content.rating}',
                    ),
                  ],
                ],
              ),
              maxLines: metadataLines,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: metaStyle,
            ),
          ),
      ],
    );
  }
}

/// Artwork filling the screen without distortion. A URL that fails falls
/// through to the next; with none left, nothing is drawn and the paused
/// video frame shows through.
class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.urls,
    required this.decodeWidth,
    this.index = 0,
  });

  final List<String> urls;
  final int decodeWidth;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (index >= urls.length) return const SizedBox.shrink();
    return Image(
      image: pauseArtworkImage(urls[index], decodeWidth),
      fit: BoxFit.cover,
      // Keeps the series artwork up while an episode still replaces it.
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
      // Cached artwork appears with the overlay; artwork still downloading
      // fades in when it arrives rather than popping in.
      frameBuilder: (context, child, frame, synchronous) => synchronous
          ? child
          : AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: child,
            ),
      errorBuilder: (context, _, _) =>
          _Artwork(urls: urls, decodeWidth: decodeWidth, index: index + 1),
    );
  }
}

/// Darkens the artwork (or the paused frame) so text stays readable: an
/// overall dim, a directional shade behind the text, a floor under the
/// controls, and a faint accent glow behind the play button.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.wide, this.glow = Alignment.center});

  final bool wide;

  /// Where the accent glow centers: behind the play button.
  final Alignment glow;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Color(0x52000000)),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: wide
              ? const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xD9000000),
                    Color(0x8C000000),
                    Color(0x00000000),
                  ],
                  stops: [0, .4, .75],
                )
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x59000000),
                    Color(0x00000000),
                    Color(0x99000000),
                    Color(0xE6000000),
                  ],
                  stops: [0, .3, .6, 1],
                ),
        ),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xB3000000), Color(0x00000000)],
            stops: [0, .45],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: glow,
            radius: .5,
            colors: [
              GlassTheme.primary.withValues(alpha: .14),
              GlassTheme.primary.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    ],
  );
}

/// The large resume button: a translucent glass disc with a soft accent glow.
class _PausePlayButton extends StatelessWidget {
  const _PausePlayButton({
    required this.size,
    required this.onPressed,
    this.focusNode,
  });

  final double size;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Resume playback',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: GlassTheme.primary.withValues(alpha: .32),
            blurRadius: size * .45,
            spreadRadius: 1,
          ),
          const BoxShadow(color: Color(0x66000000), blurRadius: 24),
        ],
      ),
      child: Material(
        shape: const CircleBorder(
          side: BorderSide(color: Color(0x59FFFFFF), width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x47FFFFFF), Color(0x14FFFFFF)],
            ),
          ),
          child: InkWell(
            onTap: onPressed,
            focusNode: focusNode,
            focusColor: GlassTheme.primary.withValues(alpha: .55),
            child: SizedBox.square(
              dimension: size,
              child: Icon(
                Symbols.play_arrow_rounded,
                fill: 1,
                size: size * .54,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
