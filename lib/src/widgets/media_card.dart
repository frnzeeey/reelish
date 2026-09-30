import 'dart:async';

import 'package:flutter/material.dart';
import 'package:feather_icon_font/feather_icon_font.dart';
import '../models/media_item.dart';
import '../theme/glass_theme.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progress = 0,
    this.onFavorite,
  });

  final MediaItem item;
  final FutureOr<void> Function() onTap;
  final double progress;
  final VoidCallback? onFavorite;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _navigating = false;
  bool _pressed = false;

  Future<void> _activate() async {
    if (_navigating) return;
    _navigating = true;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    setState(() => _pressed = true);
    await Future<void>.delayed(Duration(milliseconds: reduceMotion ? 1 : 240));
    if (!mounted) return;
    try {
      await widget.onTap();
    } finally {
      if (mounted) {
        setState(() {
          _pressed = false;
          _navigating = false;
        });
      }
    }
  }

  Widget _frosted({required Widget child, double radius = 14}) {
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xA619202D),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: .24)),
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: surface,
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
          border: Border.all(color: Colors.white.withValues(alpha: .14)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: Material(
            color: GlassTheme.surface,
            child: InkWell(
              onTap: _activate,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: _pressed ? 1 : 0),
                duration: Duration(milliseconds: reduceMotion ? 1 : 240),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Transform.translate(
                  offset: Offset(0, reduceMotion ? 0 : -16 * value),
                  child: Opacity(opacity: 1 - value, child: child),
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
                        errorBuilder: (_, __, ___) => const ColoredBox(
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
                              onPressed: widget.onFavorite,
                              icon: const Icon(FeatherIcons.heart, size: 17),
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
                                    const Icon(
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
    );
  }
}
