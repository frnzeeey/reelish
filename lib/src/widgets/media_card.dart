import 'dart:async';
import 'package:flutter/material.dart';
import 'package:feather_icon_font/feather_icon_font.dart';
import '../models/media_item.dart';
import '../theme/glass_theme.dart';
import 'liquid_glass.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progress = 0,
    this.onFavorite,
    this.isFavorite = false,
  });

  final MediaItem item;
  final FutureOr<void> Function() onTap;
  final double progress;
  final VoidCallback? onFavorite;
  final bool isFavorite;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _navigating = false;
  late bool _isFavorite;
  DateTime? _lastActivationAt;
  final ValueNotifier<bool> _pressed = ValueNotifier(false);
  final ValueNotifier<int> _heartPressCount = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.isFavorite;
  }

  @override
  void didUpdateWidget(covariant MediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isFavorite != widget.isFavorite) {
      _isFavorite = widget.isFavorite;
    }
  }

  void _onFavoritePressed() {
    setState(() => _isFavorite = !_isFavorite);
    if (!MediaQuery.disableAnimationsOf(context)) {
      _heartPressCount.value++;
    }
    widget.onFavorite?.call();
  }

  Future<void> _activate() async {
    final now = DateTime.now();
    if (_navigating ||
        (_lastActivationAt != null &&
            now.difference(_lastActivationAt!) <
                const Duration(milliseconds: 350))) {
      return;
    }
    _lastActivationAt = now;
    _navigating = true;
    try {
      await widget.onTap();
    } finally {
      if (mounted) {
        _pressed.value = false;
        _navigating = false;
      }
    }
  }

  @override
  void dispose() {
    _pressed.dispose();
    _heartPressCount.dispose();
    super.dispose();
  }

  Widget _frosted({required Widget child, double radius = 14}) {
    return LiquidGlass(
      quality: LiquidGlassQuality.balanced,
      blurSigma: 10,
      opacity: .62,
      borderRadius: radius,
      tintColor: const Color(0xFF242833),
      showShadow: false,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final progress = widget.progress;
    final imagePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return SizedBox(
      width: 146,
      height: 264,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: .28),
              Colors.white.withValues(alpha: .07),
              GlassTheme.primary.withValues(alpha: .22),
            ],
            stops: const [0, .58, 1],
          ),
          boxShadow: [
            const BoxShadow(
              color: Color(0x66000000),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: .07),
              blurRadius: 10,
              spreadRadius: .5,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19),
            child: Material(
              color: GlassTheme.surface,
              child: InkWell(
                onTap: _activate,
                onTapDown: (_) => _pressed.value = true,
                onTapCancel: () {
                  if (_pressed.value && !_navigating) _pressed.value = false;
                },
                child: ValueListenableBuilder<bool>(
                  valueListenable: _pressed,
                  builder: (context, pressed, child) =>
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 1, end: pressed ? .985 : 1),
                        duration: Duration(
                          milliseconds: reduceMotion ? 1 : 100,
                        ),
                        curve: Curves.easeOutCubic,
                        builder: (context, scale, child) =>
                            Transform.scale(scale: scale, child: child),
                        child: child,
                      ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (item.poster.isEmpty)
                        const ColoredBox(
                          color: GlassTheme.elevatedSurface,
                          child: Icon(
                            FeatherIcons.film,
                            size: 36,
                            color: Colors.white30,
                          ),
                        )
                      else
                        Image.network(
                          item.poster,
                          fit: BoxFit.cover,
                          cacheWidth: (146 * imagePixelRatio).round(),
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: GlassTheme.elevatedSurface,
                            child: Icon(FeatherIcons.film),
                          ),
                        ),
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x22000000),
                                Colors.transparent,
                                Color(0x55000000),
                              ],
                              stops: [0, .45, 1],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _frosted(
                          radius: 30,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: Text(
                              item.type == 'series' ? 'SERIES' : 'FILM',
                              style: const TextStyle(
                                fontSize: 8,
                                letterSpacing: .5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.onFavorite != null)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: _frosted(
                            radius: 30,
                            child: SizedBox(
                              width: 35,
                              height: 35,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                onPressed: _onFavoritePressed,
                                icon: ValueListenableBuilder<int>(
                                  valueListenable: _heartPressCount,
                                  builder: (context, pressCount, child) {
                                    if (pressCount == 0 || reduceMotion) {
                                      return child!;
                                    }
                                    return TweenAnimationBuilder<double>(
                                      key: ValueKey(pressCount),
                                      tween: Tween(begin: .72, end: 1),
                                      duration: const Duration(
                                        milliseconds: 420,
                                      ),
                                      curve: Curves.elasticOut,
                                      builder: (context, progress, child) {
                                        return Transform.scale(
                                          scale: progress,
                                          child: child,
                                        );
                                      },
                                      child: child,
                                    );
                                  },
                                  child: Icon(
                                    _isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    size: 18,
                                    color: _isFavorite
                                        ? GlassTheme.primary
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: progress > 0 ? 11 : 9,
                        child: _frosted(
                          radius: 15,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              9,
                              8,
                              9,
                              progress > 0 ? 6 : 8,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (item.year.isNotEmpty)
                                      Flexible(
                                        child: Text(
                                          item.year,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    if (item.rating.isNotEmpty) ...[
                                      if (item.year.isNotEmpty)
                                        const SizedBox(width: 7),
                                      Icon(
                                        FeatherIcons.star,
                                        size: 10,
                                        color: GlassTheme.primary,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        item.rating,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (progress > 0) ...[
                                  const SizedBox(height: 7),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: progress.clamp(0, 1),
                                      minHeight: 3,
                                      color: GlassTheme.primary,
                                      backgroundColor: Colors.white24,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
