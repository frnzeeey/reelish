# Reelish UX/UI redesign: audit and roadmap

Status: **Stages A and B complete; decisions D1–D3 taken (§ 9);
implementation in progress (§ 10).**

Scope: a brand-identity refinement and UX/UI redesign of the phone, Android
TV / Google TV and Windows interfaces. Not a rebrand and not a rewrite. The
playback engine, provider execution, Watch Party sync, authentication and
entitlements are protected areas (§ 7).

Audit baseline: `main` at `9e16ed3` (Release v1.38.2), 20 November 2026.

---

## 1. Summary of findings

1. **The foundation is better than the brief assumes.** Reelish already has
   a token system (`AppSpace`, `AppRadius`, `AppType`/`AppTextSize`,
   `AppIcon`, `AppMotion` in `lib/src/theme/design_tokens.dart`), a theme
   architecture that separates page colours (`ThemeSurfaces`,
   `lib/src/theme/theme_tokens.dart`) from the accent (`AccentPalette`), a
   player that stays dark in every theme, its own icon font, and one
   entitlement rule for every perk. The redesign should extend this, not
   replace it.
2. **The brand assets in the brief do not exist in the repository.** The
   brief describes a sofa-shaped symbol with three circles and a green,
   earthy palette. The shipped identity is the coral "R" mark
   (`assets/icons/logo_icon.png`, `reelish_icon.png`, `Primary_logo.png`,
   `word_logo.png`, coral `#FF4D6D`). The one new, uncommitted file,
   `assets/icons/reelish_app_emblem.png`, is a terracotta "I"-beam flanked
   by three cream and three sand squares: no circles and no green. No
   palette or brand guide is documented anywhere. Brand work (Phase 10) and
   any new default palette are blocked until the approved logo files and
   colour values are supplied.
3. **Social features are buried.** Friends is reached only from the Profile
   page; Messages only from inside Friends (or a friend's page). On Windows
   and TV that is three steps from the sidebar. Unread messages, friend
   requests and recommendations are counted (`SocialController.counts`,
   `MessagesController.unread`) but shown only on the Profile page. The
   alert history (`EpisodeAlerts.recent`) is shown only inside
   Settings › Notifications.
4. **Primary navigation spends a slot on a setup task.** The phone dock is
   Home · Library · Plugins · Settings. Plugins is set up once and visited
   rarely; Together (friends, messages, parties) is the product's
   differentiator and has no slot.
5. **Consistency debt is moderate and concentrated.** Outside
   `lib/src/theme/`: 176 `Color(0x…)` literals, 214 `Colors.white`, 182
   numeric `fontSize`, 97 numeric `BorderRadius.circular`, about 388 numeric
   `EdgeInsets`, against 508 `AppSpace`, 279 type-scale and 112 `AppRadius`
   uses. Many literals are legitimate (artwork overlays, the player, badge
   finishes); the rest cluster in a few files (player overlays, Wrapped,
   profile style, account badges). Fix them as each screen is redesigned,
   not with a repo-wide sweep.
6. **Messages has no wide layout.** `friends_screen.dart` already splits into
   two columns on TV and Windows from 720 dp, but `messages_screen.dart` is a
   single column: on a wide window the conversation list and a chat are not
   side by side.
7. **Some brief items do not exist and some are named differently.** There is
   no offline download feature. "Sovereign" is not an account tier: it is
   the Founder's own collection (Sovereign Edition theme and profile card,
   Sovereign frame, Sovereign Crest icon and splash), gated by Founder perks.
   Both are preserved as they are (§ 6).

---

## 2. Architecture audit

