# Reelish documentation

Technical documentation for developers and AI coding assistants. For what
Reelish is and how to install it, see the root [README](../README.md).

**New here?** Start with [onboarding](development/onboarding.md), then the
[architecture overview](architecture/architecture-overview.md).

**Looking for something specific?** Use the
[codebase index](codebase/codebase-index.md) for the main components, or
search the generated references below: every file, class and function in
`lib/` is listed A–Z with its location.

## Architecture

| Page | What it covers |
|---|---|
| [Architecture overview](architecture/architecture-overview.md) | Layers, startup, choosing the interface, navigation, state; diagrams |
| [Data flow](architecture/data-flow.md) | Catalog rows, library and Continue watching, details, search, settings |
| [Design patterns](architecture/design-patterns.md) | The patterns the code uses and why |
| [Platform architecture](architecture/platform-architecture.md) | Shared versus per-platform code, the platform matrix, native channels |

## Codebase reference

| Page | What it covers |
|---|---|
| [Codebase index](codebase/codebase-index.md) | The main components, A–Z |
| [Directory reference](codebase/directory-reference.md) | Every folder, A–Z |
| [File reference](codebase/file-reference.md) | *Generated.* Every `lib/` file: purpose, declarations, imports, importers, tests |
| [Class reference](codebase/class-reference.md) | *Generated.* Every type, A–Z: role, location, relations, reach |
| [Function reference](codebase/function-reference.md) | *Generated.* Functions and methods, A–Z, with signatures |
| [Dependency map](codebase/dependency-map.md) | *Generated.* Folder graph, most depended-on files, package usage |

## Features

| Page | What it covers |
|---|---|
| [Feature index](features/feature-index.md) | Every feature mapped to its code, data and tests |
| [Caching](features/caching.md) | TMDB response and artwork caches: policies, decision, measurements |
| [Usage statistics](features/analytics.md) | Opt-in Firebase Analytics on Android: events, privacy, setup, DebugView, cost |
| [Account badges](backend/badges.md) | Founder and Supporter: where each comes from, and why neither is a permission |
| [Entitlements](backend/entitlements.md) | Free, Supporter and Founder: one rule for every supporter perk, and how to add one |
| [Supporters](backend/supporters.md) | The Supporter Badge: Buy Me a Coffee webhooks, supporter codes, reviews, setup |
| [App themes](features/supporter-themes.md) | Supporter app themes: the accent and profile they set, entitlement, saving, rendering |
| [App icons](features/app-icons.md) | Launcher icon switching, the free and supporter icons, and their assets |
| [Launch screen](features/launch-screen.md) | The system and Flutter splash on each platform, and the Founder's Sovereign Crest splash |
| [Avatar frames](features/avatar-frames.md) | The Supporter avatar frame collection, the Founder's Sovereign frame, limited editions, and how they are drawn |
| [Avatar frames API](backend/frames.md) | Who may wear which frame, cross-device sync, limited-edition collecting, Watch Party |
| [Trakt profile](features/trakt-profile.md) | The Trakt username and avatar on every device: storage, refresh, failures, cost |
| [Icon system](design/icon-system.md) | Reelish's own icons: design rules, solid forms, how to add one, the gallery |
| [Content advisory](features/content-advisory.md) | The age rating card at playback start: TMDB coverage, sourcing rules, behaviour |
| [Crash reporting](features/crash-reporting.md) | Opt-in Crashlytics on Android, the Windows error log, what is reported, testing, symbols |
| [Personalised discovery](personalized-discovery/PERSONALIZED_DISCOVERY_ARCHITECTURE.md) | On-device recommendations: audit, components, data flow, cold start, limits |
| [Recommendation scoring](personalized-discovery/RECOMMENDATION_SCORING_MODEL.md) | Viewing status, weights, genre affinity, seeds, score terms, rows, diversity, feedback |
| [Personalisation data](personalized-discovery/PERSONALIZATION_DATA_MODEL.md) | What is stored per account, JSON shapes, account isolation, privacy, sync analysis |
| [Discovery TMDB usage](personalized-discovery/TMDB_API_OPTIMIZATION.md) | Requests per refresh, caching, bounding, failure handling |
| [Discovery test report](personalized-discovery/PERSONALIZED_DISCOVERY_TEST_REPORT.md) | Scenarios, results, what was not verified |
| [Discovery changelog](personalized-discovery/IMPLEMENTATION_CHANGELOG.md) | Files created and changed, decisions, follow-ups |
| [Continue watching](intelligent-continue-watching/CONTINUE_WATCHING_ARCHITECTURE.md) | Progress checkpoints, resume, completion, up next, start over, per-account history; diagrams |
| [Playback progress data](intelligent-continue-watching/PLAYBACK_PROGRESS_DATA_MODEL.md) | Stored keys and JSON shapes, derived rules, the per-account migration |
| [Cross-device sync](intelligent-continue-watching/CROSS_DEVICE_SYNC_STRATEGY.md) | Sync through the Reelish API: ordering, conflicts, offline outbox, free-tier budget |
| [Continue watching tests](intelligent-continue-watching/CONTINUE_WATCHING_TEST_REPORT.md) | Tests, results, what was not verified |
| [Continue watching changelog](intelligent-continue-watching/IMPLEMENTATION_CHANGELOG.md) | Files created and changed, decisions, limitations |
| [Custom collections](custom-collections/CUSTOM_COLLECTIONS_ARCHITECTURE.md) | Collections, folders and smart collections on phone, TV and Windows; data and UI flow |
| [Collection data](custom-collections/COLLECTION_DATA_MODEL.md) | Stored records and JSON shape, constraints, ordering, deletion marks, migration |
| [Collection sync](custom-collections/COLLECTION_SYNC_STRATEGY.md) | Local-first storage and sync through the Reelish API: ordering, conflicts, Trakt, free-tier budget |
| [Smart collections](custom-collections/SMART_COLLECTIONS_SPECIFICATION.md) | Recently added, My list, Not started, Finished: sources, rules, edge cases |
| [Collections tests](custom-collections/CUSTOM_COLLECTIONS_TEST_REPORT.md) | Tests, results, what was not verified |
| [Collections changelog](custom-collections/IMPLEMENTATION_CHANGELOG.md) | Files created and changed, decisions, limitations |

