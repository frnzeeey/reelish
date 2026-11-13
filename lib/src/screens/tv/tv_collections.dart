// Collections for the remote: the library's Collections row (smart
// collections, folders, the viewer's collections and a Create tile) and the
// full-screen page each opens, with its actions as buttons above a poster
// grid. Removing a title is on its details page, through Collections.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../collections/collection_models.dart';
import '../../collections/collection_store.dart';
import '../../collections/smart_collections.dart';
import '../../models/media_item.dart';
import '../../navigation/app_transitions.dart';
import '../../services/storage_service.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../viewmodels/library_view_model.dart';
import '../../widgets/collections/collection_actions.dart';
import '../../widgets/collections/collection_cover.dart';
import '../../widgets/tv/tv_focus.dart';
import '../../widgets/tv/tv_poster_card.dart';
import 'tv_browse.dart';

/// The library's Collections row.
class TvCollectionsRow extends StatelessWidget {
  const TvCollectionsRow({
    super.key,
    required this.model,
    required this.storage,
    required this.onOpen,
    this.autofocus = false,
  });

  final LibraryViewModel model;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;
  final bool autofocus;

  void _open(BuildContext context, CollectionTarget target) =>
      unawaited(TvCollectionPage.open(context, target, storage, onOpen));

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
    final tiles = <Widget>[
      for (final kind in SmartCollection.values)
        TvCollectionTile(
          autofocus: autofocus && kind == SmartCollection.values.first,
          title: kind.label,
          caption: _count(model.smart(kind).length, 'title'),
          icon: ReelishIcons.sparkle,
          posters: [
            for (final item in model.smart(kind).take(4))
              if (item.poster.isNotEmpty) item.poster,
          ],
          onSelect: () => _open(context, SmartTarget(kind)),
        ),
      for (final folder in library.folders)
        TvCollectionTile(
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
          onSelect: () => _open(context, FolderTarget(folder.id)),
        ),
      for (final collection in library.collectionsIn(null))
        TvCollectionTile(
          title: collection.name,
          caption: _count(library.countOf(collection.id), 'title'),
          icon: ReelishIcons.playlist,
          posters: library.coverArtOf(collection),
          onSelect: () => _open(context, CustomTarget(collection.id)),
        ),
      if (model.collectionStore.account != null)
        TvCollectionTile(
          title: 'Create',
          caption: 'Collection or folder',
          icon: ReelishIcons.add,
          posters: const [],
          onSelect: () => unawaited(_create(context)),
        ),
    ];
    return SizedBox(
      height: TvMediaRow.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TvRowTitle('Collections'),
          Expanded(
            child: FocusTraversalGroup(
              policy: tvSelfScrollingTraversal,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: TvPosterMetrics.focusPadding,
                ),
                itemCount: tiles.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: TvPosterMetrics.gap),
                itemBuilder: (_, index) => tiles[index],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A collection, folder or smart collection as a poster-sized card, its
/// name on the artwork.
class TvCollectionTile extends StatelessWidget {
  const TvCollectionTile({
    super.key,
    required this.title,
    required this.caption,
    required this.icon,
    required this.posters,
    required this.onSelect,
    this.autofocus = false,
  });

  final String title, caption;
  final IconData icon;
  final List<String> posters;
  final VoidCallback onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: TvPosterMetrics.width,
    height: TvPosterMetrics.height,
    child: TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      scrollAlignment: .5,
      semanticLabel: '$title, $caption',
      child: Stack(
        fit: StackFit.expand,
        children: [
          CollectionCover(
            posters: posters,
            icon: icon,
            width: TvPosterMetrics.width,
            radius: 0,
          ),
          // White on artwork, over the artwork scrim.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    GlassTheme.artworkScrim.withValues(alpha: .92),
                    GlassTheme.artworkScrim.withValues(alpha: 0),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .8),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A collection, smart collection or folder, full screen.
class TvCollectionPage extends StatefulWidget {
  const TvCollectionPage({
    super.key,
    required this.target,
    required this.storage,
    required this.onOpen,
  });

  final CollectionTarget target;
  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

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
          TvCollectionPage(target: target, storage: storage, onOpen: onOpen),
    ),
  );

  @override
  State<TvCollectionPage> createState() => _TvCollectionPageState();
}

class _TvCollectionPageState extends State<TvCollectionPage> {
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

  Future<void> _chooseSort() async {
    final sort = await showDialog<CollectionSort>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: GlassTheme.elevatedSurface,
        title: const Text('Sort by'),
        children: [
          for (final sort in CollectionSort.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, sort),
              child: Row(
                children: [
                  Expanded(child: Text(sort.label)),
                  if (sort == _sort)
                    Icon(ReelishIcons.check, color: GlassTheme.primary),
                ],
              ),
            ),
        ],
      ),
    );
    if (sort != null && mounted) setState(() => _sort = sort);
  }

  void _openTarget(CollectionTarget target) => unawaited(
    TvCollectionPage.open(context, target, widget.storage, widget.onOpen),
  );

  @override
  Widget build(BuildContext context) {
    final library = _model.collections;
    final Widget body = switch (widget.target) {
      SmartTarget(:final kind) => _page(
        title: kind.label,
        subtitle: kind.description,
        items: _model.loading ? null : _model.smart(kind),
        actions: const [],
      ),
      CustomTarget(:final id) => switch (library.collection(id)) {
        final collection? => _page(
          title: collection.name,
          subtitle: collection.description,
          items: [
            for (final entry in library.entriesOf(id, sort: _sort)) entry.item,
          ],
          actions: [
            _button(
              icon: ReelishIcons.sort,
              label: _sort.label,
              onPressed: _chooseSort,
            ),
            _button(
              icon: ReelishIcons.moreVertical,
              label: 'Options',
              onPressed: () => CollectionActions.manage(
                context,
                _store,
                collection,
                onDeleted: _close,
              ),
            ),
          ],
          empty:
              'Add titles from a details page: choose Collections, then '
              'tick ${collection.name}.',
        ),
        null => _gone(),
      },
      FolderTarget(:final id) => switch (library.folder(id)) {
        final folder? => _folderPage(folder, library),
        null => _gone(),
      },
    };
    return Scaffold(backgroundColor: GlassTheme.background, body: body);
  }

  Widget _gone() => TvMessage(
    icon: ReelishIcons.playlist,
    title: _store.loaded ? 'This was deleted' : '',
    message: '',
  );

  Widget _button({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) => OutlinedButton.icon(
    autofocus: autofocus,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      shape: const StadiumBorder(),
      foregroundColor: GlassTheme.textPrimary,
      textStyle: const TextStyle(
        fontFamily: GlassTheme.fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w800,
      ),
    ),
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
  );

  Widget _header(String title, String subtitle, String count) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w900,
          letterSpacing: -1,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        [if (subtitle.isNotEmpty) subtitle, count].join('  ·  '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: GlassTheme.muted, fontSize: 15),
      ),
    ],
  );

  Widget _page({
    required String title,
    required String subtitle,
    required List<MediaItem>? items,
    required List<Widget> actions,
    String empty = '',
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(
      TvSafeArea.horizontal,
      TvSafeArea.vertical,
      TvSafeArea.horizontal,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(title, subtitle, _count(items?.length ?? 0, 'title')),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 12, children: actions),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: items == null
              ? Center(
                  child: CircularProgressIndicator(color: GlassTheme.primary),
                )
              : items.isEmpty
              ? Focus(
                  // Keeps focus on the page (and Back working) when there
                  // is nothing else to focus.
                  autofocus: actions.isEmpty,
                  child: TvMessage(
                    icon: ReelishIcons.playlist,
                    title: 'Nothing here yet',
                    message: empty.isNotEmpty
                        ? empty
                        : 'Titles appear here as you save and watch them.',
                  ),
                )
              : TvMediaGrid(
                  items: items,
                  autofocus: true,
                  cards: TvCardOptions(onOpen: widget.onOpen),
                ),
        ),
      ],
    ),
  );

  Widget _folderPage(CollectionFolder folder, CollectionLibrary library) {
    final collections = library.collectionsIn(folder.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TvSafeArea.horizontal,
        TvSafeArea.vertical,
        TvSafeArea.horizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(folder.name, '', _count(collections.length, 'collection')),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            children: [
              _button(
                icon: ReelishIcons.add,
                label: 'New collection',
                autofocus: collections.isEmpty,
                onPressed: () async {
                  final created = await CollectionActions.create(
                    context,
                    _store,
                    folderId: folder.id,
                  );
                  if (created != null) _openTarget(CustomTarget(created.id));
                },
              ),
              _button(
                icon: ReelishIcons.moreVertical,
                label: 'Folder options',
                onPressed: () => CollectionActions.manageFolder(
                  context,
                  _store,
                  folder,
                  onDeleted: _close,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: collections.isEmpty
                ? const TvMessage(
                    icon: ReelishIcons.stack,
                    title: 'This folder is empty',
                    message:
                        'Create a collection here, or move one in from its '
                        'Options.',
                  )
                : FocusTraversalGroup(
                    child: GridView.builder(
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.fromLTRB(
                        12,
                        TvPosterMetrics.focusPadding,
                        12,
                        40,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent:
                                TvPosterMetrics.width + TvPosterMetrics.gap,
                            mainAxisExtent: TvPosterMetrics.height,
                            crossAxisSpacing: TvPosterMetrics.gap,
                            mainAxisSpacing: TvPosterMetrics.gap + 6,
                          ),
                      itemCount: collections.length,
                      itemBuilder: (context, index) {
                        final collection = collections[index];
                        return Align(
                          alignment: Alignment.topLeft,
                          child: TvCollectionTile(
                            autofocus: index == 0,
                            title: collection.name,
                            caption: _count(
                              library.countOf(collection.id),
                              'title',
                            ),
                            icon: ReelishIcons.playlist,
                            posters: library.coverArtOf(collection),
                            onSelect: () =>
                                _openTarget(CustomTarget(collection.id)),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _count(int count, String noun) =>
    '$count ${count == 1 ? noun : '${noun}s'}';
