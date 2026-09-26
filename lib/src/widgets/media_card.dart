import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../theme/glass_theme.dart';

class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progress = 0,
    this.onFavorite,
  });
  final MediaItem item;
  final VoidCallback onTap;
  final double progress;
  final VoidCallback? onFavorite;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 146,
    height: 264,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(19),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 14,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(19),
                    child: item.poster.isEmpty
                        ? Container(
                            color: const Color(0xFF202839),
                            child: const Icon(
                              Icons.movie_outlined,
                              size: 36,
                              color: Colors.white30,
                            ),
                          )
                        : Image.network(
                            item.poster,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: const Color(0xFF202839),
                              child: const Icon(Icons.movie_outlined),
                            ),
                          ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0x44000000)],
                          stops: [.55, 1],
                        ),
                      ),
                    ),
                  ),
                  if (progress > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        value: progress.clamp(0, 1),
                        minHeight: 3,
                        color: GlassTheme.cyan,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        item.type == 'series' ? 'SERIES' : 'FILM',
                        style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  if (onFavorite != null)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        onPressed: onFavorite,
                        icon: const Icon(Icons.favorite_border, size: 17),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            [
              item.year,
              item.rating.isEmpty ? '' : '★ ${item.rating}',
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            style: const TextStyle(color: GlassTheme.muted, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}