| Concern | Where | Notes for the redesign |
|---|---|---|
| Entry and startup | `lib/main.dart`, `lib/src/screens/splash_screen.dart` | Splash art chosen before sign-in (`lib/src/platform/splash_art.dart`); Founder sees Sovereign Crest |
| Interface choice | `lib/src/platform/device_capabilities.dart` | `isTv`, `isDesktop`, `usesTvLayout` (TV **and** Windows) |
| Orchestration | `lib/src/screens/home_screen.dart` (3,312 lines) | Phone tabs, `_buildTv`, `_buildDesktop`, `_openItem`, Spotlight, rows. Edit surgically |
| Navigation model | `lib/src/navigation/app_destination.dart` | `TvDestination` feeds TV rail and Windows sidebar; page switches are exhaustive (16 arms) |
| Phone navigation | `lib/src/widgets/soft_glass_dock.dart` | Four fixed tabs, indices hard-coded in `_selectTab` and analytics names |
| TV shell | `lib/src/screens/tv/tv_home_shell.dart` | `tvRailOrder` puts Profile first |
| Windows shell | `lib/src/desktop/desktop_shell.dart` | Sidebar, Profile at the foot, resume shelf under Plugins |
| State | `lib/src/viewmodels/`, singletons in `lib/src/account/`, `lib/src/social/`, `lib/src/messaging/` | `SocialController.instance` and `MessagesController.instance` are app-wide, so a navigation badge needs no new state |
| Theme | `lib/src/theme/glass_theme.dart`, `theme_tokens.dart`, `supporter_themes.dart` | Static getters set by `lib/src/services/accent_settings_controller.dart` |
| Persisted appearance | `onfeed.appearance.accent`, `.theme`, `.theme_accent` | Accent ids (`coral`, `custom:rrggbb`) and theme ids are user data; keep them loadable |
| Entitlements | `lib/src/account/supporter_controller.dart`, `backend/src/entitlements.ts` | `SupporterController.has(SupporterPerk.x)`; Founder perks separate |
| Backend | `backend/` (Cloudflare Worker, D1, Durable Objects) | The redesign needs **no** backend or contract change |
| Docs tooling | `tool/docs/docs_tool.dart` | New `lib/` files need a purpose comment; `check` must pass |

---

## 3. Feature inventory

Risk: **H** touches protected code or entitlements, **M** shared widget or
navigation, **L** one screen's presentation.

