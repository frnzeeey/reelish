# Contributing to Reelish

Thanks for helping. Reelish ships to Android phones and tablets, Android TV
and Google TV, and Windows from one codebase, so most changes reach more
than one platform.

## Before you start

1. Read [onboarding](docs/development/onboarding.md) and the
   [architecture overview](docs/architecture/architecture-overview.md).
2. Set up the project: [getting started](docs/development/getting-started.md).
   You need your own TMDB API key in `lib/tmdb_config.local.dart`; never
   commit it.
3. Find the code for your change in the
   [feature index](docs/features/feature-index.md) or the
   [codebase index](docs/codebase/codebase-index.md).

## Rules

The full list is in [`CLAUDE.md`](CLAUDE.md) and the
[coding standards](docs/development/coding-standards.md). The essentials:

- **Keep platforms separate.** Change the platform's own widgets; a change
  to shared code must be inert elsewhere, and say so.
- **Don't touch playback or provider execution casually.** Engine
  selection, source preparation, headers, redirects and the sandbox limits
  change only with a verified cause and tests.
- **Treat provider output as untrusted.** Never weaken the network policy,
  the QuickJS limits, script approval or update verification.
- **Keep viewers' data readable.** Stored keys and JSON shapes stay
  loadable.
- **No secrets** in code, logs or docs. No full stream URLs or headers in
  logs.
- **Focused changes.** No unrelated refactors, repository-wide formatting
  or new dependencies without agreement.

## Making a change

1. Write or extend a test that shows the problem or the new behaviour.
2. Make the change in the narrowest place.
3. Validate (details in the [testing guide](docs/development/testing-guide.md#before-a-commit)):

   ```sh
   dart format <the files you changed>
   flutter analyze lib test integration_test test_driver
   flutter test
   flutter build apk --profile        # if Android can be affected
   flutter build windows --release    # if Windows can be affected
   ```

4. Update the documentation in the same change
   ([documentation standards](docs/maintenance/documentation-standards.md)):

   ```sh
   dart run tool/docs/docs_tool.dart generate
   dart run tool/docs/docs_tool.dart check
   ```

5. In the pull request, say what changed, why, what you tested and on which
   platforms, and what you could not verify.

## Releases

Releases are made only by CI from a version tag; see
[`docs/releasing.md`](docs/releasing.md). Never publish a build by hand.
