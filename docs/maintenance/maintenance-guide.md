# Maintenance guide

Routine work that keeps Reelish healthy, and where each task is described.

| Task | When | How |
|---|---|---|
| Release | When a set of changes is ready | [`docs/releasing.md`](../releasing.md); the `release-validation` skill |
| Update the plugin catalog | When the community catalog changes | `dart run tool/generate_plugin_catalog.dart`, commit `assets/data/plugins.json` (apps fetch it from `main`) |
| Regenerate brand assets | When an image in `assets/icons/` changes | `tool/branding/generate_brand_assets.ps1`, then `dart run flutter_launcher_icons`; see [the feature index](../features/feature-index.md#branding) |
| Update GitHub Actions | Dependabot opens a monthly PR | Actions are pinned to commit SHAs ([`.github/dependabot.yml`](../../.github/dependabot.yml)) |
| Upgrade Flutter | Deliberately, with the whole team | Change `FLUTTER_VERSION` in both workflows; run every test and integration test; see [third-party dependencies](../reference/third-party-dependencies.md#upgrading-safely) |
| Upgrade a package | One at a time | Read its changelog; for vendored packages re-apply and re-verify the `REELISH_PATCH.md` |
| Rebuild the Windows QuickJS DLL | When `flutter_js` changes | [`tool/build_quickjs_bridge_windows.ps1`](../../tool/build_quickjs_bridge_windows.ps1); update the expected SHA-256 in `release-windows.yml` |
| Regression check | Before every commit and release | The `regression-check` skill; [testing guide](../development/testing-guide.md#before-a-commit) |
| Security review | Changes at a trust boundary | The `security-audit` skill; [`docs/streaming_security.md`](../streaming_security.md) |
| Documentation | With every code change | [Documentation standards](documentation-standards.md) |

## Ownership map

There is no CODEOWNERS file. The areas below are the natural units of
ownership, with the files that hold them:

| Area | Files |
|---|---|
| Catalog and TMDB | `tmdb_service.dart`, `tmdb_response_cache.dart`, `paged_feed_controller.dart`, `media_catalog_rules.dart`, `media_discovery_ranking.dart`, `home_view_model.dart` |
| Library and storage | `storage_service.dart`, `library_view_model.dart`, `resume_summary.dart`, `episode_progress.dart` |
| Providers and sandbox | `provider_*.dart`, `network_target_policy.dart`, `stream_discovery.dart`, `third_party/flutter_js/` |
| Playback | `playback_coordinator.dart`, `player_engine.dart`, `source_preparer.dart`, `stream_*.dart`, `torrent_source_preparer.dart`, `lib/src/widgets/player/` |
| Subtitles | `subtitle_addon_service.dart`, `subtitle_loader.dart`, `subtitle_language.dart`, `external_cue_clock.dart` |
| Updates | `github_update_service.dart`, `windows_update_controller.dart`, `update_config.dart`, `app_update_flow.dart`, update dialogs, the update channels |
| Phone UI | `lib/src/screens/`, `lib/src/widgets/` |
| TV UI | `lib/src/screens/tv/`, `lib/src/widgets/tv/` |
| Windows UI and runner | `lib/src/desktop/`, `lib/src/platform/`, `windows/` |

Known limitations: [known issues](known-issues.md). Candidates for
structural work: [technical debt](technical-debt.md).