| Feature | Implementation and location | Depends on | UX/UI problems | Proposal | Risk | Required testing |
|---|---|---|---|---|---|---|
| Home (phone) | `home_screen.dart` `_home()`, `_brandHeader()`, category chips | `HomeViewModel`, `PagedFeedController` | Header carries mark, Join-party pill, Search and Profile; chips duplicate Movies/Series | Lighter header (mark, Search, Profile); party moves to Together | M | Widget tests for Home; phone run |
| Spotlight | phone `_featuredCarousel`; Windows `lib/src/desktop/desktop_hero.dart`; TV `TvBrowseFrame`; presets in `lib/src/spotlight/` | `TmdbService.spotlight`, Spotlight Experience perk | Text over artwork depends on per-surface scrims; three implementations drift | Keep identity and presets; unify title block, metadata order and scrim tokens | M | Each preset on each platform; reduced motion |
| Top 10 | `HomeViewModel.top10`, `lib/src/desktop/desktop_top_ten.dart`, Bebas numerals on phone | Ranking rules | Fine; numerals are phone-only | Keep; align card radius and spacing tokens | L | Visual check |
| Rows, cards | `lib/src/widgets/media_card.dart`, row headings | Artwork cache | `_RowHeading` uses raw 19 px; mixed radii | Type scale + `AppRadius` only | L | Golden or screenshot comparison |
| Search | `lib/src/screens/search/`, `UniversalSearchController` | TMDB, provider availability | Reached from header (phone) and rail; fine | Keep; refresh empty/loading states | L | Search tests |
| Details | `media_details_screen.dart`, `tv/tv_details_screen.dart`, `desktop/desktop_details_screen.dart` | `DetailsViewModel` | Three layouts; "watch together" only implicit | Clear primary action hierarchy: Play/Resume, then Watch together, My list, Recommend | M | Per-platform details tests |
| Playback UI | `lib/src/widgets/player/` | **Protected** engines, sources, subtitles, audio, party sync | 14 colour literals in paused overlay, 10 in controls | Token clean-up only, under `GlassTheme.playerSurfaces` | H | `playback-audit` checks, integration tests on Windows, Android device |
| Episode selection | `episode_panel.dart`, `EpisodeContext` | Player session | 8 colour literals | Visual tokens only | H | Episode navigation tests |
| Continue watching / history | `HomeViewModel.loadHistory`, `DesktopResumeShelf`, `library_screen.dart` | `StorageService` | Fine | Keep shapes; restyle | L | Library tests |
| My list / collections | `lib/src/collections/`, `lib/src/screens/collections/` | Storage, Trakt sync | Fine | Restyle only | L | Collection tests |
| Profile | `lib/src/screens/profile_screen.dart` | Account, badges, frames, social counts | Hub for too many things (friends, messages, stats, supporters, style) | Becomes identity + stats + personalization; social moves to Together (link kept) | M | Profile tests for free, Supporter, Founder |
| Avatar presets / custom | `lib/src/widgets/profile_avatar_picker.dart`, `ProfileController` | Device-local storage | Fine | Restyle | L | Picker tests |
| Avatar frames | `lib/src/screens/avatar_frames_screen.dart`, `lib/src/account/avatar_frames.dart` | Frames API, perks | Fine | Restyle only; no rule change | H (perks) | Frames tests, all account types |
| Profile cards | `lib/src/theme/profile_styles.dart`, `profile_style_screen.dart` | Perks, Founder card | 12 colour literals in style screen | Restyle; Sovereign Edition unchanged | H (perks) | Profile style tests |
| Friends | `lib/src/screens/social/friends_screen.dart` | `SocialController` | Buried under Profile; no desktop layout | Together destination; two-pane on Windows | M | Friends tests, TV focus |
| Messages | `lib/src/screens/social/messages_screen.dart` | `MessagesController` (WebSocket) | Two levels deep; unread count not on navigation | Together destination with badge; list + thread side by side on Windows | M | Messaging tests (incl. reconnect) |
| Watch Party | `lib/src/screens/watch_party/` | **Protected** room protocol, `PartyPlayerSync` | Join scattered: phone header pill, Settings, desktop Settings | One home in Together; Create stays on Details | M (UI) / H (sync) | Party tests; do not touch sync |
| Notifications | `lib/src/notifications/`, `notification_settings_screen.dart` | Episode checks | Alert history buried in Settings | Activity list in Together; preferences stay in Settings | M | Notification tests |
| Trakt | `lib/src/account/`, `sign_in_screen.dart` | Reelish API | Fine | Restyle sign-in with new brand | M | Sign-in tests |
| Settings | `playback_settings_screen.dart` (`SettingsScreen`), `desktop_settings_page.dart` | Many controllers | Join-a-party inside Settings; Appearance mixes themes, accent, Spotlight, icon | Group: Account · Appearance · Playback · Notifications · Privacy · About & Support | M | Settings tests per platform |
| Help & Support | `help_support_screen.dart`, `lib/src/support/` | — | Fine | Restyle | L | — |
| Plugins | `plugins_screen.dart`, `plugin_library_screen.dart`, `lib/src/widgets/plugin_library/` | **Protected** provider install and approval | Occupies a dock slot | See decision D2 | M | Plugin tests |
| Updates | `lib/src/widgets/app_update_flow.dart`, `update_dialog.dart`, `desktop/desktop_update_section.dart` | GitHub release, Authenticode | Fine | Restyle dialogs only | H (verification) | Update tests |
| Supporters | `supporters_screen.dart` | Buy Me a Coffee, entitlements | Fine | Restyle | M | Supporter tests |
| Themes | `lib/src/theme/supporter_themes.dart` | `appThemes` perk, Founder perks | Fine | New brand theme added alongside (§ 6) | H (perks) | Theme tests, persistence |
| App icons | `lib/src/platform/app_icon.dart`, `app_icon_settings_screen.dart`, `AppIconSwitcher.kt` | Aliases, server check | Fine | New brand icons as **new** ids (§ 8) | H | `app_icon_test`, Android device |
| Wrapped | `lib/src/wrapped/` | History | 12 colour literals | Restyle with tokens | L | Wrapped tests |
| Offline downloads | Not implemented | — | Brief lists it | Out of scope; not built here | — | — |

