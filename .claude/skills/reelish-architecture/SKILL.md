---
name: reelish-architecture
description: Map of Reelish's code — modules, data flow, platform split and where each feature lives. Use before any non-trivial change, when locating code for a feature, or when unsure whether something is shared between phone, TV and Windows.
---

# Reelish architecture

## Purpose
Give an accurate, verified starting map so changes land in the right layer
and on the right platform. Outcome: you know which files own the behaviour
you are about to touch, and what else depends on them.

## Activation
- Starting work in an unfamiliar area, or a task that spans layers.
- Deciding whether a change belongs in shared code or one platform's UI.
- Another skill sends you here for orientation.

## Codebase context
Read [architecture.md](architecture.md) for the module map, data flow and
platform matrix. It references real files; open them rather than trusting
the summary when details matter.

## Workflow
1. Find the feature's owner in `architecture.md` (UI layer, ViewModel,
   service, model).
2. Open those files and confirm the behaviour in code. `grep` for the class
   to find every caller, including other platforms' UI.
3. Note which platforms reach the code path (see the platform matrix).
4. Choose the narrowest layer that can make the change: a platform UI file
   before a shared widget, a ViewModel before a service, a service before a
   model.
5. Hand off to the specialised skill (playback, providers, UI, Windows,
   security, performance) for the change itself.

## Safety constraints
- `home_screen.dart` is large and holds wiring for all three interfaces
  (`_buildDesktop`, `_buildTv`, the phone tabs). Edit it surgically.
- Models and `StorageService` define persisted shapes; keep them backward
  compatible.
- The vendored packages (`packages/`, `third_party/flutter_js`) carry
  Reelish-specific patches; read their notes before editing.

## Platform considerations
See the platform matrix in `architecture.md`. The common mistake is using
`usesTvLayout` (TV **and** Windows) where `isTv` (TV hardware) was meant.

## Validation
Orientation only. Validate the eventual change with `regression-check`.

## Completion criteria
You can name the files that own the behaviour, every platform that reaches
it, and the tests that cover it (`test/` names follow the feature).

## Reporting
State which layer you changed and why that layer, per CLAUDE.md § Reporting.
