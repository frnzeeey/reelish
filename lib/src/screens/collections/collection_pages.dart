// Collections on the phone: the Library's Collections section (smart
// collections, folders and the viewer's own collections) and the page each
// of them opens, a grid of titles or of a folder's collections. Long press
// reaches a collection's or title's actions.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../collections/collection_models.dart';
import '../../collections/collection_store.dart';
import '../../collections/smart_collections.dart';
import '../../models/media_item.dart';
import '../../navigation/app_transitions.dart';
import '../../services/storage_service.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../viewmodels/library_view_model.dart';
import '../../widgets/collections/collection_actions.dart';
import '../../widgets/collections/collection_cover.dart';
import '../../widgets/media_card.dart';

/// The Library's Collections section.
class CollectionsSection extends StatelessWidget {
  const CollectionsSection({
    super.key,
    required this.model,
    required this.storage,
    required this.onOpen,
  });

  final LibraryViewModel model;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

  void _open(BuildContext context, CollectionTarget target) =>
      unawaited(CollectionPage.open(context, target, storage, onOpen));

  Future<void> _new(BuildContext context) async {
    final store = model.collectionStore;
    final choice = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: GlassTheme.elevatedSurface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(ReelishIcons.playlist, color: GlassTheme.primary),
              title: const Text('New collection'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: Icon(ReelishIcons.stack, color: GlassTheme.primary),
              title: const Text('New folder'),
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice) {
      final created = await CollectionActions.create(context, store);
      if (created != null && context.mounted) {
        _open(context, CustomTarget(created.id));
      }
    } else {
      await CollectionActions.createFolder(context, store);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = model.collections;
    final store = model.collectionStore;
    final width = MediaCard.rowWidthFor(context);
    final tiles = <Widget>[
      for (final folder in library.folders)
        _Tile(
          width: width,
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
          onTap: () => _open(context, FolderTarget(folder.id)),
          onLongPress: () =>
              CollectionActions.manageFolder(context, store, folder),
        ),
      for (final collection in library.collectionsIn(null))
        _Tile(
          width: width,
          title: collection.name,
          caption: _count(library.countOf(collection.id), 'title'),
          icon: ReelishIcons.playlist,
          posters: library.coverArtOf(collection),
          onTap: () => _open(context, CustomTarget(collection.id)),
          onLongPress: () =>
              CollectionActions.manage(context, store, collection),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Collections',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Your own lists, and ones that fill themselves',
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.label,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'New collection or folder',
                  onPressed: store.account == null ? null : () => _new(context),
                  icon: Icon(ReelishIcons.add, color: GlassTheme.primary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _TileRow(
            storageKey: 'library-smart',
            width: width,
            children: [
              for (final kind in SmartCollection.values)
                _Tile(
                  width: width,
                  title: kind.label,
                  caption: _count(model.smart(kind).length, 'title'),
                  icon: ReelishIcons.sparkle,
                  posters: [
                    for (final item in model.smart(kind).take(4))
                      if (item.poster.isNotEmpty) item.poster,
                  ],
                  onTap: () => _open(context, SmartTarget(kind)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (tiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _EmptyCollections(
                onCreate: store.account == null ? null : () => _new(context),
              ),
            )
          else
            _TileRow(
              storageKey: 'library-collections',
              width: width,
              children: tiles,
            ),
        ],
      ),
    );
  }
}

class _TileRow extends StatelessWidget {
  const _TileRow({
    required this.storageKey,
    required this.width,
    required this.children,
  });

  final String storageKey;
  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _Tile.heightFor(context, width),
    child: ListView.separated(
      key: PageStorageKey<String>(storageKey),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: children.length,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (_, index) => children[index],
    ),
  );
}

/// A collection, folder or smart collection: its cover, name and count.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.width,
    required this.title,
    required this.caption,
    required this.icon,
    required this.posters,
    required this.onTap,
    this.onLongPress,
  });

  final double width;
  final String title, caption;
  final IconData icon;
  final List<String> posters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static double heightFor(BuildContext context, double width) =>
      CollectionCover.heightFor(width) + MediaCard.captionHeight(context);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title, $caption',
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CollectionCover(posters: posters, icon: icon, width: width),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: AppTextSize.bodySmall,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              caption,
              maxLines: 1,
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.caption,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyCollections extends StatelessWidget {
  const _EmptyCollections({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            ReelishIcons.playlist,
            size: 19,
            color: GlassTheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Make your first collection',
                style: TextStyle(
                  fontSize: AppTextSize.body,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Group titles your way, such as Weekend movies or Childhood '
                'favourites. Add titles from any details page.',
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        if (onCreate != null) ...[
          const SizedBox(width: AppSpace.xs),
          TextButton(onPressed: onCreate, child: const Text('Create')),
        ],
      ],
    ),
  );
}

/// A collection, smart collection or folder, full screen.
class CollectionPage extends StatefulWidget {
  const CollectionPage({
    super.key,
    required this.target,
    required this.storage,
    required this.onOpen,
    this.store,
  });

  final CollectionTarget target;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;
  final CollectionStore? store;

  static Future<void> open(
    BuildContext context,
    CollectionTarget target,
    StorageService storage,
    ValueChanged<MediaItem> onOpen,
  ) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      builder: (_) =>
          CollectionPage(target: target, storage: storage, onOpen: onOpen),
    ),
  );

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late final _model = LibraryViewModel(
    storage: widget.storage,
    collections: widget.store,
  );
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