---

## 4. UX and navigation audit

**Information architecture today**

```
Phone dock:   Home · Library · Plugins · Settings          (Profile, Search, Join party in Home header)
Windows:      Home · Movies · Series · Search · My library · Plugins · Settings · [Profile at foot]
TV rail:      [Profile] · Home · Movies · Series · Search · My library · Plugins · Settings
Social:       Profile → Friends → Messages → conversation
Watch Party:  phone header pill · Settings › Join · Details › Create · invitation link
Alerts:       Settings › Notifications (history at the bottom)
```

**Problems**

- Social is three to four steps deep, and its counts are invisible from
  navigation.
- Watch Party has four entry points and no home.
- Plugins holds a primary slot on every platform.
- Profile is overloaded: identity, statistics, social, membership, styling.
- Settings carries a feature (Join a watch party).
- Phone Home header packs four controls into one row; at large text the
  party label already has to shorten.

**Proposed information architecture**

```
Phone dock:      Home · Library · Together · Plugins · Settings   (D2 option a)
                 Home · Library · Together · Settings             (D2 option b)
Windows sidebar: Home · Movies · Series · Search · My library · Together · Plugins · Settings · [Profile]
TV rail:         [Profile] · Home · Movies · Series · Search · My library · Together · Plugins · Settings

Together
├── Messages        conversations; unread badge on the destination
├── Friends         friends, requests (badge), find people, recommendations to you
├── Watch Party     join by code, active invitations; create stays on Details
└── Activity        episode alerts and friend activity (read/unread)

Profile   identity card, stats, personalization (avatar, frame, card), membership; link to Friends kept
Settings  Account · Appearance · Playback · Notifications · Privacy · About & Support
```

"Together" fits the living-room idea better than "Social": it is where
people gather, not a feed. One destination, four sections, one badge (sum of
unread messages and friend requests). When Friends is turned off
(`SocialController.enabled`), Together shows Watch Party and a friendly
switch-on card rather than disappearing, so navigation stays stable.

**Platform patterns**

- *Phone:* five dock items, each at least 48 dp; badge on Together. Header:
  mark, Search, Profile. Together opens on Messages when unread, else Friends.
- *Windows:* Together is a two-pane page: conversation or friend list on the
  left (fixed ~360 px), thread or friend page on the right; Ctrl+K stays
  search; Esc closes a thread. Hover and focus states from existing desktop
  surfaces.
- *TV:* Together is a rail destination with section tabs across the top;
  conversations read-only by default with quick replies and the existing
  `TvTextEntryDialog` for typing. Focus enters the first unread item.

**Screen relationships (after)**

```
Home ──► Details ──► Play ──► Player
  │         ├─► Watch together ──► Waiting room ──► Player (party)
  │         └─► Recommend to a friend ──► Together/Messages
Search ──► Details
Together ──► Conversation ──► Details (shared title) / Join party
        ──► Friend page ──► their collection ──► Details
Profile ──► Avatar · Frame · Card · Stats · Supporters
Settings ──► Appearance (themes, accent, Spotlight, app icon) …
```

---

## 5. Design system direction

The token system stays; gaps are filled.