## Playback

| Page | What it covers |
|---|---|
| [Playback architecture](playback/playback-architecture.md) | The pipeline from Play to picture, the play request flow, recovery |
| [Playback lifecycle](playback/playback-lifecycle.md) | The player session: opening, playing, subtitles, episodes, closing |
| [Provider integration](playback/provider-integration.md) | Repositories, script approval, the QuickJS sandbox, discovery |
| [Player engines](playback/platform-player-engines.md) | Media3 and libmpv, selection, the engine gate, torrents |
| [Audio tracks](playback/audio-tracks.md) | Dual audio: discovery, naming, switching, engine support and limits |
| [Troubleshooting](playback/troubleshooting.md) | Symptoms mapped to code and logs |

Playback audit (2026-11-13, static review of v1.33.1; findings await review):

| Page | What it covers |
|---|---|
| [Audit: architecture overview](playback-audit/PLAYBACK_ARCHITECTURE_OVERVIEW.md) | Verified components, lifecycle and failure diagrams, invariants, platform matrix |
| [Audit: report](playback-audit/PLAYBACK_AUDIT_REPORT.md) | Findings PB-01 to PB-15 with evidence, failure scenarios, answers |
| [Audit: performance](playback-audit/PLAYBACK_PERFORMANCE_REPORT.md) | Stage model, timeout budget, bottlenecks, metrics and targets |
| [Audit: test strategy](playback-audit/PLAYBACK_TEST_STRATEGY.md) | Existing coverage, gaps, fake-engine harness, device and stress tests |
| [Audit: remediation roadmap](playback-audit/PLAYBACK_REMEDIATION_ROADMAP.md) | Phased fixes with dependencies, risks and definitions of done |

## Backend

| Page | What it covers |
|---|---|
| [Reelish API](backend/README.md) | Trakt sign-in, sessions, the TMDB gateway: architecture, API, data, threat model |
| [API operations](backend/operations.md) | Setup, secrets, deploy, rollback, backups, rotation, monitoring, incidents, costs |

## Platforms

| Page | What it covers |
|---|---|
| [Android](platforms/android.md) | Phones and tablets |
| [Android TV](platforms/android-tv.md) | The remote interface |
| [Google TV](platforms/google-tv.md) | Same code as Android TV; what differs on its devices |
| [Windows](platforms/windows.md) | The desktop interface, runner, packaging and updates |

## Development

| Page | What it covers |
|---|---|
| [Onboarding](development/onboarding.md) | First questions answered, reading order |
| [Getting started](development/getting-started.md) | Requirements, first run, builds, commands |
| [Coding standards](development/coding-standards.md) | Style, structure, async, safety rules |
| [Debugging guide](development/debugging-guide.md) | Logs, entry points, common failures, measuring |
| [Testing guide](development/testing-guide.md) | Test kinds, integration tests, writing tests, validation before a commit |
| [Adding features](development/adding-features.md) | Where code goes and what to keep |

## Maintenance

| Page | What it covers |
|---|---|
| [Maintenance guide](maintenance/maintenance-guide.md) | Routine tasks, ownership areas |
| [Documentation standards](maintenance/documentation-standards.md) | Keeping these docs accurate; the `docs_tool` checks |
| [Known issues](maintenance/known-issues.md) | Verified limitations |
| [Technical debt](maintenance/technical-debt.md) | Maintainability observations |

## Reference

| Page | What it covers |
|---|---|
| [Configuration reference](reference/configuration-reference.md) | Local files, defines, version, CI secret names, stored data |
| [Third-party dependencies](reference/third-party-dependencies.md) | Every package, why, where, and how to upgrade |
| [Glossary](reference/glossary.md) | Terms, A–Z |

## Guides and records kept from before

| Page | What it covers |
|---|---|
| [Android TV and Google TV](android_tv.md) | TV detection, focus management, testing, limitations |
| [Reelish for Windows](windows.md) | Install, use, build from source, releases |
| [Releasing](releasing.md) | The release pipeline, secrets, debug symbols, updater |
| [Streaming security](streaming_security.md) | The trust boundary and accepted risk SEC-01 |
| [Code protection](code_protection.md) | Obfuscation and what remains visible |

Audit records describe the codebase at the time they were written; paths
and details in them may have changed since:
[production readiness audit](production_readiness_audit.md),
[production sanity check](production_sanity_check.md),
[Windows readiness audit](WINDOWS_READINESS_AUDIT.md),
[security audit](security/SECURITY_AUDIT.md),
[security remediation](security/SECURITY_REMEDIATION.md),
[API and rate-limit audit](security/API_RATE_LIMIT_AUDIT.md),
[frontend/backend audit](security/FRONTEND_BACKEND_AUDIT.md),
[improvement report](security/IMPROVEMENT_REPORT.md).

## Keeping this accurate

The generated pages are rebuilt from the source:

```sh
dart run tool/docs/docs_tool.dart generate
dart run tool/docs/docs_tool.dart check
```

`check` fails on broken links, missing paths, stale generated pages,
unlinked pages and undocumented files. See
[documentation standards](maintenance/documentation-standards.md).
