// A friend's shared collection, read-only: its titles as poster cards that
// open the title's details. Reached from the friend's page on phone, TV and
// Windows. The server lists only collections the friend shares, and only to
// friends; if it stops being shared the page says so.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../account/account_api.dart';
import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/collections/collection_cover.dart';
import '../../widgets/settings/settings_components.dart';

/// A shared collection on a friend's page: its cover, name and size.
class SharedCollectionTile extends StatelessWidget {
  const SharedCollectionTile({
    super.key,
    required this.collection,
    required this.onOpen,
  });

  final SharedCollection collection;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => MergeSemantics(child: _row());

  Widget _row() => InkWell(
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          CollectionCover(
            posters: collection.posters,
            icon: ReelishIcons.playlist,
            width: 44,
            radius: AppRadius.sm,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  collection.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.titleSmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    collection.count == 1
                        ? '1 title'
                        : '${collection.count} titles',
                    ?collection.description,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.muted,
                    fontSize: AppTextSize.label,
                  ),
                ),
              ],
            ),
          ),
          Icon(ReelishIcons.chevronRight, color: GlassTheme.muted, size: 22),
        ],
      ),
    ),
  );
}

class FriendCollectionScreen extends StatefulWidget {
  const FriendCollectionScreen({
    super.key,
    required this.owner,
    required this.collection,
    this.friends,
    this.onBack,
  });

  final SocialPerson owner;
  final SharedCollection collection;

  /// [FriendsController.instance] when null.
  final FriendsController? friends;
  final VoidCallback? onBack;

  @override
  State<FriendCollectionScreen> createState() => _FriendCollectionScreenState();
}

class _FriendCollectionScreenState extends State<FriendCollectionScreen> {
  late final FriendsController _friends =
      widget.friends ?? FriendsController.instance;
  late SharedCollection _collection = widget.collection;
  final _titles = <MediaItem>[];
  String? _cursor;
  bool _loading = true;
  bool _failed = false;

  /// The server no longer shares it with this account.
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await _friends.sharedCollection(
        widget.owner.handle,
        _collection.id,
        cursor: more ? _cursor : null,
      );
      if (!mounted) return;
      setState(() {
        if (!more) _titles.clear();
        _titles.addAll(page.titles);
        _titles.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        _cursor = page.cursor;
        if (page.collection case final collection?) _collection = collection;
      });
    } on AccountApiException catch (error) {
      if (mounted) {
        setState(() => error.status == 404 ? _gone = true : _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(MediaItem item) {
    final open = SocialTitles.open;
    if (open != null) unawaited(open(item));
  }

  @override
  Widget build(BuildContext context) {
    final width = DeviceCapabilities.usesTvLayout ? 150.0 : 112.0;
    return SettingsPage(
      title: _collection.name,
      subtitle: 'Shared by ${widget.owner.label}',
      icon: ReelishIcons.playlist,
      onBack: widget.onBack,
      footer: null,
      children: [
        if (_gone)
          SettingsSection(
            description:
                '${widget.owner.label} no longer shares this collection with '
                'you.',
            children: [
              SettingsTile(
                icon: ReelishIcons.back,
                title: 'Back',
                onTap: widget.onBack,
              ),
            ],
          )
        else if (_titles.isEmpty && _loading)
          const Padding(
            padding: EdgeInsets.all(AppSpace.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_titles.isEmpty && _failed)
          SettingsSection(
            description: 'The collection could not be loaded.',
            children: [
              SettingsTile(
                icon: ReelishIcons.refresh,
                title: 'Try again',
                onTap: () => unawaited(_load()),
              ),
            ],
          )
        else ...[
          if (_collection.description case final description?)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, AppSpace.md),
              child: Text(
                description,
                style: TextStyle(color: GlassTheme.muted),
              ),
            ),
          if (_titles.isEmpty)
            Text(
              'Nothing in it yet.',
              style: TextStyle(color: GlassTheme.muted),
            ),
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            children: [
              for (final (index, item) in _titles.indexed)
                _PosterCard(
                  item: item,
                  width: width,
                  autofocus: index == 0 && DeviceCapabilities.usesTvLayout,
                  onOpen: () => _open(item),
                ),
            ],
          ),
          if (_cursor != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.lg),
              child: SettingsSection(
                children: [
                  SettingsTile(
                    icon: ReelishIcons.arrowDown,
                    title: _loading ? 'Loading…' : 'Show more',
                    enabled: !_loading,
                    onTap: () => unawaited(_load(more: true)),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.width,
    required this.onOpen,
    this.autofocus = false,
  });

  final MediaItem item;
  final double width;
  final VoidCallback onOpen;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // One item for a screen reader: the title and its year.
    return SizedBox(
      width: width,
      child: MergeSemantics(child: _card(ratio)),
    );
  }

  Widget _card(double ratio) => InkWell(
    autofocus: autofocus,
    borderRadius: BorderRadius.circular(AppRadius.sm),
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: SizedBox(
              width: width,
              height: width * 1.5,
              child: item.poster.isEmpty
                  ? ColoredBox(
                      color: GlassTheme.surface,
                      child: Icon(ReelishIcons.movie, color: GlassTheme.muted),
                    )
                  : ArtworkImage.network(
                      item.poster,
                      fit: BoxFit.cover,
                      cacheWidth: (width * ratio).round(),
                      errorBuilder: (_, _, _) =>
                          ColoredBox(color: GlassTheme.surface),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.bodySmall,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (item.year.isNotEmpty)
            Text(
              item.year,
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
            ),
        ],
      ),
    ),
  );
}