| Area | Today | Change |
|---|---|---|
| Colour roles | `ThemeSurfaces` (background, surface, raised, text, border, glass, scrim, sidebar, ambient) + `AccentPalette` | Add **secondary accent** (optional per theme, for the "togetherness" highlights and the Together badge), and semantic **overlay** roles (`scrimStrong`, `scrimSoft`) used by Spotlight and details instead of local gradients |
| Status colours | `GlassTheme.warning/danger/success/info` | Keep |
| Elevation and shadow | Ad hoc `BoxShadow`s | Add `AppShadow` (none, card, floating, focus) tuned for dark surfaces |
| Gradients | `GlassTheme.gradient` + local ones | Keep one accent gradient and the scrim roles; no new decorative gradients |
| Spacing, radius, type, icon size, motion | `design_tokens.dart` | Keep scale; adopt everywhere a redesigned screen is touched |
| Glass | `LiquidGlass`, `GlassBox` | Glass for floating chrome only (dock, sheets, player chrome); cards become solid `surface` |
| TV | `GlassTheme.tv`, `TvFocusable` | One focus ring spec: 3 px accent ring + 1.04 scale, from tokens |

Rules: no `Color(0x…)` outside `lib/src/theme/` in redesigned files except
artwork-specific overlays; `Colors.white` only on artwork, video or accent
fills; durations through `AppMotion.resolve`.

---

## 6. Themes and account benefits (preserved as-is)

| Item | Who | Gate | Change in this project |
|---|---|---|---|
| Classic (no theme) + 11 accents + custom accent | Everyone | — | Unchanged; still selectable |
| Velvet Cinema, Aurora, Obsidian Gold, Ember, Arctic, Rosé Noir, Ivory Studio | Supporters and Founder | `appThemes` perk | Unchanged ids and colours; screens must render them correctly |
| Sovereign Edition theme, card, frame, Crest icon and splash | Founder only | Founder perks | Unchanged |
| Supporter badge, Founder badge | Identity | Server | Unchanged; restyled placement only |
| Hosting a Watch Party | Supporters, Founder | `createParty` on the server | Unchanged |
| Spotlight presets (2 free, 4 supporter) | — | Perk | Unchanged |
| App icons: Default, Slate free; Signature and Colours supporter; Crest Founder | — | Server check | New brand icons added under new ids |

**New brand look as a theme.** Once the palette is approved (D1), it is
added as a new free theme ("Living Room" working name) built from
`ThemeSurfaces` + `AccentPalette`, not by editing `ThemeSurfaces.classic` or
`GlassTheme.coral`. Saved ids keep resolving; a test asserts every
previously shipped id still loads. Whether it becomes the default for people
who never chose a theme is decision D3.

---

## 7. Protected areas and safeguards

| Area | Files | Safeguard |
|---|---|---|
| Playback engines and source pipeline | `lib/src/services/` playback, `PlaybackCoordinator`, `player_engine.dart` | Not edited. Player phase changes only colour/spacing values inside `lib/src/widgets/player/` |
| Provider execution | `ProviderPluginService`, QuickJS, `NetworkDestinationValidator` | Not edited; plugin screens restyled only |
| Watch Party sync | `lib/src/watch_party/`, `backend/src/party-room.ts`, `PartyPlayerSync` | Not edited; only screens in `lib/src/screens/watch_party/` move or restyle |
| Auth and entitlements | `lib/src/account/`, `backend/src/` | Not edited; UI reads `SupporterController.has` as now |
| Persisted data | `StorageService`, appearance keys | No key or shape changes; new keys only, additive |
| Backend contracts | `backend/` | No changes planned |

Any phase that finds it must touch one of these stops for approval.

---

## 8. Roadmap

Each phase: one or a few reviewable commits, then `dart format` on touched
files, `flutter analyze lib test integration_test test_driver`,
`flutter test`, `dart run tool/docs/docs_tool.dart check`, and the builds in
CLAUDE.md for the platforms reached.

### Phase 1 — Design-system gaps
- **Objective:** add `AppShadow`, overlay roles, optional secondary accent,
  TV focus-ring spec; no visual change yet.
