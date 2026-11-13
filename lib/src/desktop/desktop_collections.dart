// Collections on Windows: the library's Collections section (smart
// collections, folders and the viewer's collections, each with an options
// button and a right-click menu) and the page each opens, a poster grid
// with Sort and Options in its header. Esc goes back, as on details pages.

import 'dart:async';

import 'package:flutter/material.dart';

import '../collections/collection_models.dart';
import '../collections/collection_store.dart';
import '../collections/smart_collections.dart';
import '../models/media_item.dart';
import '../navigation/app_transitions.dart';
import '../services/storage_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../viewmodels/library_view_model.dart';
import '../widgets/collections/collection_actions.dart';
import '../widgets/collections/collection_cover.dart';
import 'desktop_widgets.dart';

/// Tile width in the library's Collections row.
const _tileWidth = 170.0;

/// The library's Collections section.
class DesktopCollectionsSection extends StatelessWidget {
  const DesktopCollectionsSection({
    super.key,
    required this.model,
    required this.storage,
    required this.onOpen,
    this.isFavorite,
    this.onToggleFavorite,
  });

  final LibraryViewModel model;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;
  final Future<void> Function(MediaItem item)? onToggleFavorite;

  void _open(BuildContext context, CollectionTarget target) => unawaited(
    DesktopCollectionPage.open(
      context,
      target,
      storage: storage,
      onOpen: onOpen,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
    ),
  );

  Future<void> _create(BuildContext context) async {
    final created = await CollectionActions.createAny(
      context,
      model.collectionStore,
    );
    if (created is MediaCollection && context.mounted) {
      _open(context, CustomTarget(created.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = model.collections;
    final store = model.collectionStore;
    final tiles = <Widget>[
      for (final kind in SmartCollection.values)
        DesktopCollectionTile(
          title: kind.label,
          caption: _count(model.smart(kind).length, 'title'),
          icon: ReelishIcons.sparkle,
          posters: [
            for (final item in model.smart(kind).take(4))
              if (item.poster.isNotEmpty) item.poster,
          ],
          onOpen: () => _open(context, SmartTarget(kind)),
        ),
      for (final folder in library.folders)
        DesktopCollectionTile(
          title: folder.name,
          caption: _count(
            library.collectionsIn(folder.id).length,
            'collection',
          ),
          icon: ReelishIcons.stack,
          posters: [
            for (final collection in library.collectionsIn(folder.id))
              ...library.coverArtOf(collection, count: 1),
          ].take(4).toList(),
          onOpen: () => _open(context, FolderTarget(folder.id)),
          onOptions: () =>
              CollectionActions.manageFolder(context, store, folder),
        ),
      for (final collection in library.collectionsIn(null))
        DesktopCollectionTile(
          title: collection.name,
          caption: _count(library.countOf(collection.id), 'title'),
          icon: ReelishIcons.playlist,
          posters: library.coverArtOf(collection),
          onOpen: () => _open(context, CustomTarget(collection.id)),
          onOptions: () => CollectionActions.manage(context, store, collection),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesktopSectionTitle(
          'Collections',
          trailing: store.account == null
              ? null
              : TextButton.icon(
                  onPressed: () => unawaited(_create(context)),
                  icon: const Icon(ReelishIcons.add),
                  label: const Text('New'),
                ),
        ),
        SizedBox(
          height: DesktopCollectionTile.height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: DesktopMetrics.pagePadding,
            ),
            itemCount: tiles.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: DesktopMetrics.gap),
            itemBuilder: (_, index) => tiles[index],
          ),
        ),
        if (library.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DesktopMetrics.pagePadding,
              4,
              DesktopMetrics.pagePadding,
              0,
            ),
            child: Text(
              'Make your own collections with New, and add titles from any '
              'details page with Collections.',
              style: TextStyle(color: GlassTheme.muted),
            ),
          ),
      ],
    );
  }
}

/// A collection, folder or smart collection: cover, name and count. Click
/// opens it; the options button or a right-click opens its menu.
class DesktopCollectionTile extends StatefulWidget {
  const DesktopCollectionTile({
    super.key,
    required this.title,
    required this.caption,
    required this.icon,
    required this.posters,
    required this.onOpen,
    this.onOptions,
    this.width = _tileWidth,
  });

