# Plugin Manager

Reelish finds streams through third-party **provider repositories**
("collections"): a `manifest.json` listing **providers** (scrapers), each a
JavaScript file that Reelish downloads and runs in its own script engine. The
Plugin Manager is everything that helps people choose, understand and control
them. It is built on the existing provider system, which it did not replace.

| Section | Where |
|---|---|
| Discover | Community Library: `PluginLibraryScreen` (phone, TV), embedded in `DesktopPluginsPage` (Windows) |
| Catalog details | `PluginDetailsScreen` |
| Installed | `PluginsScreen` (phone, TV), `DesktopPluginsPage` (Windows) |
| Collection details | `PluginCollectionScreen`, opened with **Manage collection** on each collection card |
| Provider details | `InstalledProviderScreen`, opened from a provider row on the collection page |
| Sources and trust | The Source section of both details pages (`PluginSourceCard`) |

The two new pages are shared by all three interfaces. They are pushed as
routes, as `PluginDetailsScreen` already was; Esc goes back on Windows, and
the first action takes focus on TV.

## How plugins work (audit)

| Question | Answer in code |
|---|---|
| Discovery | The Community Library catalog, `assets/data/plugins.json`, generated from the community Nuvio Plugin Library (`tool/generate_plugin_catalog.dart`). The app downloads it from its own GitHub repository's main branch every 6 hours at most, keeps a cached copy and falls back to the bundled one (`PluginLibraryService`, `PluginLibraryRepository`). The Nuvio website is only the generator's source; the app never calls it. |
| Metadata | Catalog: name, owner, languages, manifest link, scraper list. Manifests: per provider `id`, `name`, `filename`, `supportedTypes`, `enabled`, `priority`, and the fields the manager now keeps: `version`, `author`, `logo`, `formats`, `contentLanguage`, `disabledPlatforms`, `hasSettings`. |
| Install | `ProviderPluginService.install(url)`: HTTPS only, `NetworkDestinationValidator`, GitHub links rewritten to the raw manifest, CloudStream and add-on manifests refused. Only repository URLs are stored. |
| Load | At launch every manifest is re-read (conditional GET, cached body). A manifest that fails keeps the copy loaded earlier this session, or the collection stays installed and is retried. |
| Communication | `ProviderRunner`: QuickJS on a background isolate, `getStreams(tmdbId, type, season, episode)`. `ProviderFetchBridge` gives scripts `fetch`/XHR backed by Dart HTTP. |
| Selection | Every enabled provider that supports the title's type, highest `priority` first, four workers and two live runtimes (`ProviderExecutionScheduler`). Automatic selection can be limited further in Playback settings. |
| Enable / disable | Per provider, stored as `onfeed.nuvio.plugin.enabled` overrides (`repositoryUrl|providerId`). Read when a search starts; a search already running keeps its list, and playback that has started never consults providers. |
| Updates | No version pinning: manifests and scripts are fetched fresh. Script code is pinned by SHA-256 after first use; changed code, and providers a manifest adds after install, are held in `pendingScriptUpdates` until the viewer allows them. |
| Errors | Load failures by repository URL, lookup failures by provider, shown under Needs attention. |
| Permissions | None declared by providers, none enforced per provider. Every provider gets the same runtime limits (below). |
| Compatibility | Not evaluated before this work: `disabledPlatforms` was discarded. |
| Settings | Local only (SharedPreferences, one manifest cache file). No backend involvement. |

## What changed

- **Manifest metadata** is kept on `ProviderPlugin` and `ProviderRepository`
  (version, author, logo, formats, content languages, disabled platforms,
  settings). Parsing drops values of the wrong type; nothing new is persisted
  except approved versions (below).
- **Compatibility** (`plugin_compatibility.dart`), judged from what the
  manifest declares and what Reelish does:

  | Level | When |
  |---|---|
  | No known issues | Nothing declared rules this device out. Not a promise of streams. |
  | Works with limits | Declares settings; Reelish has none, so it runs with an empty `SCRAPER_SETTINGS`. |
  | Not for this device | Its author lists this device in `disabledPlatforms`, or it declares only content Reelish never searches (e.g. `anime` alone). |
  | Checked after install | Catalog only: the catalog carries no platform data for its scrapers. |

  Platform names map as: `tv`, `androidtv`, `googletv` → TV hardware;
  `android`, `mobile`, `phone` → phones and tablets; `windows`, `desktop`,
  `pc` → Windows. Others (`ios`, `web`) never match. Availability is kept
  apart: *Temporarily unavailable* (manifest not reachable), *Paused for
  review* and *Last search failed* are states, not compatibility.
- **No accidental activation.** A provider whose author disables this device
  starts switched off here (`ProviderPluginService._applyOverrides`); the
  viewer can still switch it on after a confirmation (`setProviderEnabled`).
  An explicit choice always wins and is kept. A provider Reelish never
  searches cannot be switched on.
