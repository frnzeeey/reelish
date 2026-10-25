# Adding a feature

A path that fits how the code is built. Read the
[architecture overview](../architecture/architecture-overview.md) first.

## 1. Decide where it lives

| The feature is… | Put it in |
|---|---|
| Data or rules (TMDB, storage, providers, playback policy) | A service in [`lib/src/services/`](../../lib/src/services) and models in [`lib/src/models/`](../../lib/src/models) |
| Screen state shared by several interfaces | A `ChangeNotifier` in [`lib/src/viewmodels/`](../../lib/src/viewmodels) |
| Phone UI | [`lib/src/screens/`](../../lib/src/screens), [`lib/src/widgets/`](../../lib/src/widgets) |
| TV UI | [`lib/src/screens/tv/`](../../lib/src/screens/tv), [`lib/src/widgets/tv/`](../../lib/src/widgets/tv) |
| Windows UI | [`lib/src/desktop/`](../../lib/src/desktop) |
| The player | [`lib/src/widgets/player/`](../../lib/src/widgets/player), keeping the touch, remote and desktop paths separate |
| Native behaviour | A method on an existing channel (`MainActivity.kt`, `windows/runner/`) and a thin Dart wrapper in [`lib/src/platform/`](../../lib/src/platform) |

A feature that exists on every platform usually means one service or view
model and up to three thin widgets.

## 2. Wire it

- Long-lived services are created in `AppServices`
  ([`app_services.dart`](../../lib/src/app/app_services.dart)) and handed
  down; don't construct services inside widgets.
- New top-level places for TV and Windows go in `TvDestination`
  ([`app_destination.dart`](../../lib/src/navigation/app_destination.dart))
  and both shells; phone tabs are in `HomeScreen`.
- Push new pages with `AppPageRoute`.
- Persisted data goes through `StorageService` with a new, versioned key
  (and an entry in the
  [configuration reference](../reference/configuration-reference.md#stored-data)).

## 3. Keep the guarantees

- Async work checks a generation or `mounted`; listeners and controllers
  are disposed.
- Untrusted input is validated (URLs through `NetworkDestinationValidator`).
- Nothing logs URLs, headers or secrets; logs are debug-only.
- Reduced motion turns animations off; TV keeps everything reachable by
  D-pad with visible focus; Windows works with mouse, keyboard and
  controller.

## 4. Test it

Unit-test the service or view model; widget-test each interface's layout
rules (no overflow at real sizes, focus order, hover); add an integration
test when it needs a real engine or runtime. See the
[testing guide](testing-guide.md).

## 5. Document it

Add the feature to the [feature index](../features/feature-index.md), give
new files a leading comment or a `///` on their main type, regenerate the
references (`dart run tool/docs/docs_tool.dart generate`) and run `check`.
See [documentation standards](../maintenance/documentation-standards.md).
