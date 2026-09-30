import 'dart:async';

import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/storage_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/media_card.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.storage,
    required this.onPlay,
    this.refreshToken = 0,
  });
  final StorageService storage;
  final ValueChanged<MediaItem> onPlay;
  final int refreshToken;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<MediaItem> _history = [], _favorites = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) unawaited(_load());
  }

  Future<void> _load() async {
    final values = await Future.wait([
      widget.storage.history(),
      widget.storage.favorites(),
    ]);
    if (mounted)
      setState(() {
        _history = values[0];
        _favorites = values[1];
        _loading = false;
      });
  }

  Widget _row(String title, List<MediaItem> items, {bool favorite = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Text(
              'Nothing saved here yet.',
              style: TextStyle(color: GlassTheme.muted),
            ),
          if (items.isNotEmpty)
            SizedBox(
              height: 264,
              child: ListView.builder(
                key: PageStorageKey<String>('library-row-$title'),
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Stack(
                      children: [
                        MediaCard(
                          item: item,
                          progress: item.resumeMs > 0 ? 0.3 : 0,
                          onTap: () => widget.onPlay(item),
                          onFavorite: favorite
                              ? () async {
                                  await widget.storage.toggleFavorite(item);
                                  await _load();
                                }
                              : null,
                        ),
                        if (!favorite)
                          Positioned(
                            top: 5,
                            right: 5,
                            child: Material(
                              color: Colors.black.withValues(alpha: .72),
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: 'Remove from watch history',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () async {
                                  await widget.storage.removeHistory(item);
                                  await _load();
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
      );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Your library'),
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                _row(
                  'Continue watching',
                  _history.where((e) => e.resumeMs > 0).toList(),
                ),
                _row('Watch history', _history),
                _row('Favorites', _favorites, favorite: true),
              ],
            ),
          ),
  );
}
