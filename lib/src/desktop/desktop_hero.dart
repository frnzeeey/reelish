import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../theme/glass_theme.dart';
import 'desktop_widgets.dart';

/// The featured titles at the top of desktop Home: a wide backdrop with the
/// title, synopsis and actions. Rotates every 8 s, pauses while the pointer
/// is over it, and can be stepped with the dots.
class DesktopHero extends StatefulWidget {
  const DesktopHero({
    super.key,
    required this.items,
    required this.onPlay,
    required this.onDetails,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final List<MediaItem> items;

  /// Movies start playback; series open their episodes.
  final ValueChanged<MediaItem> onPlay;
  final ValueChanged<MediaItem> onDetails;
  final bool Function(MediaItem item) isFavorite;
  final Future<bool> Function(MediaItem item) onToggleFavorite;

  @override
  State<DesktopHero> createState() => _DesktopHeroState();
}

class _DesktopHeroState extends State<DesktopHero> {
  static const _interval = Duration(seconds: 8);
  int _index = 0;
  bool _hovered = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant DesktopHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.items.length) _index = 0;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || _hovered || widget.items.length < 2) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      setState(() => _index = (_index + 1) % widget.items.length);
    });
  }

  void _show(int index) {
    setState(() => _index = index);
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final item = widget.items[_index];
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);
        final height = (viewport.height * .58).clamp(340.0, 680.0);
        final width = constraints.maxWidth;
        return MouseRegion(
          onEnter: (_) => _hovered = true,
          onExit: (_) => _hovered = false,
          child: SizedBox(
            height: height,
            width: width,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: desktopMotion(context, 600),
                  child: _Backdrop(
                    key: ValueKey('${item.type}:${item.id}'),
                    item: item,
                    width: width,
                  ),
                ),
                Positioned(
                  left: DesktopMetrics.pagePadding,
                  bottom: 48,
                  width: (width * .48).clamp(420.0, 720.0),
                  child: AnimatedSwitcher(
                    duration: desktopMotion(context, 420),
                    // Old text fades out before the new one fades in, so the
                    // two titles never overlap.
                    switchInCurve: const Interval(.5, 1),
                    switchOutCurve: const Interval(.5, 1),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomLeft,
                      children: [...previous, ?current],
                    ),
                    child: _HeroText(
                      key: ValueKey('text:${item.type}:${item.id}'),
                      item: item,
                      favorite: widget.isFavorite(item),
                      onPlay: () => widget.onPlay(item),
                      onDetails: () => widget.onDetails(item),
                      onToggleFavorite: () async {
                        await widget.onToggleFavorite(item);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                if (widget.items.length > 1)
                  Positioned(
                    right: DesktopMetrics.pagePadding,
                    bottom: 56,
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          _Dot(
                            active: i == _index,
                            label: 'Show ${widget.items[i].name}',
                            onTap: () => _show(i),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({super.key, required this.item, required this.width});

  final MediaItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final image = item.background.isNotEmpty ? item.background : item.poster;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: GlassTheme.surface),
        if (image.isNotEmpty)
          Image.network(
            image,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round(),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        // Text side darkened for contrast; the bottom fades into the page.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xF20B0B0F), Color(0x990B0B0F), Color(0x000B0B0F)],
              stops: [0, .38, .72],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Solid before the edge, so the image's last pixel row never
              // shows as a line.
              colors: [
                Color(0x000B0B0F),
                Color(0x000B0B0F),
                GlassTheme.background,
                GlassTheme.background,
              ],
              stops: [0, .6, .95, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _HeroText extends StatelessWidget {
  const _HeroText({
    super.key,
    required this.item,
    required this.favorite,
    required this.onPlay,
    required this.onDetails,
    required this.onToggleFavorite,
  });

  final MediaItem item;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final series = item.type == 'series';
    final meta = [
      if (item.year.isNotEmpty) item.year,
      series ? 'Series' : 'Movie',
      if (item.rating.isNotEmpty) '★ ${item.rating}',
    ].join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: GlassTheme.primary.withValues(alpha: .4)),
          ),
          child: Text(
            'REELISH SPOTLIGHT',
            style: TextStyle(
              color: GlassTheme.coralBright,
              fontSize: 11,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          item.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 46,
            height: 1.05,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          meta,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Colors.white70,
          ),
        ),
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            item.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Colors.white70,
            ),
          ),
        ],
        const SizedBox(height: 22),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onPlay,
              style: FilledButton.styleFrom(
                backgroundColor: GlassTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 18,
                ),
              ),
              icon: Icon(
                series ? Symbols.view_list_rounded : Symbols.play_arrow_rounded,
                fill: 1,
              ),
              label: Text(
                series ? 'Episodes' : 'Play',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onDetails,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: .08),
                side: BorderSide(color: Colors.white.withValues(alpha: .3)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 18,
                ),
              ),
              icon: const Icon(Symbols.info_rounded),
              label: const Text(
                'More info',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton.outlined(
              tooltip: favorite ? 'Remove from My list' : 'Add to My list',
              onPressed: onToggleFavorite,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: .08),
                side: BorderSide(color: Colors.white.withValues(alpha: .3)),
                padding: const EdgeInsets.all(14),
              ),
              icon: Icon(
                favorite ? Symbols.check_rounded : Symbols.add_rounded,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active, required this.label, required this.onTap});

  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: AnimatedContainer(
          duration: desktopMotion(context, 220),
          width: active ? 26 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active
                ? GlassTheme.primary
                : Colors.white.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    ),
  );
}