- **Update check.** *Check for updates* on a collection re-reads its manifest
  and downloads the script of every provider that is switched on, **without
  running any**. New or changed code goes to review with its version change
  (`Version 1.0.2 → 1.0.3`, or *New provider*), so it is found before a
  search rather than during one. Nothing is ever applied silently; *Review
  and allow* asks first.
- **Approved versions.** `onfeed.plugin.scriptVersions.v1` maps each approved
  script URL to the version its manifest listed when it was allowed (first use
  or approval). Display only: hashes still decide what runs. Removed with the
  collection.
- **Search and filters** on the collection page: by name, description or
  author; All, On, Off, Needs attention, Not for this device (only filters
  with matches are offered).

## Source trust

Three different statements, never merged:

| Level | Meaning | Set by |
|---|---|---|
| Verified publisher | The Reelish catalog maintainer confirmed who publishes this exact manifest URL. Says nothing about the code. | `verified: true` on the catalog entry, set **by hand**. The generator never sets it and keeps existing values when it regenerates. Today no entry is verified. |
| Listed in the catalog | Someone added it to the community catalog. Nobody verified the publisher or reviewed the code. | Present in the catalog. |
| Added by link | Installed from a pasted link and not in the catalog. Reelish knows nothing about it. | Everything else. |

A fourth state, *Source not checked*, shows while the catalog has not loaded.
Matching is on the exact manifest URL, so a look-alike repository on another
account is not "listed". The host line ("Hosted on GitHub by the account
yoruix") is read from the address and labelled as such, not as an identity.

To verify a publisher: confirm who controls the hosting account (for example
a signed statement from the account, or the maintainer's own repository
linking to the manifest), set `"verified": true` on that entry in
`assets/data/plugins.json`, and commit. Remove it if the account changes
hands.

## What every provider can and cannot do

Shown as *What providers can do* on every details page
(`ProviderCapabilitiesCard`). These are runtime facts, the same for every
provider; providers do not declare permissions, so none are listed per
provider.

Providers **can** receive the title being looked up (TMDB number, movie or
series, season and episode); contact public HTTPS sites (and send them that
title); return stream links and the headers the player sends with them, which
`StreamValidator` checks.

Providers **cannot** reach private, loopback or link-local addresses
(`NetworkDestinationValidator`, DNS pinned); read the Reelish or Trakt
account, tokens, history, files, or another provider's cookies (none are
exposed; each runtime has its own cookie jar, discarded after the run); run
past the hard 45-second limit; or change code after install without approval.

The card says plainly that the script engine separates providers from the
viewer's data but is not an operating-system sandbox. It does not claim a
memory limit: QuickJS's 64 MiB cap is confirmed only on Android.

## Security assessment

| Risk | Status |
|---|---|
| Arbitrary code execution | Inherent: providers are downloaded JavaScript. Contained by QuickJS on an isolate, no file/OS modules, the fetch bridge (HTTPS, public addresses, 2 MiB bodies, 4 concurrent requests), timeouts and the scheduler. |
| Update tampering / host takeover | Code pinned by SHA-256 after first use; changes and new providers need approval. The first version of a script listed at install is trusted on first use (TOFU), so installing is the trust decision. |
| Download integrity | HTTPS only, redirects re-validated, credentials stripped cross-origin. No publisher signatures exist in this ecosystem. |
| Malformed metadata | Catalog and manifest parsing never throws for a bad entry; lengths and counts capped; only HTTPS logo and link URLs kept. |
| Misleading trust | Fixed: listed and verified are distinct, the verified flag comes only from Reelish's own catalog file, and "listed" text says it is not an endorsement. |
| Secrets | Providers receive no tokens or account data; the details pages show only manifest data, the script address and IDs. |
| Privacy | Every provider learns what is being looked up, and so do the sites it contacts. Stated on the capabilities card. Logos load from the address the manifest gives (usually Google's favicon service), as library logos already did. |

Remaining limits: no per-provider permission enforcement is possible without
a manifest permission model the ecosystem lacks (a destination allowlist per
provider would break most providers, which reach many mirror hosts); TOFU on
install; no signatures.

## Backend and cost

None. Everything is on the device and in the existing catalog file; no
backend route, table or request was added. The update check makes one
manifest request and one request per enabled provider, only when the viewer
presses the button.

## Tests

`plugin_manager_test` (metadata parsing, malformed values, compatibility,
catalog compatibility, trust and host parsing, TV defaults and choices, update
check, failed downloads, outages, version recording and removal, the two
pages), `plugin_library_test` (catalog details trust wording),
`provider_repository_state_test`, `desktop_settings_plugins_test`.

Not covered automatically: real TV remote focus order on the new pages, real
Windows window scaling, live provider repositories.

## Follow-ups

- Regenerate `assets/data/plugins.json` so catalog scrapers carry
  `disabledPlatforms` and `version`; until then Discover shows *Checked after
  install*, and a compatibility filter in the library would have nothing to
  filter.
- A per-provider "Allow" (approval is per collection today).
