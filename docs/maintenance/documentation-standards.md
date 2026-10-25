# Documentation standards

How the documentation stays accurate. It has two kinds of pages:

- **Generated references**, in [`docs/codebase/`](../codebase):
  `file-reference.md`, `class-reference.md`, `function-reference.md` and
  `dependency-map.md`. They are produced from the source by
  [`tool/docs/docs_tool.dart`](../../tool/docs/docs_tool.dart) and never
  edited by hand.
- **Hand-written guides**: everything else. They explain how and why, and
  link to the generated references for exact names and lines.

## Rule

Update the documentation **in the same change** as the code. A change that
adds, renames, moves or removes code, or changes behaviour, is not finished
until `dart run tool/docs/docs_tool.dart check` passes.

## Checklist

When you…

- **add a file:** give it a leading `//` comment or a `///` doc comment on
  the type it is named after. If neither fits, add an entry to
  `_curatedPurposes` in the tool. Then regenerate.
- **add a class, service or public method:** write a `///` doc comment
  whose first sentence says what it is or does; regenerate.
- **rename or move a file or component:** regenerate; fix links in the
  hand-written pages (`check` reports broken links and missing paths).
- **add a feature:** add it to the [feature index](../features/feature-index.md)
  (table row and section), and to the platform pages it affects.
- **change an important function's behaviour:** update the guide that
  describes it (playback, providers, data flow).
- **change the architecture:** update the
  [architecture overview](../architecture/architecture-overview.md), its
  diagrams, and [design patterns](../architecture/design-patterns.md).
- **add a dependency:** add it to
  [third-party dependencies](../reference/third-party-dependencies.md).
- **add or change stored data or configuration:** update the
  [configuration reference](../reference/configuration-reference.md).
- **change platform behaviour:** update the page in
  [`docs/platforms/`](../platforms) and the matrix in
  [platform architecture](../architecture/platform-architecture.md).
- **replace a playback engine:** update
  [player engines](../playback/platform-player-engines.md), the
  [playback architecture](../playback/playback-architecture.md) and the
  [troubleshooting guide](../playback/troubleshooting.md).
- **add a page:** link it from [`docs/README.md`](../README.md); `check`
  fails for an unlinked page.

## What `check` verifies

`dart run tool/docs/docs_tool.dart check` exits non-zero when:

- a generated reference is missing or differs from what the source
  produces (so stale line numbers and removed symbols are caught);
- a relative Markdown link in `README.md`, `CONTRIBUTING.md` or `docs/`
  points at a file or folder that does not exist;
- a backticked repository path (`lib/…`, `test/…`, `docs/…` and other
  top-level folders) does not exist;
- a page under `docs/` is not linked from `docs/README.md`;
- a `lib/` file has no purpose, or `_curatedPurposes` names a file that no
  longer exists.

Alphabetical order and duplicate entries in the references are guaranteed
by construction (they are sorted and generated from one parse). The
hand-written A–Z tables ([codebase index](../codebase/codebase-index.md),
[feature index](../features/feature-index.md),
[directory reference](../codebase/directory-reference.md)) are kept in
order by hand.

The tool needs only the Dart SDK and adds nothing to the app. It is not
run by CI; running it there is a one-line addition to the release
workflows if wanted.

## Writing style

- Say exactly what the code does, with its names: "`saveProgress` writes
  the history entry every 15 s", not "handles progress".
- Link to code with repository-relative links; prefer symbol names to line
  numbers in hand-written pages (the generated references carry lines).
- Keep secrets out: no API keys, passwords, tokens or signing material;
  show placeholders (`YOUR_TMDB_API_KEY`).
- Mark anything not verified as **Needs verification** instead of
  guessing.
- Audit reports are records of a point in time: start them with a note
  that they describe the codebase as it was, and don't update them later.
