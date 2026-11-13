// The dialogs that create, edit, move and delete collections and folders,
// and the one that puts a title in collections. They are plain dialogs of
// buttons and list tiles, so the same flow works by touch, with the mouse
// and keyboard, and with a TV remote; destructive choices focus Cancel.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../collections/collection_models.dart';
import '../../collections/collection_store.dart';
import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';

/// What [CollectionActions.manage] can do with a collection.
enum _CollectionAction { edit, move, cover, earlier, later, delete }

/// What [CollectionActions.manageFolder] can do with a folder.
enum _FolderAction { rename, earlier, later, delete }

/// Where [CollectionActions.move] can put a collection.
sealed class _Destination {
  const _Destination();
}

class _TopLevel extends _Destination {
  const _TopLevel();
}

class _NewFolder extends _Destination {
  const _NewFolder();
}

class _Folder extends _Destination {
  const _Folder(this.id);
  final String id;
}

abstract final class CollectionActions {
  /// Asks for a name (and description) and creates a collection in
  /// [folderId], with [first] in it when given.
  static Future<MediaCollection?> create(
    BuildContext context,
    CollectionStore store, {
    String? folderId,
    MediaItem? first,
  }) async {
    final input = await _CollectionForm.show(
      context,
      title: 'New collection',
      action: 'Create',
    );
    if (input == null || !context.mounted) return null;
    return _attempt(
      context,
      () => store.createCollection(
        name: input.name,
        description: input.description,
        folderId: folderId,
        first: first,
      ),
      done: first == null ? null : 'Added to ${input.name.trim()}',
    );
  }

  static Future<void> edit(
    BuildContext context,
    CollectionStore store,
    MediaCollection collection,
  ) async {
    final input = await _CollectionForm.show(
      context,
      title: 'Edit collection',
      action: 'Save',
      name: collection.name,
      description: collection.description,
    );
    if (input == null || !context.mounted) return;
    await _run(
      context,
      () => store.editCollection(
        collection.id,
        name: input.name,
        description: input.description,
      ),
    );
  }

  /// Asks first; true once the collection is deleted.
  static Future<bool> delete(
    BuildContext context,
    CollectionStore store,
    MediaCollection collection,
  ) async {
    final count = store.library.countOf(collection.id);
    final confirmed = await confirm(
      context,
      title: 'Delete ${collection.name}?',
      message:
          'The collection and its list of '
          '$count ${count == 1 ? 'title' : 'titles'} are deleted. The titles '
          'stay on My list, in other collections and in your history.',
      action: 'Delete',
    );
    if (!confirmed || !context.mounted) return false;
    return _run(
      context,
      () => store.deleteCollection(collection.id),
      done: '${collection.name} deleted',
    );
  }

  /// Moves a collection into a folder (a new one if chosen) or to the top
  /// of the library.
  static Future<void> move(
    BuildContext context,
    CollectionStore store,
    MediaCollection collection,
  ) async {
    final library = store.library;
    final destination = await _choose<_Destination>(
      context,
      title: 'Move ${collection.name}',
      options: [
        (
          const _TopLevel(),
          ReelishIcons.library,
          'My library (no folder)',
          collection.folderId == null,
        ),
        for (final folder in library.folders)
          (
            _Folder(folder.id),
            ReelishIcons.stack,
            folder.name,
            collection.folderId == folder.id,
          ),
        (const _NewFolder(), ReelishIcons.add, 'New folder', false),
      ],
    );
    if (destination == null || !context.mounted) return;
    String? folderId;
    switch (destination) {
      case _TopLevel():
        folderId = null;
      case _Folder(:final id):
        folderId = id;
      case _NewFolder():
        final folder = await createFolder(context, store);
        if (folder == null || !context.mounted) return;
        folderId = folder.id;
    }
    final name = folderId == null
        ? 'My library'
        : store.library.folder(folderId)?.name ?? 'the folder';
    await _run(
      context,
      () => store.moveCollection(collection.id, folderId),
      done: 'Moved to $name',
    );
  }

