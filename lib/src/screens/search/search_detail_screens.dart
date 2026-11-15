// The pages behind a person and a movie collection found in Universal
// Search. A person's page keeps acting, directing and other work apart (many
// people do several); a collection lists its films in release order. Titles
// open the existing details pages. Where alerts exist, both offer Follow
// (FollowAlertButton).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../search/search_models.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/follow_alert_button.dart';
import 'search_cards.dart';

/// Loads a page and shows it, with retry; shared by both pages.
class _DetailPage<T> extends StatefulWidget {
  const _DetailPage({
    required this.title,
    required this.load,
    required this.build,
  });

  final String title;
  final Future<T> Function() load;
  final List<Widget> Function(BuildContext context, T value) build;

  @override
  State<_DetailPage<T>> createState() => _DetailPageState<T>();
}

class _DetailPageState<T> extends State<_DetailPage<T>> {
  late Future<T> _value = widget.load();

  @override
  Widget build(BuildContext context) {
    final gutter = DeviceCapabilities.isTv
        ? 48.0
        : DeviceCapabilities.isDesktop
        ? 32.0
        : AppSpace.md;
    return CallbackShortcuts(
      // Esc goes back on Windows, as on other pages there.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Scaffold(
        backgroundColor: GlassTheme.background,
        body: SafeArea(
          child: FutureBuilder<T>(
            future: _value,
            builder: (context, snapshot) {
              final header = Padding(
                padding: EdgeInsets.fromLTRB(
                  gutter - 8,
                  AppSpace.sm,
                  gutter,
                  0,
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      autofocus: DeviceCapabilities.isTv && !snapshot.hasData,
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(ReelishIcons.back),
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: AppTextSize.title,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              );
              if (snapshot.hasError) {
                return Column(
                  children: [
                    header,
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'This page didn’t load.',
                              style: TextStyle(color: GlassTheme.textPrimary),
                            ),
                            const SizedBox(height: AppSpace.sm),
                            OutlinedButton(
                              onPressed: () =>
                                  setState(() => _value = widget.load()),
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }
              final value = snapshot.data;
              if (value == null) {
                return Column(
                  children: [
                    header,
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ],
                );
              }
              return ListView(
                padding: EdgeInsets.only(bottom: AppSpace.xl),
                children: [
                  header,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: widget.build(context, value),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Widget _heading(String text) => Padding(
  padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.sm),
  child: Text(
    text,
    style: TextStyle(
      color: GlassTheme.textPrimary,
      fontSize: AppTextSize.title,
      fontWeight: FontWeight.w800,
    ),
  ),
);

/// The narrowest a phone poster gets before a row drops a column.
const double _phonePosterMin = 100;

/// Titles in rows. TV and Windows keep their fixed poster size; on a phone
/// the posters share the row evenly, as many as fit at [_phonePosterMin]
/// (three on a 360 dp phone), so no strip is left at the edge.
Widget _titles(
  List<MediaItem> items,
  ValueChanged<MediaItem> onOpen, {
  List<String>? roles,
}) {
  if (DeviceCapabilities.usesTvLayout) {
    return _titleWrap(items, onOpen, SearchSizes.poster, roles: roles);
  }
  return LayoutBuilder(
    builder: (context, box) {
      const spacing = AppSpace.sm;
      final columns = math.max(
        2,
        ((box.maxWidth + spacing) / (_phonePosterMin + spacing)).floor(),
      );
      final width = (box.maxWidth - spacing * (columns - 1)) / columns;
      // Floored a hair so rounding never pushes the last poster to a new row.
      return _titleWrap(items, onOpen, width - 0.01, roles: roles);
    },
  );
}

Widget _titleWrap(
  List<MediaItem> items,
  ValueChanged<MediaItem> onOpen,
  double width, {
  List<String>? roles,
}) => Wrap(
  spacing: AppSpace.sm,
  runSpacing: AppSpace.md,
  children: [
    for (final (index, item) in items.indexed)
      SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SearchTitleCard(
              item: item,
              width: width,
              onOpen: () => onOpen(item),
            ),
            if (roles != null && roles[index].isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  roles[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.primary,
                    fontSize: AppTextSize.caption,
                  ),
                ),
              ),
          ],
        ),
      ),
  ],
);

class PersonScreen extends StatelessWidget {
  const PersonScreen({
    super.key,
    required this.id,
    required this.name,
    required this.load,
    required this.onOpenTitle,
  });

  final int id;
  final String name;
  final Future<PersonDetails> Function(int id) load;
  final ValueChanged<MediaItem> onOpenTitle;

  @override
  Widget build(BuildContext context) => _DetailPage<PersonDetails>(
    title: name,
    load: () => load(id),
    build: (context, person) {
      Widget credits(String title, List<PersonCredit> list) => list.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heading('$title  ${list.length}'),
                _titles(
                  [for (final credit in list) credit.item],
                  onOpenTitle,
                  roles: [for (final credit in list) credit.role],
                ),
              ],
            );
      final born = [
        if (person.birthday.isNotEmpty) 'Born ${person.birthday}',
        if (person.placeOfBirth.isNotEmpty) person.placeOfBirth,
      ].join(' · ');
      // Their own department first: a director's page opens on directing.
      final sections = [
        ('Acting', person.acting),
        ('Directing', person.directing),
        ('Other work', person.otherCrew),
      ];
      if (person.department == 'Directing') {
        sections.insert(0, sections.removeAt(1));
      }
      return [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              height: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: person.profileUrl.isEmpty
                    ? ColoredBox(
                        color: GlassTheme.elevatedSurface,
                        child: Icon(
                          ReelishIcons.person,
                          color: GlassTheme.muted,
                          size: 48,
                        ),
                      )
                    : ArtworkImage.network(
                        person.profileUrl,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                      ),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: AppTextSize.headline,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (person.department.isNotEmpty)
                    Text(
                      'Known for ${person.department.toLowerCase()}',
                      style: TextStyle(
                        color: GlassTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (born.isNotEmpty)
                    Text(born, style: TextStyle(color: GlassTheme.muted)),
                  FollowAlertButton.person(id: id, name: person.name),
                ],
              ),
            ),
          ],
        ),
        if (person.biography.isNotEmpty) _Biography(text: person.biography),
        for (final (title, list) in sections) credits(title, list),
        if (person.acting.isEmpty &&
            person.directing.isEmpty &&
            person.otherCrew.isEmpty)
          _heading('No movies or series listed yet'),
      ];
    },
  );
}

class _Biography extends StatefulWidget {
  const _Biography({required this.text});

