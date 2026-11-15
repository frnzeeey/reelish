// Reelish Wrapped as a story: a slide per highlight, only for highlights
// with real numbers behind them, then a finale with how everything was
// counted. Touch taps and swipes on phones; the remote's left and right on
// TV; arrows, Enter, Escape and buttons on Windows. Each highlight can be
// shared as a card (WrappedShareSheet), on phones and Windows only. The
// stage stays dark in every theme, and motion follows reduced motion and
// stops on TV.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/brand_logo.dart';
import '../widgets/settings/settings_components.dart';
import 'wrapped_cards.dart';
import 'wrapped_export.dart';
import 'wrapped_service.dart';
import 'wrapped_stats.dart';
import 'wrapped_visuals.dart';

/// Opens Reelish Wrapped: the list of years, or [year]'s recap. Home sets
/// it while it is up (it holds the catalog the recap looks titles up in),
/// as it does for watch parties; null until then.
abstract final class WrappedLauncher {
  static void Function({int? year})? open;
}

/// Profile > Reelish Wrapped: each year there is, and when the next opens.
class WrappedHubScreen extends StatelessWidget {
  const WrappedHubScreen({
    super.key,
    required this.service,
    this.displayName = '',
    this.onBack,
  });

  final WrappedService service;
  final String displayName;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final next = service.latestYear + 1;
    void open(int year, {bool preview = false}) => unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WrappedScreen(
            service: service,
            year: year,
            preview: preview,
            displayName: displayName,
          ),
        ),
      ),
    );
    return SettingsPage(
      title: 'Reelish Wrapped',
      subtitle: 'Your year in movies and series. Only you see it.',
      icon: ReelishIcons.star,
      onBack: onBack,
      footer: null,
      children: [
        FutureBuilder<List<int>>(
          future: service.years(),
          builder: (context, snapshot) => SettingsSection(
            label: 'YOUR YEARS',
            description:
                'Counted from what you watched on Reelish, on any of your '
                'devices. A recap is kept on this device once you open it.',
            children: [
              for (final year in snapshot.data ?? [service.latestYear])
                SettingsTile(
                  icon: ReelishIcons.star,
                  title: 'Wrapped $year',
                  description: 'Open your recap',
                  onTap: () => open(year),
                ),
              SettingsTile(
                icon: ReelishIcons.calendar,
                title: 'Wrapped $next',
                description: 'Opens on 1 January ${next + 1}',
                enabled: false,
              ),
              if (service.isOpen(next, preview: true))
                SettingsTile(
                  icon: ReelishIcons.bug,
                  title: 'Preview $next so far',
                  description: 'Debug builds only; not kept',
                  onTap: () => open(next, preview: true),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class WrappedScreen extends StatefulWidget {
  const WrappedScreen({
    super.key,
    required this.service,
    required this.year,
    this.preview = false,
    this.displayName = '',
  });

  final WrappedService service;
  final int year;
  final bool preview;

  /// Offered for the share cards, off by default.
  final String displayName;

  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

class _Slide {
  const _Slide(this.palette, this.build, [this.card]);

  final WrappedPalette palette;
  final Widget Function(_SlideScope scope) build;
  final WrappedCardKind? card;
}

/// What a slide is drawn with.
class _SlideScope {
  const _SlideScope({
    required this.summary,
    required this.scale,
    required this.wide,
    required this.active,
    required this.turns,
  });

  final WrappedSummary summary;
  final double scale;

  /// Landscape: visual beside the words (TV, Windows, tablets turned).
  final bool wide;

  /// The slide on screen: its numbers count up.
  final bool active;
  final Animation<double> turns;
}

class _WrappedScreenState extends State<WrappedScreen>
    with SingleTickerProviderStateMixin {
  WrappedSummary? _summary;
  Object? _error;
  double _progress = 0;
  bool _refreshing = false;
  final _pages = PageController();
  final _focus = FocusNode(debugLabel: 'Wrapped story');
  int _index = 0;
  bool _canSave = false;

  /// The Reel's slow turn: one controller, stopped under reduced motion and
  /// on TV.
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(
      WrappedExport.canSave().then((v) {
        if (mounted) setState(() => _canSave = v);
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still =
        DeviceCapabilities.isTv || MediaQuery.disableAnimationsOf(context);
    if (still) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      unawaited(_turn.repeat());
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _error = null;
      _progress = 0;
      _refreshing = refresh;
    });
    try {
      final summary = await widget.service.load(
        widget.year,
        refresh: refresh,
        preview: widget.preview,
        progress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _refreshing = false;
        _index = 0;
      });
      if (_pages.hasClients) _pages.jumpToPage(0);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _refreshing = false;
      });
    }
  }

  List<_Slide> _slides(WrappedSummary s) => [
    _Slide(WrappedPalette.premiere, _welcome, WrappedCardKind.summary),
    if (s.movies.isNotEmpty)
      _Slide(WrappedPalette.movies, _movies, WrappedCardKind.movies),
    if (s.minutes >= 1)
      _Slide(
        WrappedPalette.hours,
        _hours,
        s.minutes >= 60 ? WrappedCardKind.hours : null,
      ),
    if (s.topSeries != null)
      _Slide(WrappedPalette.series, _series, WrappedCardKind.series),
    if (s.genres.isNotEmpty)
      _Slide(WrappedPalette.genres, _genres, WrappedCardKind.genre),
    if (s.actors.isNotEmpty)
      _Slide(WrappedPalette.actors, _actors, WrappedCardKind.actors),
    if (s.milestones.isNotEmpty) _Slide(WrappedPalette.milestones, _milestones),
    if (s.personas.isNotEmpty)
      _Slide(WrappedPalette.persona, _persona, WrappedCardKind.persona),
    _Slide(WrappedPalette.finale, _finale, WrappedCardKind.summary),
  ];

  void _go(int index, int count) {
    if (index < 0 || index >= count) return;
    setState(() => _index = index);
    // The buttons change with the slide; when the focused one goes, focus
    // returns to the story, so the arrows and the remote keep working.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null ||
          (primary != _focus && !primary.ancestors.contains(_focus))) {
        _focus.requestFocus();
      }
    });
    final duration = AppMotion.resolve(
      context,
      const Duration(milliseconds: 420),
    );
    if (duration == Duration.zero) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: duration,
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _close() => Navigator.of(context).maybePop();

  KeyEventResult _key(KeyEvent event, int count) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown) {
      _go(_index + 1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      _go(_index - 1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      backgroundColor: WrappedPalette.stage,
      body: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'Montserrat', color: Colors.white),
        child: summary == null || _refreshing
            ? _status()
            : summary.isEmpty
            ? _empty(summary)
            : _story(summary),
      ),
    );
  }

  Widget _status() {
    final error = _error;
    return WrappedBackdrop(
      palette: WrappedPalette.premiere,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _turn,
                    builder: (context, _) => WrappedReel(
                      size: 180,
                      palette: WrappedPalette.premiere,
                      turns: _turn.value,
                      child: Text('${widget.year}', style: WrappedType.hero(1)),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                if (error == null) ...[
                  Text(
                    'Gathering your ${widget.year}…',
                    style: WrappedType.headline(.8),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpace.md),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: _progress == 0 ? null : _progress,
                      color: WrappedPalette.coral,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ] else ...[
                  Text(
                    'Your recap could not be put together.',
                    style: WrappedType.headline(.8),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Check your connection and try again.',
                    style: WrappedType.body(1),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Wrap(
                    spacing: AppSpace.sm,
                    children: [
                      FilledButton(
                        autofocus: true,
                        onPressed: () => _load(),
                        child: const Text('Try again'),
                      ),
                      TextButton(onPressed: _close, child: const Text('Close')),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(WrappedSummary s) => WrappedBackdrop(
    palette: WrappedPalette.premiere,
    child: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Your ${s.year} story is still unwritten.',
                  style: WrappedType.headline(1),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  'Wrapped counts movies and episodes you watched to the end '
                  'on Reelish${s.partial ? ' from ${wrappedShortDate(s.coveredFrom)}' : ''}. '
                  'Nothing finished in ${s.year} was found.',
                  style: WrappedType.body(1),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpace.lg),
                FilledButton(
                  autofocus: true,
                  onPressed: _close,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _story(WrappedSummary summary) {
    final slides = _slides(summary);
    final count = slides.length;
    final tvLayout = DeviceCapabilities.usesTvLayout;
    final shareable =
        (WrappedExport.canShare || _canSave) && !DeviceCapabilities.isTv;
    final card = slides[_index.clamp(0, count - 1)].card;
    final last = _index == count - 1;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, event) => _key(event, count),
      child: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: count,
            physics: tvLayout
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => WrappedBackdrop(
              palette: slides[i].palette,
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth > box.maxHeight * 1.15;
                    final scale =
                        (wide ? box.maxHeight / 620 : box.maxWidth / 400).clamp(
                          .75,
                          1.6,
                        );
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpace.xl * scale,
                        64,
                        AppSpace.xl * scale,
                        96,
                      ),
                      child: slides[i].build(
                        _SlideScope(
                          summary: summary,
                          scale: scale,
                          wide: wide,
                          active: i == _index,
                          turns: _turn,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          // Tap the left third to go back, the rest to go on (phones).
          if (!tvLayout)
            Positioned.fill(
              top: 64,
              bottom: 96,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  final width = MediaQuery.sizeOf(context).width;
                  _go(
                    details.localPosition.dx < width / 3
                        ? _index - 1
                        : _index + 1,
                    count,
                  );
                },
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _Segments(count: count, index: _index),
                  ),
                  const SizedBox(width: 8),
                  if (!last)
                    TextButton(
                      onPressed: () => _go(count - 1, count),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Skip'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    color: Colors.white,
                    onPressed: _close,
                    icon: const Icon(ReelishIcons.close),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.xs,
                  children: [
                    if (tvLayout && _index > 0)
                      OutlinedButton.icon(
                        onPressed: () => _go(_index - 1, count),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(ReelishIcons.chevronLeft),
                        label: const Text('Back'),
                      ),
                    if (shareable && card != null)
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(
                          showWrappedShare(
                            context,
                            summary: summary,
                            kind: card,
                            displayName: widget.displayName,
                            canSave: _canSave,
                          ),
                        ),
                        icon: const Icon(ReelishIcons.share),
                        label: Text(last ? 'Share your year' : 'Share'),
                      ),
                    if (last)
                      OutlinedButton.icon(
                        // Takes over from Next for the remote.
                        autofocus: tvLayout,
                        onPressed: () => _go(0, count),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(ReelishIcons.restart),
                        label: const Text('Replay'),
                      )
                    else if (tvLayout)
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: () => _go(_index + 1, count),
                        icon: const Icon(ReelishIcons.chevronRight),
                        label: const Text('Next'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // The slides. Each lays out stacked on a phone and side by side when wide.

  Widget _split(_SlideScope s, Widget visual, Widget words) => s.wide
      ? Row(
          children: [
            Expanded(child: Center(child: visual)),
            SizedBox(width: AppSpace.xl * s.scale),
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: words),
            ),
          ],
        )
      : Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            visual,
            SizedBox(height: AppSpace.xl * s.scale),
            words,
          ],
        );

  Widget _words(
    _SlideScope s, {
    required String eyebrow,
    required String headline,
    String? body,
    Color? color,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: s.wide
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      Text(
        eyebrow,
        style: WrappedType.eyebrow(s.scale, color ?? WrappedPalette.coral),
      ),
      SizedBox(height: AppSpace.sm * s.scale),
      Text(
        headline,
        textAlign: s.wide ? TextAlign.start : TextAlign.center,
        style: WrappedType.headline(s.scale),
      ),
      if (body != null) ...[
        SizedBox(height: AppSpace.sm * s.scale),
        Text(
          body,
          textAlign: s.wide ? TextAlign.start : TextAlign.center,
          style: WrappedType.body(s.scale),
        ),
      ],
    ],
  );

  /// The Reel with [value] counting up while the slide is on screen.
  /// [year] is shown as it is, not counted up or grouped ("2026"); [glyph]
  /// takes the number's place.
  Widget _reel(
    _SlideScope s,
    WrappedPalette palette,
    int value,
    String unit, {
    bool year = false,
    IconData? glyph,
  }) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: s.turns,
      builder: (context, child) => WrappedReel(
        size: (s.wide ? 300 : 230) * s.scale,
        palette: palette,
        turns: s.turns.value,
        child: child!,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null)
            Icon(glyph, size: 96, color: Colors.white)
          else if (year)
            Text('$value', style: WrappedType.hero(1))
          else
            _CountUp(
              value: value,
              active: s.active,
              style: WrappedType.hero(1),
            ),
          Text(
            unit.toUpperCase(),
            style: WrappedType.eyebrow(1.1, Colors.white),
          ),
        ],
      ),
    ),
  );

  Widget _welcome(_SlideScope s) {
    final sum = s.summary;
    return _split(
      s,
      _reel(s, WrappedPalette.premiere, sum.year, 'Wrapped', year: true),
      _words(
        s,
        eyebrow: 'REELISH WRAPPED',
        headline: 'One year. Countless stories.',
        body: [
          if (widget.preview) 'A preview of ${sum.year} so far.',
          'Here is what you watched to the end on Reelish in ${sum.year}.',
          if (sum.partial)
            'Reelish keeps synced progress for 400 days, so this covers '
                '${wrappedShortDate(sum.coveredFrom)} to 31 December.',
        ].join(' '),
      ),
    );
  }

  Widget _movies(_SlideScope s) {
    final sum = s.summary;
    final month = sum.topMonth;
    final posters = [
      for (final m in sum.movies.reversed.take(s.wide ? 8 : 6))
        if (m.poster.isNotEmpty) m.poster,
    ];
    return _split(
      s,
      _reel(s, WrappedPalette.movies, sum.movies.length, 'movies'),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: s.wide
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          _words(
            s,
            eyebrow: 'YOUR MOVIES',
            headline: sum.movies.length == 1
                ? 'One movie, start to finish.'
                : '${wrappedNumber(sum.movies.length)} movies, start to finish.',
            body: month == 0
                ? null
                : 'Your busiest month for movies and episodes was '
                      '${monthNames[month - 1]}.',
            color: WrappedPalette.movies.a,
          ),
          if (posters.isNotEmpty) ...[
            SizedBox(height: AppSpace.lg * s.scale),
            Wrap(
              spacing: 8 * s.scale,
              runSpacing: 8 * s.scale,
              alignment: s.wide ? WrapAlignment.start : WrapAlignment.center,
              children: [
                for (final p in posters)
                  WrappedArtwork(url: p, width: 52 * s.scale, aspect: 2 / 3),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _hours(_SlideScope s) {
    final sum = s.summary;
    final inHours = sum.minutes >= 60;
    return _split(
      s,
      _reel(
        s,
        WrappedPalette.hours,
        inHours ? sum.minutes ~/ 60 : sum.minutes,
        inHours ? 'hours' : 'minutes',
      ),
      _words(
        s,
        eyebrow: 'YOUR TIME',
        headline: 'Your year was made of stories.',
        body:
            'About ${wrappedNumber(sum.movieMinutes ~/ 60)} h of movies and '
            '${wrappedNumber(sum.seriesMinutes ~/ 60)} h of series. An '
            'estimate: the furthest point you reached in each movie and '
            'episode you last played this year.',
        color: WrappedPalette.hours.a,
      ),
    );
  }

  Widget _series(_SlideScope s) {
    final sum = s.summary;
    final top = sum.topSeries!;
    return _split(
      s,
      top.poster.isEmpty
          ? _reel(s, WrappedPalette.series, top.count, 'episodes')
          : WrappedArtwork(
              url: top.poster,
              width: (s.wide ? 220 : 170) * s.scale,
              aspect: 2 / 3,
            ),
      _words(
        s,
        eyebrow: 'YOUR MOST-WATCHED SERIES',
        headline: top.name,
        body: [
          '${wrappedNumber(top.count)} episode${top.count == 1 ? '' : 's'} '
              'finished.',
          'In all, ${wrappedNumber(sum.episodes)} episodes across '
              '${sum.series.length} series',
          if (sum.seasonsFinished > 0)
            'and ${sum.seasonsFinished} full '
                'season${sum.seasonsFinished == 1 ? '' : 's'}.'
          else
            '',
        ].where((t) => t.isNotEmpty).join(' '),
        color: WrappedPalette.series.a,
      ),
    );
  }

  Widget _genres(_SlideScope s) {
    final sum = s.summary;
    final most = sum.genres.first.count;
    return _split(
      s,
      _words(
        s,
        eyebrow: 'YOUR GENRES',
        headline: '${sum.genres.first.name} had you hooked.',
        body:
            'Counted once per title you finished, a series once however '
            'many episodes.',
        color: WrappedPalette.genres.a,
      ),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420 * s.scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, g) in sum.genres.indexed)
              _GenreBar(
                rank: i + 1,
                name: g.name,
                share: sum.genreTitles == 0 ? 0 : g.count / sum.genreTitles,
                fill: g.count / most,
                scale: s.scale,
                active: s.active,
              ),
          ],
        ),
      ),
    );
  }

  Widget _actors(_SlideScope s) {
    final sum = s.summary;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _words(
          s,
          eyebrow: 'YOUR FAVOURITE FACES',
          headline: 'The actors you kept coming back to.',
          body: 'In the most titles you finished.',
          color: WrappedPalette.actors.a,
        ),
        SizedBox(height: AppSpace.xl * s.scale),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpace.lg * s.scale,
          runSpacing: AppSpace.md * s.scale,
          children: [
            for (final a in sum.actors.take(s.wide ? 5 : 3))
              SizedBox(
                width: 110 * s.scale,
                child: Column(
                  children: [
                    WrappedArtwork(
                      url: a.profile,
                      width: 88 * s.scale,
                      aspect: 1,
                      circle: true,
                    ),
                    SizedBox(height: AppSpace.xs * s.scale),
                    Text(
                      a.name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: WrappedType.body(s.scale).copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${a.count} titles',
                      style: WrappedType.body(s.scale * .85),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _milestones(_SlideScope s) {
    final sum = s.summary;
    return _split(
      s,
      _words(
        s,
        eyebrow: 'YOUR MILESTONES',
        headline: 'Moments that made your year.',
        color: WrappedPalette.milestones.a,
      ),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440 * s.scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in sum.milestones.take(5))
              Padding(
                padding: EdgeInsets.only(bottom: AppSpace.md * s.scale),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64 * s.scale,
                      child: Text(
                        wrappedShortDate(m.at).toUpperCase(),
                        style: WrappedType.eyebrow(
                          s.scale,
                          WrappedPalette.milestones.a,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.label,
                            style: WrappedType.body(s.scale).copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(m.detail, style: WrappedType.body(s.scale * .9)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _persona(_SlideScope s) {
    final sum = s.summary;
    final main = sum.personas.first;
    return _split(
      s,
      _reel(
        s,
        WrappedPalette.persona,
        0,
        'Your personality',
        glyph: ReelishIcons.starFilled,
      ),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: s.wide
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          _words(
            s,
            eyebrow: "YOU'RE",
            headline: main.title,
            body: '${main.line} ${main.reason}',
            color: WrappedPalette.persona.a,
          ),
          if (sum.personas.length > 1) ...[
            SizedBox(height: AppSpace.md * s.scale),
            for (final p in sum.personas.skip(1))
              Padding(
                padding: EdgeInsets.only(bottom: AppSpace.xs * s.scale),
                child: Text(
                  'Also ${p.title}: ${p.reason}',
                  textAlign: s.wide ? TextAlign.start : TextAlign.center,
                  style: WrappedType.body(s.scale * .85),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _finale(_SlideScope s) {
    final sum = s.summary;
    final stats = [
      if (sum.movies.isNotEmpty) ('movies', sum.movies.length),
      if (sum.episodes > 0) ('episodes', sum.episodes),
      if (sum.series.isNotEmpty) ('series', sum.series.length),
      if (sum.minutes >= 60) ('hours, about', sum.minutes ~/ 60),
    ];
    // Centred when it fits, scrolling when it does not.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: _finaleBody(s, sum, stats),
        ),
      ),
    );
  }

  Widget _finaleBody(
    _SlideScope s,
    WrappedSummary sum,
    List<(String, int)> stats,
  ) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      const ReelishWordmark(height: 20),
      SizedBox(height: AppSpace.md * s.scale),
      Text(
        'Your ${sum.year} in stories',
        textAlign: TextAlign.center,
        style: WrappedType.headline(s.scale),
      ),
      SizedBox(height: AppSpace.lg * s.scale),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: AppSpace.xl * s.scale,
        runSpacing: AppSpace.md * s.scale,
        children: [
          for (final (label, value) in stats)
            Column(
              children: [
                Text(
                  wrappedNumber(value),
                  style: WrappedType.hero(s.scale * .55),
                ),
                Text(
                  label.toUpperCase(),
                  style: WrappedType.eyebrow(s.scale, Colors.white),
                ),
              ],
            ),
        ],
      ),
      SizedBox(height: AppSpace.xl * s.scale),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560 * s.scale),
        child: Text(
          'How this was counted: movies and episodes you watched to 90% '
          'or more on Reelish, on any of your devices, dated by when you '
          'finished them in your local time. Each counts once, so '
          'rewatches are not added. Hours are an estimate. Only you see '
          'this recap; nothing is shared unless you share it.',
          textAlign: TextAlign.center,
          style: WrappedType.body(s.scale * .8),
        ),
      ),
      SizedBox(height: AppSpace.sm * s.scale),
      if (!widget.preview)
        TextButton(
          onPressed: () => _load(refresh: true),
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
          child: const Text('Count again'),
        ),
    ],
  );
}

/// The slides as segments along the top.
class _Segments extends StatelessWidget {
  const _Segments({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Slide ${index + 1} of $count',
    child: Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: Container(
              height: 3,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: i <= index ? Colors.white : Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A number counting up to [value] once [active]; at once under reduced
/// motion.
class _CountUp extends StatelessWidget {
  const _CountUp({
    required this.value,
    required this.active,
    required this.style,
  });

  final int value;
  final bool active;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.resolve(
      context,
      const Duration(milliseconds: 1100),
    );
    if (!active || duration == Duration.zero) {
      return Text(wrappedNumber(value), style: style);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        wrappedNumber(v.round()),
        style: style,
        semanticsLabel: wrappedNumber(value),
      ),
    );
  }
}

class _GenreBar extends StatelessWidget {
  const _GenreBar({
    required this.rank,
    required this.name,
    required this.share,
    required this.fill,
    required this.scale,
    required this.active,
  });

  final int rank;
  final String name;

  /// Of all titles with a genre.
  final double share;

  /// Of the top genre's count.
  final double fill;
  final double scale;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.resolve(
      context,
      Duration(milliseconds: 500 + rank * 120),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Semantics(
        label: '$rank. $name, ${(share * 100).round()} percent of titles',
        excludeSemantics: true,
        child: Row(
          children: [
            SizedBox(
              width: 24 * scale,
              child: Text(
                '$rank',
                style: WrappedType.eyebrow(scale, Colors.white),
              ),
            ),
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: active ? 0 : fill, end: fill),
                duration: duration,
                curve: Curves.easeOutCubic,
                builder: (context, f, _) => Stack(
                  children: [
                    Container(
                      height: 34 * scale,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(8 * scale),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: f.clamp(.06, 1),
                      child: Container(
                        height: 34 * scale,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              WrappedPalette.genres.a,
                              WrappedPalette.genres.b,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(8 * scale),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10 * scale),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WrappedType.body(scale).copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${(share * 100).round()}%',
                              style: WrappedType.body(
                                scale * .9,
                              ).copyWith(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The share sheet for one card: format, what to show, a live preview of
/// the exact image, and Share or Save.
Future<void> showWrappedShare(
  BuildContext context, {
  required WrappedSummary summary,
  required WrappedCardKind kind,
  required String displayName,
  required bool canSave,
}) {
  final sheet = _ShareSheet(
    summary: summary,
    kind: kind,
    displayName: displayName,
    canSave: canSave,
  );
  if (DeviceCapabilities.usesTvLayout) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF15141C),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
          child: sheet,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF15141C),
    builder: (_) => sheet,
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.summary,
    required this.kind,
    required this.displayName,
    required this.canSave,
  });

  final WrappedSummary summary;
  final WrappedCardKind kind;
  final String displayName;
  final bool canSave;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _boundary = GlobalKey();
  WrappedCardFormat _format = WrappedCardFormat.story;
  bool _name = false;
  bool _artwork = true;
  bool _link = true;
  bool _busy = false;

  WrappedCardOptions get _options => WrappedCardOptions(
    name: _name ? widget.displayName : '',
    artwork: _artwork,
    link: _link,
  );

  String get _fileName =>
      'reelish-wrapped-${widget.summary.year}-${widget.kind.name}-'
      '${_format.name}';

  /// The card's images loaded, so the export is complete: always the
  /// Reelish wordmark (a card must never go out without its brand), and
  /// the artwork when shown.
  Future<void> _ready() async {
    await precacheImage(const AssetImage(BrandAssets.wordLogo), context);
    if (!mounted) return;
    for (final url
        in _artwork
            ? wrappedCardImages(widget.kind, widget.summary)
            : const <String>[]) {
      try {
        await precacheImage(
          NetworkImage(url),
          context,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {
        // That image stays a plain tile.
      }
      if (!mounted) return;
    }
    // One more frame, so what was loaded is painted.
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _export({required bool share}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    String message;
    try {
      await _ready();
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('No card.');
      final png = await WrappedExport.capture(boundary);
      if (share) {
        final text = [
          'My ${widget.summary.year} on Reelish #ReelishWrapped',
          if (_link) WrappedCardOptions.linkText,
        ].join(' ');
        final ok = await WrappedExport.share(png, _fileName, text: text);
        message = ok ? '' : 'Sharing did not open. Try again.';
      } else {
        final where = await WrappedExport.save(png, _fileName);
        message = where == null
            ? 'The image could not be saved. Try again.'
            : 'Saved to $where.';
      }
    } catch (_) {
      message = 'The image could not be made. Try again.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (message.isNotEmpty) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = FittedBox(
      child: RepaintBoundary(
        key: _boundary,
        child: WrappedCard(
          kind: widget.kind,
          summary: widget.summary,
          format: _format,
          options: _options,
        ),
      ),
    );
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Share a card',
          style: TextStyle(
            color: Colors.white,
            fontSize: AppTextSize.titleLarge,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          'Only this image leaves Reelish, and only when you share or save '
          'it.',
          style: TextStyle(color: Colors.white.withValues(alpha: .7)),
        ),
        const SizedBox(height: AppSpace.md),
        SegmentedButton<WrappedCardFormat>(
          segments: [
            for (final f in WrappedCardFormat.values)
              ButtonSegment(value: f, label: Text(f.label)),
          ],
          selected: {_format},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _format = v.first),
        ),
        if (widget.displayName.trim().isNotEmpty)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show my name'),
            subtitle: Text(widget.displayName),
            value: _name,
            onChanged: (v) => setState(() => _name = v),
          ),
        if (wrappedCardImages(widget.kind, widget.summary).isNotEmpty)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Posters and photos'),
            value: _artwork,
            onChanged: (v) => setState(() => _artwork = v),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Where to get Reelish'),
          value: _link,
          onChanged: (v) => setState(() => _link = v),
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            if (WrappedExport.canShare)
              FilledButton.icon(
                autofocus: true,
                onPressed: _busy ? null : () => _export(share: true),
                icon: const Icon(ReelishIcons.share),
                label: const Text('Share'),
              ),
            if (widget.canSave)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _export(share: false),
                icon: const Icon(ReelishIcons.download),
                label: const Text('Save image'),
              ),
          ],
        ),
      ],
    );
    return Theme(
      data: GlassTheme.player(tv: DeviceCapabilities.isTv),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 640
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 240, height: 420, child: preview),
                    const SizedBox(width: AppSpace.lg),
                    Expanded(child: SingleChildScrollView(child: controls)),
                  ],
                )
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      SizedBox(height: 340, child: preview),
                      const SizedBox(height: AppSpace.md),
                      controls,
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
