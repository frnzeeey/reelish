// The share cards of Reelish Wrapped: one highlight each, in a story
// (9:16), portrait (4:5) or square (1:1) frame, drawn at a fixed 360-wide
// logical size and exported at three times that (1080 px wide). Every
// number comes from the year's WrappedSummary; nothing is added. A card
// carries no account id, no watchlist and, unless the viewer turns it on,
// no name.
import 'package:flutter/material.dart';

import '../widgets/brand_logo.dart';
import 'wrapped_stats.dart';
import 'wrapped_visuals.dart';

enum WrappedCardKind { hours, movies, genre, actors, series, persona, summary }

enum WrappedCardFormat {
  story('Story', 9 / 16),
  portrait('Portrait', 4 / 5),
  square('Square', 1);

  const WrappedCardFormat(this.label, this.aspect);
  final String label;

  /// Width over height.
  final double aspect;

  static const width = 360.0;
  Size get size => Size(width, width / aspect);
}

/// What the viewer chose to put on a card.
class WrappedCardOptions {
  const WrappedCardOptions({
    this.name = '',
    this.artwork = true,
    this.link = true,
  });

  /// Shown when not empty; off by default.
  final String name;

  /// Posters and portraits.
  final bool artwork;

  /// "Get Reelish" and where.
  final bool link;

  static const linkText = 'github.com/frnzeeey/reelish';
}

/// Which cards [summary] can make: only those with real numbers.
List<WrappedCardKind> wrappedCardsFor(WrappedSummary summary) => [
  if (summary.minutes >= 60) WrappedCardKind.hours,
  if (summary.movies.isNotEmpty) WrappedCardKind.movies,
  if (summary.genres.isNotEmpty) WrappedCardKind.genre,
  if (summary.actors.isNotEmpty) WrappedCardKind.actors,
  if (summary.topSeries != null) WrappedCardKind.series,
  if (summary.personas.isNotEmpty) WrappedCardKind.persona,
  if (!summary.isEmpty) WrappedCardKind.summary,
];

/// The artwork a card shows, so it can be loaded before export.
List<String> wrappedCardImages(WrappedCardKind kind, WrappedSummary summary) =>
    switch (kind) {
      WrappedCardKind.movies => [
        for (final m in summary.movies.reversed.take(6))
          if (m.poster.isNotEmpty) m.poster,
      ],
      WrappedCardKind.actors => [
        for (final a in summary.actors.take(3))
          if (a.profile.isNotEmpty) a.profile,
      ],
      WrappedCardKind.series => [
        if (summary.topSeries?.poster.isNotEmpty ?? false)
          summary.topSeries!.poster,
      ],
      _ => const [],
    };

class WrappedCard extends StatelessWidget {
  const WrappedCard({
    super.key,
    required this.kind,
    required this.summary,
    this.format = WrappedCardFormat.story,
    this.options = const WrappedCardOptions(),
  });

  final WrappedCardKind kind;
  final WrappedSummary summary;
  final WrappedCardFormat format;
  final WrappedCardOptions options;

  WrappedPalette get _palette => switch (kind) {
    WrappedCardKind.hours => WrappedPalette.hours,
    WrappedCardKind.movies => WrappedPalette.movies,
    WrappedCardKind.genre => WrappedPalette.genres,
    WrappedCardKind.actors => WrappedPalette.actors,
    WrappedCardKind.series => WrappedPalette.series,
    WrappedCardKind.persona => WrappedPalette.persona,
    WrappedCardKind.summary => WrappedPalette.finale,
  };

  bool get _roomy => format == WrappedCardFormat.story;