- **Files:** `lib/src/theme/design_tokens.dart`, `theme_tokens.dart`,
  `glass_theme.dart`; tests.
- **Risk:** `ThemeSurfaces ==`/`hashCode` must include new fields; theme
  previews use `GlassTheme.build`.
- **Accept:** analyze clean, all theme tests pass, no screenshot diffs.

### Phase 2 — Shared components
- **Objective:** one card, one section header, one list row, one empty/error
  state, one badge, used by later phases.
- **Files:** `lib/src/widgets/media_card.dart`, `glass_box.dart`, new shared
  widgets under `lib/src/widgets/`.
- **Risk:** cards are on every platform; keep the TV focus wrapper outside.
- **Accept:** existing card tests pass; TV focus unchanged.

### Phase 3 — Navigation and Together (needs D2)
- **Objective:** add `TvDestination.together` and the phone dock item, the
  Together page per platform, the unread badge; move Join a party from the
  phone header and Settings into Together; keep Profile's Friends link.
- **Files:** `lib/src/navigation/app_destination.dart`,
  `lib/src/widgets/soft_glass_dock.dart`, `lib/src/screens/home_screen.dart`
  (tab indices, `_selectTab`, both page switches),
  `lib/src/screens/tv/tv_home_shell.dart`, `lib/src/desktop/desktop_shell.dart`,
  new Together pages (phone, TV, Windows), `friends_screen.dart`,
  `messages_screen.dart` (embeddable bodies), settings screens.
- **Dependencies:** Phase 2.
- **Risk:** dock indices and analytics screen names; back handling
  (`PopScope`); deep links into parties; messages socket lifecycle when the
  page is embedded rather than pushed.
- **Accept:** every old route still reachable; badge matches Profile's
  count; TV D-pad reaches every Together item; Windows two-pane works with
  mouse, keyboard and gamepad.

### Phase 4 — Home and discovery
- Spotlight title block and scrims unified across three implementations
  (presets untouched); lighter phone header; row heading on the type scale;
  loading, empty and error states from Phase 2.
- **Files:** `home_screen.dart` (surgical), `lib/src/desktop/desktop_hero.dart`,
  `lib/src/screens/tv/tv_browse.dart`, `lib/src/spotlight/`.
- **Risk:** Spotlight animation presets and reduced motion.

### Phase 5 — Details
- Action hierarchy (Play/Resume, Watch together, My list, Recommend),
  metadata order, episode list styling, on all three layouts.
- **Risk:** `_openItem` wiring; party create path. No change to source search.

### Phase 6 — Profile and personalization
- Profile as identity + stats + personalization; membership tile; restyled
  avatar, frame and card pickers. Sovereign Edition and frame rendering
  untouched.
- **Accept:** profile tests for free, Supporter and Founder sessions.

### Phase 7 — Together polish
- Friend discovery, requests, recommendations and activity list restyled;
  desktop two-pane refinements; empty states that invite (add a friend,
  start a party).

### Phase 8 — Settings
- Regroup into Account · Appearance · Playback · Notifications · Privacy ·
  About & Support on phone and Windows; TV reuses as today.

### Phase 9 — Player chrome
- Replace literals in `paused_overlay.dart`, `player_controls.dart`,
  `episode_panel.dart`, `player_progress_bar.dart` with player tokens.
  Behaviour, gestures and layout unchanged. Run `playback-audit`.

### Phase 10 — Brand assets (needs D1)
- New brand theme (§ 6); new mark and wordmark in `lib/src/widgets/brand_logo.dart`
  (keeping `BrandAssets` names and old files so nothing breaks); splash;
  adaptive icon, monochrome layer and TV banner via
  `tool/branding/generate_brand_assets.ps1`; Windows `.ico`; new icon presets
  as new ids in `lib/src/platform/app_icon.dart`, `AppIconSwitcher.kt` and the
  manifest, with unlock rules matching their group.