  final String text;

  @override
  State<_Biography> createState() => _BiographyState();
}

class _BiographyState extends State<_Biography> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: _open ? null : 4,
          overflow: _open ? null : TextOverflow.ellipsis,
          style: TextStyle(color: GlassTheme.muted),
        ),
        if (widget.text.length > 240)
          TextButton(
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? 'Less' : 'More'),
          ),
      ],
    ),
  );
}

class CollectionScreen extends StatelessWidget {
  const CollectionScreen({
    super.key,
    required this.id,
    required this.name,
    required this.load,
    required this.onOpenTitle,
  });

  final int id;
  final String name;
  final Future<CollectionDetails> Function(int id) load;
  final ValueChanged<MediaItem> onOpenTitle;

  @override
  Widget build(BuildContext context) => _DetailPage<CollectionDetails>(
    title: name,
    load: () => load(id),
    build: (context, collection) => [
      if (collection.backdropUrl.isNotEmpty)
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: AspectRatio(
            aspectRatio: 21 / 9,
            child: ArtworkImage.network(
              collection.backdropUrl,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
            ),
          ),
        ),
      const SizedBox(height: AppSpace.md),
      Text(
        collection.name,
        style: TextStyle(
          color: GlassTheme.textPrimary,
          fontSize: AppTextSize.headline,
          fontWeight: FontWeight.w800,
        ),
      ),
      Text(
        'Movie collection on TMDB · ${collection.parts.length} '
        'film${collection.parts.length == 1 ? '' : 's'}',
        style: TextStyle(
          color: GlassTheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FollowAlertButton.collection(id: id, name: collection.name),
      ),
      if (collection.overview.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            collection.overview,
            style: TextStyle(color: GlassTheme.muted),
          ),
        ),
      _heading('Films in order'),
      _titles(collection.parts, onOpenTitle),
    ],
  );
}
