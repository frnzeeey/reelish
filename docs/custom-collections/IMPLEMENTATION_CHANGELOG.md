# Custom collections: implementation changelog

## Phase 1 — local collections (2026-11-13)

### Files created

| File | Purpose |
|---|---|
| `lib/src/collections/collection_models.dart` | `CollectionFolder`, `MediaCollection`, `CollectionEntry`, `CollectionSort`, `CollectionLibrary` |
| `lib/src/collections/collection_store.dart` | `CollectionStore`: per-account storage, one write queue, validation, deletion marks |
| `lib/src/collections/smart_collections.dart` | `SmartCollection`, `SmartCollections.of`, `CollectionTarget` |
| `lib/src/widgets/collections/collection_actions.dart` | Shared dialogs: create, edit, move, cover, reorder, delete, Add to collections |
| `lib/src/widgets/collections/collection_cover.dart` | Poster-shaped cover: up to four posters, or an icon |
| `lib/src/screens/collections/collection_pages.dart` | Phone: Library section and the collection, smart and folder pages |
| `lib/src/screens/tv/tv_collections.dart` | TV: library row, tiles and pages |
| `lib/src/desktop/desktop_collections.dart` | Windows: library section, tiles and pages |
| `test/custom_collections_test.dart` | 31 tests ([test report](CUSTOM_COLLECTIONS_TEST_REPORT.md)) |
| `docs/custom-collections/*` | These documents |

### Files changed

| File | Change |
|---|---|
| `lib/src/models/media_item.dart` | Optional `savedAt` (when added to My list) |
| `lib/src/services/storage_service.dart` | `toggleFavorite` dates new My list titles; Trakt additions stay undated |
| `lib/src/account/account_history.dart` | Points `CollectionStore` at the signed-in account |
| `lib/src/viewmodels/library_view_model.dart` | `collections`, `collectionStore`, cached `smart(kind)` |
| `lib/src/screens/library_screen.dart` | Collections chip and section |
| `lib/src/screens/tv/tv_pages.dart` | Collections row in the TV library |
| `lib/src/desktop/desktop_pages.dart` | Collections section in the Windows library |
| `lib/src/screens/media_details_screen.dart`, `lib/src/screens/tv/tv_details_screen.dart`, `lib/src/desktop/desktop_details_screen.dart` | Collections button (`onCollections`), shown only when given |
| `lib/src/screens/home_screen.dart` | Passes `onCollections` to the three details pages |
| `docs/README.md` | Links to these documents |

### Existing behaviour preserved

- My list, its hearts, its Library row and its Trakt watchlist sync are
  unchanged; the My list smart collection reads the same list.
- Library rows keep their order and focus: Collections comes after the
  watch history on every interface.
- Details pages show the new button only when `onCollections` is given, so
  other callers and tests are unaffected.
- Playback, sources and the player are untouched.
- My list entries saved before `savedAt` load as before.

### Decisions

- Folders one level deep; title cards stored with the entry; Trakt not used;
  sync in Phase 2 through the Reelish API + D1 (user decisions).
- Entry key `collectionId|type:id`: no duplicates, on one device or after
  sync.
- Deletions kept as marks for 400 days, ready for sync.
- Four smart collections; Currently watching and Recently watched already
  exist as rows ([specification](SMART_COLLECTIONS_SPECIFICATION.md)).
- Collection pages are pushed routes like details pages, so Back works the
  same everywhere.
- No new icons: folders use `stack`, collections `playlist`, smart
  collections `sparkle` (a folder glyph would need the icon font
  regenerated).

### Dependencies

None added.

### Known limitations

- **Sync**: in Phase 1 collections stayed on the device where they were
  made; Phase 2 below adds sync.
- **History cap**: Not started and Finished read the last 50 history titles.
- **Titles in a collection** follow the chosen sort; there is no manual
  order and no drag and drop.
- **Card data** is copied when a title is added; a changed TMDB poster shows
  on the details page but not on the collection card until the title is
  added again.
- **On TV and Windows**, a title is removed from a collection through its
  details page (Collections), not from the collection grid.
- **Adding to a collection** is on details pages only, not on every card.
- **My list** is still per device, not per account.

### Validation

`flutter test` 1382 passed, 4 skipped; `flutter analyze` 15 info, no
warnings; docs check passed; `flutter build windows --release` and
`flutter build apk --profile` built. No device run.

## Phase 2 — sync across devices (2026-11-13)

Design and ordering: [sync strategy](COLLECTION_SYNC_STRATEGY.md).

### Files created

| File | Purpose |
|---|---|
| `backend/migrations/0012_collection_records.sql` | `collection_records` table and its pull index |
| `backend/src/collections.ts` | `POST/GET /collections`: validation, newest-wins upsert, paged pull, prune of old deletion marks |
| `backend/test/collections.test.ts` | 10 tests |
| `lib/src/account/collection_sync.dart` | `CollectionSync`: outbox, push/pull, clock offset, retries, first-sync upload |
| `test/collection_sync_test.dart` | 9 tests against a fake API with the server's rule |

### Files changed

| File | Change |
|---|---|
| `backend/src/index.ts` | Routes under `SYNC_LIMITER`; prune in the daily cron |
| `lib/src/collections/collection_store.dart` | `onRecordsChanged`, `recordTimes`, `record`, `applySynced`; a title whose collection has not arrived yet is kept |
| `lib/src/collections/collection_models.dart` | `SyncedKind`, `SyncedRecord` |
| `lib/src/account/account_api.dart` | `pushCollections`, `pullCollections` |
| `lib/main.dart` | Attaches `CollectionSync` after `ProgressSync` |
| `lib/src/screens/legal_information_screen.dart` | Privacy policy: *Your collections across your devices*; account deletion lists collections |
| `lib/src/support/help_content.dart` | Help: *How do I make my own collections?* |
| `docs/backend/README.md` | Routes and table |

### Decisions

- One row per record (folder, collection, title in a collection), ordered
  per record as playback progress is, so edits to different records on
  different devices never overwrite each other.
- The server stores a body rebuilt from checked fields, never the device's
  JSON; a deletion keeps no name or title.
- Push 10 s after editing stops (collections change in bursts), and when
  the app is hidden; pull at start, sign-in and return to the app.
- Sync is on for every signed-in account; there is no setting.

### Dependencies

None added.

### Known limitations

See the [sync strategy](COLLECTION_SYNC_STRATEGY.md#limitations): clock
correction only after first contact, no live updates while the app stays
open, a deleted collection's title rows kept on the server until the
account is deleted, no per-account record cap.

### Deployment

Staging: migration `0012` applied and the Worker deployed on 2026-11-13
(version e97030b6; `/health` answers, `/api/v1/collections` answers 401
without a session). Production: not touched; apply migration `0012` and
deploy production before a release that includes the app side.