  /// The collection's menu: edit, move, reorder and delete. [onDeleted]
  /// runs once it is gone (a page showing it closes).
  static Future<void> manage(
    BuildContext context,
    CollectionStore store,
    MediaCollection collection, {
    VoidCallback? onDeleted,
  }) async {
    final siblings = store.library.collectionsIn(collection.folderId);
    final index = siblings.indexWhere((c) => c.id == collection.id);
    final action = await _choose<_CollectionAction>(
      context,
      title: collection.name,
      options: [
        (_CollectionAction.edit, ReelishIcons.edit, 'Edit name', false),
        (_CollectionAction.move, ReelishIcons.stack, 'Move to folder', false),
        if (store.library.countOf(collection.id) > 0)
          (_CollectionAction.cover, ReelishIcons.star, 'Choose cover', false),
        if (index > 0)
          (_CollectionAction.earlier, ReelishIcons.arrowUp, 'Move up', false),
        if (index >= 0 && index < siblings.length - 1)
          (_CollectionAction.later, ReelishIcons.arrowDown, 'Move down', false),
        (_CollectionAction.delete, ReelishIcons.trash, 'Delete', false),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _CollectionAction.edit:
        await edit(context, store, collection);
      case _CollectionAction.move:
        await move(context, store, collection);
      case _CollectionAction.cover:
        await chooseCover(context, store, collection);
      case _CollectionAction.earlier:
        await _run(context, () => store.reorderCollection(collection.id, -1));
      case _CollectionAction.later:
        await _run(context, () => store.reorderCollection(collection.id, 1));
      case _CollectionAction.delete:
        if (await delete(context, store, collection)) onDeleted?.call();
    }
  }

  /// Which title's poster heads the collection, or the newest titles'.
  static Future<void> chooseCover(
    BuildContext context,
    CollectionStore store,
    MediaCollection collection,
  ) async {
    final entries = store.library.entriesOf(
      collection.id,
      sort: CollectionSort.title,
    );
    // Wrapped, so "Newest titles" (no title) differs from a dismissed list.
    final choice = await _choose<(MediaItem?,)>(
      context,
      title: 'Cover for ${collection.name}',
      options: [
        (
          (null,),
          ReelishIcons.sparkle,
          'Newest titles',
          collection.cover.isEmpty,
        ),
        for (final entry in entries)
          (
            (entry.item,),
            entry.type == 'series' ? ReelishIcons.tv : ReelishIcons.movie,
            entry.name,
            entry.titleKey == collection.cover,
          ),
      ],
    );
    if (choice == null || !context.mounted) return;
    await _run(context, () => store.setCover(collection.id, choice.$1));
  }

  /// Asks whether to make a collection or a folder, then makes it. Returns
  /// the new [MediaCollection] or [CollectionFolder], or null.
  static Future<Object?> createAny(
    BuildContext context,
    CollectionStore store,
  ) async {
    final collection = await _choose<bool>(
      context,
      title: 'Create',
      options: [
        (true, ReelishIcons.playlist, 'New collection', false),
        (false, ReelishIcons.stack, 'New folder', false),
      ],
    );
    if (collection == null || !context.mounted) return null;
    return collection ? create(context, store) : createFolder(context, store);
  }

  static Future<CollectionFolder?> createFolder(
    BuildContext context,
    CollectionStore store,
  ) async {
    final input = await _CollectionForm.show(
      context,
      title: 'New folder',
      action: 'Create',
      withDescription: false,
    );
    if (input == null || !context.mounted) return null;
    return _attempt(context, () => store.createFolder(input.name));
  }

  /// The folder's menu: rename, reorder and delete. [onDeleted] runs once
  /// it is gone.
  static Future<void> manageFolder(
    BuildContext context,
    CollectionStore store,
    CollectionFolder folder, {
    VoidCallback? onDeleted,
  }) async {
    final folders = store.library.folders;
    final index = folders.indexWhere((f) => f.id == folder.id);
    final action = await _choose<_FolderAction>(
      context,
      title: folder.name,
      options: [
        (_FolderAction.rename, ReelishIcons.edit, 'Rename', false),
        if (index > 0)
          (_FolderAction.earlier, ReelishIcons.arrowUp, 'Move up', false),
        if (index >= 0 && index < folders.length - 1)
          (_FolderAction.later, ReelishIcons.arrowDown, 'Move down', false),
        (_FolderAction.delete, ReelishIcons.trash, 'Delete folder', false),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _FolderAction.rename:
        final input = await _CollectionForm.show(
          context,
          title: 'Rename folder',
          action: 'Save',
          name: folder.name,
          withDescription: false,
        );
        if (input == null || !context.mounted) return;
        await _run(context, () => store.renameFolder(folder.id, input.name));
      case _FolderAction.earlier:
        await _run(context, () => store.reorderFolder(folder.id, -1));
      case _FolderAction.later:
        await _run(context, () => store.reorderFolder(folder.id, 1));
      case _FolderAction.delete:
        if (await deleteFolder(context, store, folder)) onDeleted?.call();
    }
  }

  /// Deletes a folder, keeping its collections unless the viewer chooses
  /// otherwise. True once it is gone.
  static Future<bool> deleteFolder(
    BuildContext context,
    CollectionStore store,
    CollectionFolder folder,
  ) async {
    final inside = store.library.collectionsIn(folder.id).length;
    bool? withCollections = false;
    if (inside == 0) {
      if (!await confirm(
        context,
        title: 'Delete ${folder.name}?',
        message: 'The folder is empty.',
        action: 'Delete',
      )) {
        return false;
      }
    } else {
      withCollections = await _choose<bool>(
        context,
        title: 'Delete ${folder.name}?',
        message:
            'It holds $inside ${inside == 1 ? 'collection' : 'collections'}.',
        options: [
          (
            false,
            ReelishIcons.library,
            'Delete folder, keep collections in My library',
            false,
          ),
          (
            true,
            ReelishIcons.trashForever,
            'Delete folder and its collections',
            false,
          ),
        ],
      );
      if (withCollections == null) return false;
      if (withCollections &&
          context.mounted &&
          !await confirm(
            context,
            title:
                'Delete $inside ${inside == 1 ? 'collection' : 'collections'}?',
            message:
                'The collections in ${folder.name} are deleted too. The '
                'titles in them stay on My list and in your history.',
            action: 'Delete all',
          )) {
        return false;
      }
    }
    if (!context.mounted) return false;
    return _run(
      context,
      () => store.deleteFolder(folder.id, withCollections: withCollections!),
      done: '${folder.name} deleted',
    );
  }

  /// Which collections [item] is in, changed with each tick and saved at
  /// once; a new collection can be made from here too.
  static Future<void> addToCollections(
    BuildContext context,
    CollectionStore store,
    MediaItem item,
  ) => showDialog<void>(
    context: context,
    builder: (_) => _AddToCollectionsDialog(store: store, item: item),
  );

  /// Asks before something is deleted; Cancel has focus, so Select or
  /// Enter never deletes by accident.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: GlassTheme.elevatedSurface,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: GlassTheme.coralBright,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  /// A list of choices; the one marked current shows a tick.
  static Future<T?> _choose<T>(
    BuildContext context, {
    required String title,
    String? message,
    required List<(T, IconData, String, bool)> options,
  }) => showDialog<T>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: GlassTheme.elevatedSurface,
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    message,
                    style: TextStyle(color: GlassTheme.muted),
                  ),
                ),
              for (final (index, (value, icon, label, current))
                  in options.indexed)
                ListTile(
                  autofocus: index == 0,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(icon, color: GlassTheme.primary),
                  title: Text(label),
                  trailing: current
                      ? Icon(ReelishIcons.check, color: GlassTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  /// Runs [change], saying why if it fails, and [done] if it worked.
  /// True when it worked.
  static Future<bool> _run(
    BuildContext context,
    Future<void> Function() change, {
    String? done,
  }) async =>
      (await _attempt(context, () async {
        await change();
        return true;
      }, done: done)) ??
      false;

  /// As [_run], with what [change] returns; null when it failed.
  static Future<T?> _attempt<T extends Object>(
    BuildContext context,
    Future<T> Function() change, {
    String? done,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await change();
      if (done != null) {
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(done)));
      }
      return result;
    } on CollectionInputError catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Could not save that. Try again.')),
        );
    }
    return null;
  }
}