- **Risk:** changing the default alias's artwork changes every user's
  launcher icon at update (allowed, but intentional); removing an alias
  would break saved choices, so none are removed.

### Phase 11 — Validation
- `regression-check` across phone, TV and Windows; account matrix (free,
  Supporter, Founder via injected sessions); theme matrix (Classic, 7
  Supporter themes, Sovereign Edition, new theme; switching and restart);
  final report.

**What cannot be verified here:** real Android TV / Google TV hardware,
live providers, a real Founder account, launcher icon rendering on OEM
launchers, Windows display scaling beyond what tests cover. These will be
listed as unverified unless run on devices.

---

## 9. Decisions

- **D1 — Brand assets and palette: decided.**
  `assets/icons/reelish_app_emblem.png` is the new logo. Its three colours are
  the palette: terracotta `#BA725A`, sand `#CAA76C`, cream `#F4F0E5`. It has
  no green, so none is added; the brief's sofa/three-circle description does
  not match the emblem and is not followed. Only a 846 × 846 PNG exists: a
  vector source would still help for launcher layers and the wordmark.
- **D2 — Plugins on the phone: option (b).** Plugins moves into Settings
  (PLAYBACK › Plugins); Together takes its dock slot. The Home card for "no
  source installed" already existed and stays. Windows and TV keep Plugins in
  the rail and sidebar.
- **D3 — Default look: yes.** The brand theme is the default for everyone
  who has never chosen a theme (no saved `onfeed.appearance.theme`). Choosing
  Classic, a supporter theme or Sovereign Edition is kept.

## 10. Progress