  @override
  Widget build(BuildContext context) {
    final size = format.size;
    final palette = _palette;
    return SizedBox.fromSize(
      size: size,
      child: ClipRect(
        child: WrappedBackdrop(
          palette: palette,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, _roomy ? 34 : 22, 24, 20),
            child: DefaultTextStyle(
              style: const TextStyle(fontFamily: 'Montserrat'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const ReelishWordmark(height: 14),
                      const Spacer(),
                      Text(
                        'WRAPPED ${summary.year}',
                        style: WrappedType.eyebrow(.9, palette.a),
                      ),
                    ],
                  ),
                  Expanded(child: _body(palette)),
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    final name = options.name.trim();
    final small = TextStyle(
      color: Colors.white.withValues(alpha: .7),
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      letterSpacing: .3,
    );
    // A recap that could not see the whole year says so on every card.
    final since = summary.partial
        ? ' (from ${wrappedShortDate(summary.coveredFrom)})'
        : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            name.isEmpty
                ? 'My ${summary.year} in movies & series$since'
                : '$name · ${summary.year}$since',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small,
          ),
        ),
        if (options.link)
          Text(
            'Get Reelish · ${WrappedCardOptions.linkText}',
            style: small.copyWith(fontSize: 9),
          ),
      ],
    );
  }

  Widget _reel(WrappedPalette palette, String number, String unit) =>
      WrappedReel(
        size: _roomy ? 200 : 150,
        palette: palette,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(number, style: WrappedType.hero(1)),
            Text(
              unit.toUpperCase(),
              style: WrappedType.eyebrow(1.1, Colors.white),
            ),
          ],
        ),
      );

  Widget _text(String headline, String body, {bool center = false}) => Column(
    crossAxisAlignment: center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        headline,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: WrappedType.headline(_roomy ? .95 : .78),
      ),
      const SizedBox(height: 8),
      Text(
        body,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: WrappedType.body(_roomy ? .9 : .8),
      ),
    ],
  );

  Widget _body(WrappedPalette palette) {
    final s = summary;
    switch (kind) {
      case WrappedCardKind.hours:
        final hours = s.minutes ~/ 60;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _reel(palette, wrappedNumber(hours), hours == 1 ? 'hour' : 'hours'),
            SizedBox(height: _roomy ? 28 : 14),
            _text(
              'My year was made of stories.',
              'About ${wrappedNumber(hours)} hours of movies and series on '
                  'Reelish in ${s.year}.',
              center: true,
            ),
          ],
        );
      case WrappedCardKind.movies:
        final posters = options.artwork
            ? wrappedCardImages(kind, s).take(_roomy ? 6 : 3).toList()
            : const <String>[];
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _reel(palette, wrappedNumber(s.movies.length), 'movies'),
            SizedBox(height: _roomy ? 22 : 12),
            _text(
              s.movies.length == 1
                  ? 'One movie, start to finish.'
                  : '${wrappedNumber(s.movies.length)} movies, start to finish.',
              'Every one watched to the end in ${s.year}.',
              center: true,
            ),
            if (posters.isNotEmpty) ...[
              SizedBox(height: _roomy ? 22 : 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final p in posters)
                    WrappedArtwork(url: p, width: 62, aspect: 2 / 3),
                ],
              ),
            ],
          ],
        );
      case WrappedCardKind.genre:
        final top = s.genres.first;
        final pct = s.genreTitles == 0
            ? 0
            : (top.count * 100 / s.genreTitles).round();
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MY TOP GENRE', style: WrappedType.eyebrow(1, palette.a)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(top.name, style: WrappedType.hero(_roomy ? .78 : .6)),
            ),
            const SizedBox(height: 14),
            _text(
              '${top.name} had me hooked.',
              'It was in $pct% of the titles I finished in ${s.year}.',
            ),
            const SizedBox(height: 18),
            for (final (i, g) in s.genres.take(_roomy ? 5 : 3).indexed)
              _bar(i + 1, g.name, g.count, s.genres.first.count, palette),
          ],
        );
      case WrappedCardKind.actors:
        final actors = s.actors.take(3).toList();
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MOST-WATCHED FACES',
              style: WrappedType.eyebrow(1, palette.a),
            ),
            const SizedBox(height: 14),
            for (final a in actors)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    if (options.artwork) ...[
                      WrappedArtwork(
                        url: a.profile,
                        width: _roomy ? 64 : 48,
                        aspect: 1,
                        circle: true,
                      ),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WrappedType.headline(.7),
                          ),
                          Text(
                            'In ${a.count} titles I finished',
                            style: WrappedType.body(.8),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      case WrappedCardKind.series:
        final top = s.topSeries!;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (options.artwork && top.poster.isNotEmpty) ...[
              WrappedArtwork(
                url: top.poster,
                width: _roomy ? 150 : 96,
                aspect: 2 / 3,
              ),
              SizedBox(height: _roomy ? 22 : 12),
            ],
            _text(
              top.name,
              '${wrappedNumber(top.count)} episode${top.count == 1 ? '' : 's'} '
              'finished: my most-watched series of ${s.year}.',
              center: true,
            ),
          ],
        );
      case WrappedCardKind.persona:
        final p = s.personas.first;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("I'M", style: WrappedType.eyebrow(1.1, palette.a)),
            const SizedBox(height: 6),
            Text(p.title, style: WrappedType.hero(_roomy ? .5 : .4)),
            const SizedBox(height: 14),
            // The sharer's own voice; the reason, with its numbers, stays
            // on the slide.
            Text(p.cardLine, style: WrappedType.headline(_roomy ? .7 : .6)),
            if (s.personas.length > 1) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in s.personas.skip(1).take(3)) _chip(t.title),
                ],
              ),
            ],
          ],
        );
      case WrappedCardKind.summary:
        final cells = [
          if (s.movies.isNotEmpty) ('Movies', wrappedNumber(s.movies.length)),
          if (s.episodes > 0) ('Episodes', wrappedNumber(s.episodes)),
          if (s.minutes >= 60) ('Hours, about', wrappedNumber(s.minutes ~/ 60)),
          if (s.series.isNotEmpty) ('Series', wrappedNumber(s.series.length)),
        ];
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A story has room for the Reel: every title finished.
            if (_roomy) ...[
              Center(
                child: _reel(
                  palette,
                  wrappedNumber(s.finished),
                  s.finished == 1 ? 'story' : 'stories',
                ),
              ),
              const SizedBox(height: 28),
            ],
            Text(
              'MY YEAR IN STORIES',
              style: WrappedType.eyebrow(1, palette.a),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (label, value) in cells)
                  SizedBox(
                    width: 144,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value, style: WrappedType.hero(_roomy ? .5 : .4)),
                        Text(
                          label.toUpperCase(),
                          style: WrappedType.eyebrow(.8, Colors.white),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (s.genres.isNotEmpty || s.personas.isNotEmpty) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (s.genres.isNotEmpty)
                    _chip('Top genre: ${s.genres.first.name}'),
                  if (s.personas.isNotEmpty) _chip(s.personas.first.title),
                ],
              ),
            ],
          ],
        );
    }
  }

  Widget _bar(int rank, String name, int count, int most, WrappedPalette p) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: Text('$rank', style: WrappedType.eyebrow(1, Colors.white)),
            ),
            Expanded(
              child: Stack(
                children: [
                  Container(
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: most == 0 ? 0 : (count / most).clamp(.08, 1),
                    child: Container(
                      height: 22,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [p.a, p.b]),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(99),
      color: Colors.white.withValues(alpha: .1),
      border: Border.all(color: Colors.white.withValues(alpha: .22)),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