  Future<void> _removeTitle(MediaCollection collection, MediaItem item) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _store.remove(item, collection.id);
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not remove it. Try again.')),
      );
      return;
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${item.name} removed from ${collection.name}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                unawaited(_store.add(item, collection.id).catchError((_) {})),
          ),
        ),
      );
  }

  Future<void> _titleActions(MediaCollection collection, MediaItem item) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: GlassTheme.elevatedSurface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                item.name,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: Icon(ReelishIcons.playlist, color: GlassTheme.primary),
              title: const Text('Collections…'),
              onTap: () => Navigator.pop(context, 0),
            ),
            ListTile(
              leading: Icon(ReelishIcons.star, color: GlassTheme.primary),
              title: const Text('Use as cover'),
              onTap: () => Navigator.pop(context, 1),
            ),
            ListTile(
              leading: Icon(ReelishIcons.minus, color: GlassTheme.primary),
              title: Text('Remove from ${collection.name}'),
              onTap: () => Navigator.pop(context, 2),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 0:
        await CollectionActions.addToCollections(context, _store, item);
      case 1:
        await _store.setCover(collection.id, item).catchError((_) {});
      case 2:
        await _removeTitle(collection, item);
    }
  }

  Future<void> _chooseSort() async {
    final sort = await showModalBottomSheet<CollectionSort>(
      context: context,
      showDragHandle: true,
      backgroundColor: GlassTheme.elevatedSurface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final sort in CollectionSort.values)
              ListTile(
                title: Text(sort.label),
                trailing: sort == _sort
                    ? Icon(ReelishIcons.check, color: GlassTheme.primary)
                    : null,
                onTap: () => Navigator.pop(context, sort),
              ),
          ],
        ),
      ),
    );
    if (sort != null && mounted) setState(() => _sort = sort);
  }

  @override
  Widget build(BuildContext context) {
    final library = _model.collections;
    return switch (widget.target) {
      SmartTarget(:final kind) => _titlesPage(
        title: kind.label,
        subtitle: kind.description,
        items: _model.loading ? null : _model.smart(kind),
        icon: ReelishIcons.sparkle,
        empty: switch (kind) {
          SmartCollection.recentlyAdded =>
            'Titles you add to My list or a collection appear here for 30 days.',
          SmartCollection.myList =>
            'Add a movie or series to My list and it appears here.',
          SmartCollection.unwatched =>
            'Saved titles you have not started appear here.',
          SmartCollection.finished =>
            'Titles you watch to the end appear here.',
        },
      ),
      CustomTarget(:final id) => switch (library.collection(id)) {
        final collection? => _titlesPage(
          title: collection.name,
          subtitle: collection.description,
          items: [
            for (final entry in library.entriesOf(id, sort: _sort)) entry.item,
          ],
          icon: ReelishIcons.playlist,
          empty: 'Add titles from any details page with Collections.',
          collection: collection,
        ),
        null => _gone(),
      },
      FolderTarget(:final id) => switch (library.folder(id)) {
        final folder? => _folderPage(folder, library),
        null => _gone(),
      },
    };
  }

  /// The collection or folder was deleted (here or by sync).
  Widget _gone() => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: Text(
        _store.loaded ? 'This was deleted.' : '',
        style: TextStyle(color: GlassTheme.muted),
      ),
    ),
  );

  int _columns(double width) =>
      math.max(2, ((width - 40 + 12) / (MediaCard.defaultWidth + 12)).floor());

  Widget _titlesPage({
    required String title,
    required String subtitle,
    required List<MediaItem>? items,
    required IconData icon,
    required String empty,
    MediaCollection? collection,
  }) {
    final count = items?.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (collection != null) ...[
            IconButton(
              tooltip: 'Sort: ${_sort.label}',
              onPressed: _chooseSort,
              icon: const Icon(ReelishIcons.sort),
            ),
            IconButton(
              tooltip: 'Collection options',
              onPressed: () => CollectionActions.manage(
                context,
                _store,
                collection,
                onDeleted: _close,
              ),
              icon: const Icon(ReelishIcons.moreVertical),
            ),
          ],
        ],
      ),
      body: items == null
          ? Center(child: CircularProgressIndicator(color: GlassTheme.primary))
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = _columns(constraints.maxWidth);
                final width =
                    (constraints.maxWidth - 40 - 12 * (columns - 1)) / columns;
                return CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (subtitle.isNotEmpty) ...[
                              Text(
                                subtitle,
                                style: TextStyle(
                                  color: GlassTheme.muted,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            Text(
                              [
                                _count(count, 'title'),
                                if (collection != null && count > 1)
                                  _sort.label,
                              ].join(' · '),
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: AppTextSize.caption,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (items.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyPage(icon: icon, message: empty),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 16,
                                mainAxisExtent: MediaCard.heightFor(
                                  context,
                                  width,
                                ),
                              ),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return MediaCard(
                              item: item,
                              width: width,
                              onTap: () => widget.onOpen(item),
                              onLongPress: collection == null
                                  ? null
                                  : () => unawaited(
                                      _titleActions(collection, item),
                                    ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _folderPage(CollectionFolder folder, CollectionLibrary library) {
    final collections = library.collectionsIn(folder.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'New collection in this folder',
            onPressed: () async {
              final created = await CollectionActions.create(
                context,
                _store,
                folderId: folder.id,
              );
              if (created != null && mounted) {
                unawaited(
                  CollectionPage.open(
                    context,
                    CustomTarget(created.id),
                    widget.storage,
                    widget.onOpen,
                  ),
                );
              }
            },
            icon: const Icon(ReelishIcons.add),
          ),
          IconButton(
            tooltip: 'Folder options',
            onPressed: () => CollectionActions.manageFolder(
              context,
              _store,
              folder,
              onDeleted: _close,
            ),
            icon: const Icon(ReelishIcons.moreVertical),
          ),
        ],
      ),
      body: collections.isEmpty
          ? const _EmptyPage(
              icon: ReelishIcons.stack,
              message:
                  'This folder is empty. Create a collection here with +, or '
                  'move one in from its options.',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = _columns(constraints.maxWidth);
                final width =
                    (constraints.maxWidth - 40 - 12 * (columns - 1)) / columns;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    mainAxisExtent: _Tile.heightFor(context, width),
                  ),
                  itemCount: collections.length,
                  itemBuilder: (context, index) {
                    final collection = collections[index];
                    return _Tile(
                      width: width,
                      title: collection.name,
                      caption: _count(library.countOf(collection.id), 'title'),
                      icon: ReelishIcons.playlist,
                      posters: library.coverArtOf(collection),
                      onTap: () => unawaited(
                        CollectionPage.open(
                          context,
                          CustomTarget(collection.id),
                          widget.storage,
                          widget.onOpen,
                        ),
                      ),
                      onLongPress: () =>
                          CollectionActions.manage(context, _store, collection),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _EmptyPage extends StatelessWidget {
  const _EmptyPage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: GlassTheme.primary),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: GlassTheme.muted, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

String _count(int count, String noun) =>
    '$count ${count == 1 ? noun : '${noun}s'}';