| Step | State | Notes |
|---|---|---|
| Living Room theme (brand palette) and default rule | Done | `lib/src/theme/supporter_themes.dart`, `lib/src/services/accent_settings_controller.dart`; [App themes](features/supporter-themes.md) |
| Appearance: REELISH section (Living Room, Classic) above SUPPORTER THEMES | Done | `lib/src/screens/playback_settings_screen.dart`, `lib/src/widgets/supporter_theme_picker.dart` |
| Together destination (phone dock, TV rail, Windows sidebar) with badge | Done | `lib/src/screens/social/together_screen.dart`; Friends page with a Watch Party section. TV rail items 48 → 44 dp so nine fit 540 dp; Windows sidebar's fixed part 540 → 592 px (scrolls below that) |
| Plugins into phone Settings | Done | Opened over Home from Settings and from a Play with no source |
| Phone header Join-party pill | Kept for now | Covered by layout tests; revisit in Phase 4 |
| Brand assets (Phase 10) | Done | Emblem as the logo in the app (header, sidebar, Spotlight label, credits), splash (warm charcoal, terracotta glow), Android launcher icon, TV banner, Windows `.ico`; wordmark "ISH" in terracotta. `tool/branding/generate_emblem_sources.ps1` builds the sources. Every launcher icon now carries the emblem: the colour and Signature icons keep their backgrounds with the emblem in white (Ivory Studio in ink); the original coral is the free Coral icon; Sovereign Crest wears the emblem in champagne gold under the crown, in its laurel wreath |
| Messages side by side on Windows | Done | `lib/src/screens/social/messages_split_view.dart`, from 900 px |
| Phase 1: design-system gaps | Done | `AppShadow` (raised, floating, glow) in `lib/src/theme/design_tokens.dart`, adopted where a shadow already had exactly those values (poster cards, the Windows party poster, the TV focus glow), so nothing moved. The TV focus ring was already one spec (`TvFocusable`). Overlay roles and a secondary accent are left to Phase 4, where the Spotlight first needs them, rather than added unused |
| Phase 2: shared components | Done | `NoticeCard` (replaces the Library and Collections empty cards and the Home "Add a source" card, now a solid card rather than glass), `EmptyState` (empty collection pages, an empty chat, the Messages pane), `CountBadge` (the Together badge on the dock, rail and sidebar); `test/shared_components_test.dart`. Platform headings stay per platform (`DesktopSectionTitle`, `TvRowTitle`, the phone's row heading) |
| Phase 4: Home and Spotlight | Done | Text over artwork has two roles beside `GlassTheme.onArtwork`: `onArtworkMuted` (metadata, synopses) and `onArtworkQuiet` (page dots, secondary outlines), replacing hard-coded whites on the phone Spotlight and the Windows hero; on dark themes they follow the theme's text (cream on Living Room). The phone Spotlight label carries the emblem, as Windows' does. The phone row heading is on the type scale. Home's offline notice and empty catalog use `NoticeCard` and `EmptyState`. Kept on purpose: the three Spotlight layouts (each platform's own) and their animation presets; the phone header's Join party button (Watch Party's entry on Home; Together offers it too), a change from the plan; TV's hero text, which follows the page ink because its hero fades into the page; Windows' `DesktopMessage` and source banner, already consistent |
| Phase 5: Details | Done | One action order on phone, TV and Windows: Play/Resume and Start over, then Watch together, My list, Collections, Recommend (was Share: it sends the title to friends, who see it under Recommended to you, and "Share" also names the usage-statistics consents). TV's remote reaches Watch together right after Play. The phone and Windows secondary buttons share one style each, on the artwork text colours (`onArtwork`, `onArtworkQuiet`) instead of fixed white; the phone tagline uses `onArtworkMuted`. Not changed: metadata, episode lists, source search and the play wiring |
| Phase 6: Profile | Done | Profile reads identity card, PERSONALIZE (avatar frame, profile card, theme, app icon), YOUR VIEWING, TOGETHER (Friends, kept as a link, and Friends & privacy, both moved out of Account) and ACCOUNT. ACCOUNT gains a Reelish Supporters row: an invitation for free accounts, "Thank you" for supporters, nothing extra for the Founder (the card's capsule names them); before, Profile reached the Supporters page only through a badge, which free accounts do not have. A label only, from `SupporterController.entitlement`; no perk reads it. On TV and Windows, Together and Account form the second column. Not changed: the identity card, the Sovereign Edition card and frame, avatar, frame and card pickers and every unlock rule |
| Phase 7: Together | Done | Friend requests lead the page (they wait on an answer). Someone with no friends, requests or messages sees "Bring your people in" (`NoticeCard`) instead of an empty Messages section, which shows once there is a conversation or a waiting message. The empty friends list no longer repeats Add a friend beside ADD A FRIEND. On Windows, Escape closes the open conversation before it leaves Messages. Not changed: every Friends and Messages request, the socket and the controllers |
| Phase 8: Settings | Done | Phone and TV Settings: ACCOUNT, GENERAL (appearance, notifications, recommendations), PLAYBACK (Plugins on the phone, playback, subtitle addons), PRIVACY (usage statistics, crash reports; the section shows only where either can be sent, so Windows and local builds have none), SUPPORT. Join a watch party left Settings on every interface, Windows' rail included: Together offers it on all three, with Home's button on the phone and Home's row on Windows; Help now points to Together. The privacy policy and consent dialogs only promise "in Settings", which still holds. The Windows rail's one-off link row type went with it |
| Phase 9: player chrome | Done | The player's solid panels read `GlassTheme.playerSurfaces` instead of a fixed copy of Classic's surface: the up-next card, the episode panel and its synopsis text, the seek-preview time, the gesture hint, the unlock button, Skip intro/outro and the subtitle position panel. Opacities unchanged; on Classic the colour is all but the same (`#15151C` for `#141419`); on Living Room the panels turn warm charcoal; on a light theme they stay dark (`test/player_chrome_theme_test.dart`). Kept: the black shades and white highlights drawn on the video itself, which belong to the video, not the theme. No playback, gesture, engine, subtitle, audio or Watch Party code changed (22 lines added, 10 removed in `lib/src/widgets/player/`) |
