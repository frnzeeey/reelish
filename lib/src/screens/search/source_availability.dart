// Whether the viewer's enabled providers list sources for a movie, shown
// under Universal Search's top result. Only what providers supplied is
// shown, and a source listed is not a source tried: playing still goes
// through the title's own page.

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../search/playback_availability.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';

class SourceAvailabilityPanel extends StatelessWidget {
  const SourceAvailabilityPanel({
    super.key,
    required this.availability,
    required this.item,
  });

  final PlaybackAvailability availability;
  final MediaItem item;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: availability,
    builder: (context, _) {
      final result = availability.of(item);
      final muted = TextStyle(
        color: GlassTheme.muted,
        fontSize: AppTextSize.caption,
      );
      Widget action(String label) => TextButton.icon(
        onPressed: () => availability.check(item, again: result != null),
        icon: const Icon(ReelishIcons.refresh, size: 18),
        label: Text(label),
      );
      if (result == null) {
        return Row(
          children: [
            action('Check sources'),
            Flexible(child: Text('Asks your enabled providers.', style: muted)),
          ],
        );
      }
      final providers = result.providers;
      final Widget headline;
      switch (result.state) {
        case AvailabilityState.checking:
          headline = Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpace.sm),
              Text('Asking your providers…', style: muted),
            ],
          );
        case AvailabilityState.found:
          headline = _Line(
            icon: ReelishIcons.checkCircle,
            color: GlassTheme.success,
            text: result.finished
                ? '${_count(result.sourceCount, 'source')} from '
                      '${_count(providers.length, 'provider')}'
                : '${_count(result.sourceCount, 'source')} so far…',
          );
        case AvailabilityState.none:
          headline = _Line(
            icon: ReelishIcons.searchOff,
            color: GlassTheme.muted,
            text: 'Your providers listed no sources for this movie.',
          );
        case AvailabilityState.timedOut:
          headline = _Line(
            icon: ReelishIcons.hourglass,
            color: GlassTheme.muted,
            text: 'Your providers didn’t answer in time.',
          );
        case AvailabilityState.failed:
          headline = _Line(
            icon: ReelishIcons.warning,
            color: GlassTheme.danger,
            text: 'Couldn’t ask your providers.',
          );
      }
      return Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            headline,
            for (final provider in providers.take(5))
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  [
                    provider.provider,
                    _count(provider.count, 'source'),
                    if (provider.qualities.isNotEmpty)
                      (provider.qualities.toList()..sort()).take(4).join(', '),
                    if (provider.torrents > 0) 'torrent',
                    if (provider.withSubtitles > 0) 'subtitles',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.caption,
                  ),
                ),
              ),
            if (providers.length > 5)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  'and ${_count(providers.length - 5, 'more provider')}',
                  style: muted,
                ),
              ),
            if (result.state == AvailabilityState.found)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4),
                child: Text(
                  'Listed by providers, not tried yet: a source can still '
                  'fail to play.',
                  style: muted,
                ),
              ),
            if (result.finished) action('Check again'),
          ],
        ),
      );
    },
  );

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: AppSpace.xs),
      Flexible(
        child: Text(
          text,
          style: TextStyle(
            color: GlassTheme.textPrimary,
            fontSize: AppTextSize.label,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}