  final String title, caption;
  final IconData icon;
  final List<String> posters;
  final VoidCallback onOpen;
  final VoidCallback? onOptions;
  final double width;

  static double heightFor(double width) =>
      CollectionCover.heightFor(width) + DesktopMetrics.captionHeight;

  static double get height => heightFor(_tileWidth);

  @override
  State<DesktopCollectionTile> createState() => _DesktopCollectionTileState();
}

class _DesktopCollectionTileState extends State<DesktopCollectionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final options = widget.onOptions;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTap: options,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onOpen,
                      borderRadius: BorderRadius.circular(14),
                      child: Semantics(
                        button: true,
                        label: '${widget.title}, ${widget.caption}',
                        excludeSemantics: true,
                        child: AnimatedScale(
                          scale: _hovered ? 1.03 : 1,
                          duration: AppMotion.resolve(context, AppMotion.hover),
                          child: CollectionCover(
                            posters: widget.posters,
                            icon: widget.icon,
                            width: widget.width,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (options != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: AnimatedOpacity(
                        opacity: _hovered ? 1 : 0,
                        duration: AppMotion.resolve(context, AppMotion.hover),
                        child: IconButton.filledTonal(
                          tooltip: 'Options',
                          onPressed: options,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: .55,
                            ),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(ReelishIcons.moreVertical, size: 18),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                widget.caption,
                maxLines: 1,
                style: TextStyle(color: GlassTheme.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A collection, smart collection or folder, filling the window.
class DesktopCollectionPage extends StatefulWidget {
  const DesktopCollectionPage({
    super.key,
    required this.target,
    required this.storage,
    required this.onOpen,
    this.isFavorite,
    this.onToggleFavorite,
  });

  final CollectionTarget target;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;
  final Future<void> Function(MediaItem item)? onToggleFavorite;

  static Future<void> open(
    BuildContext context,
    CollectionTarget target, {
    required StorageService storage,
    required ValueChanged<MediaItem> onOpen,
    bool Function(MediaItem item)? isFavorite,
    Future<void> Function(MediaItem item)? onToggleFavorite,
  }) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      builder: (_) => DesktopCollectionPage(
        target: target,
        storage: storage,
        onOpen: onOpen,
        isFavorite: isFavorite,
        onToggleFavorite: onToggleFavorite,
      ),
    ),
  );

  @override
  State<DesktopCollectionPage> createState() => _DesktopCollectionPageState();
}

class _DesktopCollectionPageState extends State<DesktopCollectionPage> {
  late final _model = LibraryViewModel(storage: widget.storage);
  CollectionSort _sort = CollectionSort.newest;

  CollectionStore get _store => _model.collectionStore;

  @override
  void initState() {
    super.initState();
    _model.addListener(_changed);
    unawaited(_model.load().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    _model.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _close() {
    if (mounted) Navigator.maybePop(context);
  }

  void _openTarget(CollectionTarget target) => unawaited(
    DesktopCollectionPage.open(
      context,
      target,
      storage: widget.storage,
      onOpen: widget.onOpen,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final library = _model.collections;
    final Widget body = switch (widget.target) {
      SmartTarget(:final kind) => _titlesPage(
        title: kind.label,
        subtitle: kind.description,
        items: _model.loading ? null : _model.smart(kind),
      ),
      CustomTarget(:final id) => switch (library.collection(id)) {
        final collection? => _titlesPage(
          title: collection.name,
          subtitle: collection.description,
          items: [
            for (final entry in library.entriesOf(id, sort: _sort)) entry.item,
          ],
          collection: collection,
        ),
        null => _message('This was deleted.'),
      },
      FolderTarget(:final id) => switch (library.folder(id)) {
        final folder? => _folderPage(folder, library),
        null => _message('This was deleted.'),
      },
    };
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            top: 20,
            left: 24,
            child: IconButton.filledTonal(
              tooltip: 'Back (Esc)',
              onPressed: _close,
              icon: const Icon(ReelishIcons.back),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(String text) => Center(
    child: Text(
      _store.loaded ? text : '',
      style: TextStyle(color: GlassTheme.muted),
    ),
  );

  Widget _header(String title, String subtitle, List<Widget> actions) =>
      Padding(
        // Clear of the back button.
        padding: const EdgeInsets.only(top: 48),
        child: DesktopPageHeader(
          title: title,
          subtitle: subtitle.isEmpty ? null : subtitle,
          trailing: actions.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      );

  Widget _titlesPage({
    required String title,
    required String subtitle,
    required List<MediaItem>? items,
    MediaCollection? collection,
  }) {
    final count = _count(items?.length ?? 0, 'title');
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _header(
            title,
            [if (subtitle.isNotEmpty) subtitle, count].join('  ·  '),
            [
              if (collection != null) ...[
                PopupMenuButton<CollectionSort>(
                  tooltip: 'Sort',
                  initialValue: _sort,
                  onSelected: (sort) => setState(() => _sort = sort),
                  itemBuilder: (_) => [
                    for (final sort in CollectionSort.values)
                      PopupMenuItem(value: sort, child: Text(sort.label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(ReelishIcons.sort, color: GlassTheme.primary),
                        const SizedBox(width: 8),
                        Text(_sort.label),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => CollectionActions.manage(
                    context,
                    _store,
                    collection,
                    onDeleted: _close,
                  ),
                  icon: const Icon(ReelishIcons.moreVertical),
                  label: const Text('Options'),
                ),
              ],
            ],
          ),
        ),
        if (items == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: DesktopMessage(
              icon: collection == null
                  ? ReelishIcons.sparkle
                  : ReelishIcons.playlist,
              title: 'Nothing here yet',
              message: collection == null
                  ? 'Titles appear here as you save and watch them.'
                  : 'Add titles from any details page with Collections.',
            ),
          )
        else
          DesktopPosterGrid(
            items: items,
            onOpen: widget.onOpen,
            isFavorite: widget.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
          ),
      ],
    );
  }

  Widget _folderPage(CollectionFolder folder, CollectionLibrary library) {
    final collections = library.collectionsIn(folder.id);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child:
              _header(folder.name, _count(collections.length, 'collection'), [
                FilledButton.icon(
                  onPressed: () async {
                    final created = await CollectionActions.create(
                      context,
                      _store,
                      folderId: folder.id,
                    );
                    if (created != null) _openTarget(CustomTarget(created.id));
                  },
                  icon: const Icon(ReelishIcons.add),
                  label: const Text('New collection'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => CollectionActions.manageFolder(
                    context,
                    _store,
                    folder,
                    onDeleted: _close,
                  ),
                  icon: const Icon(ReelishIcons.moreVertical),
                  label: const Text('Options'),
                ),
              ]),
        ),
        if (collections.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: DesktopMessage(
              icon: ReelishIcons.stack,
              title: 'This folder is empty',
              message:
                  'Create a collection here, or move one in from its options.',
            ),
          )
        else
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final available =
                  constraints.crossAxisExtent - DesktopMetrics.pagePadding * 2;
              final columns = DesktopMetrics.columns(available);
              final width =
                  (available - DesktopMetrics.gap * (columns - 1)) / columns;
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  DesktopMetrics.pagePadding,
                  8,
                  DesktopMetrics.pagePadding,
                  40,
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: DesktopMetrics.gap,
                    mainAxisSpacing: 26,
                    mainAxisExtent: DesktopCollectionTile.heightFor(width),
                  ),
                  itemCount: collections.length,
                  itemBuilder: (context, index) {
                    final collection = collections[index];
                    return DesktopCollectionTile(
                      width: width,
                      title: collection.name,
                      caption: _count(library.countOf(collection.id), 'title'),
                      icon: ReelishIcons.playlist,
                      posters: library.coverArtOf(collection),
                      onOpen: () => _openTarget(CustomTarget(collection.id)),
                      onOptions: () =>
                          CollectionActions.manage(context, _store, collection),
                    );
                  },
                ),
              );
            },
          ),
      ],
    );
  }
}

String _count(int count, String noun) =>
    '$count ${count == 1 ? noun : '${noun}s'}';
