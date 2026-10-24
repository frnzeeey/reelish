---
name: release-validation
description: Release Reelish to GitHub — check the tree, bump the version, tag, watch the Android and Windows release workflows, verify the six assets, and add What's new / Fixes notes. Use only when the user asks for a release.
disable-model-invocation: true
argument-hint: "[version, e.g. 1.16.2]"
---

# Release validation

## Purpose
Publish a release exactly the way `docs/releasing.md` defines, and confirm
it landed. Outcome: tag pushed, both workflows green, six assets attached,
user-facing notes at the top of the release.

## Activation
Only on an explicit request ("release", "publish to GitHub"). A release is
public and the in-app updaters offer it to installed copies.

## Codebase context
- `docs/releasing.md`: the pipeline and rules (single version source,
  tags never reused).
- `.github/workflows/release.yml`: validates, analyzes, tests, builds and
  signs the APK, creates the release (`reelish.apk` + `.sha256`).
- `.github/workflows/release-windows.yml`: builds and test-installs
  `Reelish-Setup-x64.exe` and `Reelish-Windows-x64.zip` (+ `.sha256`),
  then attaches them once the release exists.
- `pubspec.yaml` `version: MAJOR.MINOR.PATCH+BUILD`, with
  `BUILD = MAJOR*1000000 + MINOR*1000 + PATCH`.

## Workflow
1. `git fetch origin`; on `main`, `git status --short` empty except the
   work being released, and `HEAD == origin/main` after pushing. The user
   may already have committed the work; check `git log` before committing
   again.
2. Pick the version: patch for fixes/refinements, minor for new features.
   It must be higher than the latest tag (`git tag --sort=-v:refname`).
3. Run `regression-check` if the work was not validated in this session.
4. Commit work (if any) with a descriptive message, then the bump alone:
   `Release vX.Y.Z`. Use the commit attribution the session specifies.
5. `git push origin main`; tag the same commit:
   `git tag -a vX.Y.Z -m "Reelish vX.Y.Z"`; check
   `git rev-parse HEAD 'vX.Y.Z^{commit}'` match; `git push origin vX.Y.Z`.
6. Watch both runs (`gh run list`, `gh run watch <id> --exit-status`).
7. Verify assets: `gh release view vX.Y.Z --json assets` lists
   `reelish.apk`, `reelish.apk.sha256`, `Reelish-Setup-x64.exe`,
   `Reelish-Setup-x64.exe.sha256`, `Reelish-Windows-x64.zip`,
   `Reelish-Windows-x64.zip.sha256`.
8. Write notes for users (not developers): `## What's new` and `## Fixes`,
   each item "**Area:** what changed for the viewer", platform named when
   it is platform-specific. Prepend them to the generated body (keep the
   version, commit, SHA-256 and changelog lines):
   `gh release view vX.Y.Z --json body -q .body > body.md`, concatenate,
   `gh release edit vX.Y.Z --notes-file full.md`.

## Safety constraints
- Never move, delete or reuse a pushed tag; on failure fix on `main`, bump
  the patch, tag again.
- Never upload APKs or installers by hand or build with version overrides.
- Don't skip CI checks or hooks; don't force-push `main`.
- Notes must not include secrets, internal URLs or the user's email.

## Platform considerations
Android (phone and TV) and Windows ship from the same tag; a Windows
failure leaves the Android release published (re-run
`release-windows.yml` with `release_tag`).

## Validation
Both workflows succeeded, six assets present, release marked Latest
(`gh release list --limit 1`), notes rendered.

## Completion criteria
All of Validation true; the release URL known.

## Reporting
Release URL, version, commits included, workflow results, assets, and the
notes as published.