/// A name, and optionally a description, for a collection or folder.
class _CollectionForm extends StatefulWidget {
  const _CollectionForm({
    required this.title,
    required this.action,
    required this.name,
    required this.description,
    required this.withDescription,
  });

  final String title, action, name, description;
  final bool withDescription;

  static Future<({String name, String description})?> show(
    BuildContext context, {
    required String title,
    required String action,
    String name = '',
    String description = '',
    bool withDescription = true,
  }) => showDialog<({String name, String description})>(
    context: context,
    builder: (_) => _CollectionForm(
      title: title,
      action: action,
      name: name,
      description: description,
      withDescription: withDescription,
    ),
  );

  @override
  State<_CollectionForm> createState() => _CollectionFormState();
}

class _CollectionFormState extends State<_CollectionForm> {
  late final _name = TextEditingController(text: widget.name);
  late final _description = TextEditingController(text: widget.description);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    Navigator.pop(context, (name: name, description: _description.text));
  }

  /// On a TV remote, Up and Down leave a field for the next control rather
  /// than moving the caret, so the dialog's buttons can be reached.
  Widget _field(Widget field) {
    if (!DeviceCapabilities.isTv) return field;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowDown => TraversalDirection.down,
          LogicalKeyboardKey.arrowUp => TraversalDirection.up,
          _ => null,
        };
        if (direction == null) return KeyEventResult.ignored;
        (FocusManager.instance.primaryFocus ?? node).focusInDirection(
          direction,
        );
        return KeyEventResult.handled;
      },
      child: field,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: GlassTheme.elevatedSurface,
    title: Text(widget.title),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field(
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: CollectionStore.maxNameLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: widget.withDescription
                  ? TextInputAction.next
                  : TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _error,
                counterText: '',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: widget.withDescription ? null : (_) => _submit(),
            ),
          ),
          if (widget.withDescription) ...[
            const SizedBox(height: 12),
            _field(
              TextField(
                controller: _description,
                maxLength: CollectionStore.maxDescriptionLength,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  counterText: '',
                ),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.action)),
    ],
  );
}

