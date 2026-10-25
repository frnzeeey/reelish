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

## Playback

| Page | What it covers |
|---|---|
| [Playback architecture](playback/playback-architecture.md) | The pipeline from Play to picture, the play request flow, recovery |
| [Playback lifecycle](playback/playback-lifecycle.md) | The player session: opening, playing, subtitles, episodes, closing |
| [Provider integration](playback/provider-integration.md) | Repositories, script approval, the QuickJS sandbox, discovery |
| [Player engines](playback/platform-player-engines.md) | Media3 and libmpv, selection, the engine gate, torrents |
| [Troubleshooting](playback/troubleshooting.md) | Symptoms mapped to code and logs |

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