class _AddToCollectionsDialog extends StatelessWidget {
  const _AddToCollectionsDialog({required this.store, required this.item});

  final CollectionStore store;
  final MediaItem item;

  Future<void> _toggle(BuildContext context, String id, bool add) async {
    try {
      await store.setMembership(
        item,
        add: add ? {id} : const {},
        remove: add ? const {} : {id},
      );
    } on CollectionInputError catch (error) {
      if (context.mounted) _say(context, error.message);
    } catch (_) {
      if (context.mounted) _say(context, 'Could not save that. Try again.');
    }
  }

  void _say(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: GlassTheme.elevatedSurface,
    title: Text(
      'Add ${item.name} to',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
    content: SizedBox(
      width: 440,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final library = store.library;
          final member = library.collectionsWith(item);
          final collections = [
            // Grouped as the library shows them: the top level, then each
            // folder's collections.
            ...library.collectionsIn(null),
            for (final folder in library.folders)
              ...library.collectionsIn(folder.id),
          ];
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  autofocus: collections.isEmpty,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(ReelishIcons.add, color: GlassTheme.primary),
                  title: const Text('New collection'),
                  onTap: () => unawaited(
                    CollectionActions.create(context, store, first: item),
                  ),
                ),
                if (!store.loaded && store.account != null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                for (final (index, collection) in collections.indexed)
                  CheckboxListTile(
                    autofocus: index == 0,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: GlassTheme.primary,
                    value: member.contains(collection.id),
                    title: Text(
                      collection.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (collection.folderId != null)
                          library.folder(collection.folderId!)?.name ?? '',
                        _titles(library.countOf(collection.id)),
                      ].where((part) => part.isNotEmpty).join(' · '),
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                    onChanged: (value) =>
                        unawaited(_toggle(context, collection.id, value!)),
                  ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}

String _titles(int count) => '$count ${count == 1 ? 'title' : 'titles'}';
