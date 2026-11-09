# App icons

Settings > Appearance > App icon changes the launcher icon. It exists on
Android phones and tablets only (`AppIconService.supported`): Android TV and
Google TV show the app's banner rather than its icon, and Windows embeds its
icon in the executable, so neither offers the screen.

## How switching works

Each icon is an `<activity-alias>` in `AndroidManifest.xml`, listed in
`AppIconSwitcher.kt` and `lib/src/platform/app_icon.dart` under the same id
(`test/app_icon_test.dart` checks the three agree). The enabled alias is the
only record of the choice, so it survives restarts, reboots and app updates,
and what Settings shows is what the launcher shows. Selecting enables the new
alias at once; the old one is disabled when the app goes to the background,
because Android closes a task whose launching component is disabled. The
default keeps the component name `.MainActivity`, so shortcuts made before
icon presets still work. Some launchers drop a home-screen shortcut when the
alias changes; the screen says so.

## Free, supporter and Founder icons

| Group | Icons | Who |
|---|---|---|
| Free | Default, Slate | Everyone, always |
| Signature | Velvet Cinema, Aurora, Ember, Arctic, Ivory Studio, Obsidian Gold, Rosé Noir | Reelish Supporters |
| Colours | Amber, Orange, Rose, Violet, Indigo, Blue, Teal, Green, Lime | Reelish Supporters |

The two free icons are full-quality icons, not lesser versions. Slate is the
dark counterpart of the coral default. The Signature icons are the supporter
collection's own artwork, one per [app theme](supporter-themes.md), painted from
the theme's palette and ornament (`test/app_icon_test.dart` checks there is one
per theme). Their alias ids are the saved choice, so the first five keep the
ids of the themes they replaced: `royal_violet` is Velvet Cinema, `celestial`
Arctic, `rose_luxe` Rosé Noir and `golden_hour` Obsidian Gold; `aurora`,
`ember` and `ivory_studio` match their names. An icon chosen before stays on the
home screen and shows its new artwork after the update.

Everyone sees the whole collection. Someone who is not a supporter sees the
supporter icons in full with a small lock, and a tap opens a short sheet with
a way to the Supporters page; nothing changes without that tap.

`AppIconController.select` applies a supporter icon only after asking the
server (`SupporterController.refresh`) and getting back an
[entitlement](../backend/entitlements.md) with the `appIcons` perk (supporters,
and the Founder). The perk covers the whole collection, so a new icon is the
Founder's, and every supporter's, without any list to update.
A saved status never unlocks one: if the server cannot be reached, or nobody
is signed in, the answer is `unverified` and the icon stays as it is. A donation
waiting for review does not count. The lock marks use the last known status,
for display only.

The icon is a device setting, while supporter status belongs to an account.
Reelish never changes the launcher icon on its own, since that can remove the
user's home-screen shortcut. So an icon chosen while supporting stays after
support ends, after an update, or when someone else signs in on the device,
until the user chooses another. The screen notes this, and from then on only
the free icons can be chosen. Icons chosen before the collection existed stay
for the same reason.

## The Founder Collection

Sovereign Crest (`sovereign_crest`, group `AppIconGroup.founder`) is the
Founder's own icon, the launcher companion of the Sovereign Edition
[theme](supporter-themes.md#the-founder-collection). It is the Reelish logo
(`assets/icons/logo_icon.png`) recoloured in champagne gold (`#D6B779`,
highlights in pale platinum `#F3DCA7`), wearing the Founder Collection's crown,
on obsidian (`#090A12`) with a restrained midnight-violet glow (`#A78BFA`). The
crown is the same one the Founder's laurel avatar wears.

Windows and Android TV cannot switch launcher icons (see the top of this page),
so the App icon page, and with it Sovereign Crest, appears on Android phones and
tablets only. The `.ico` exists for other uses; the Windows build keeps the
default icon for everyone.

Only the Founder sees the FOUNDER COLLECTION section, at the top of the screen:
it has nothing to unlock, so it is never shown locked. `AppIconController.select`
applies it only after the server answers with the Founder entitlement
(`FounderPerk.founderIcons`, [Founder perks](../backend/entitlements.md#founder-perks));
a supporter gets `founderOnly`, an unreachable server `unverified`. Like any
icon it is never removed behind the user's back: if it is on the launcher when
someone else signs in, the section shows it, selected, with a note, and they can
choose another icon. Default stays available to the Founder at all times.

## Assets

Each icon is an adaptive icon: a 432 px background (108 dp at xxxhdpi) in
`drawable-nodpi/`, the shared white mark (`ic_launcher_foreground`) inset 20%
so it stays inside the safe zone under every mask shape, and the shared
monochrome layer for themed icons on Android 13 and later. Launchers without
adaptive icons use `mipmap-<density>/ic_launcher_<id>.png`, 48 to 192 px.
Previews for the screen are 192 px PNGs in `assets/images/app_icons/`.

- Colour presets: `tool/branding/generate_icon_presets.ps1`, from 846 px source
  tiles in `assets/icons/`. It samples each tile's flat gradient.
- Signature icons: `tool/branding/generate_signature_icons.mjs`, painted with
  CanvasKit (from `tool/icons/`). Their ornaments (projector rays, aurora
  ribbons, embers, stars, a gold sheen, bokeh) are deterministic. Ivory Studio,
  the light one, uses an ink copy of the mark
  (`drawable-nodpi/ic_launcher_foreground_ivory_studio.png`), since the shared
  white mark would not show on it. The fallback icons and previews
  are the middle two thirds of the composed adaptive icon, as a launcher shows
  it.

- Sovereign Crest: `tool/branding/generate_sovereign_crest.mjs`, also with
  CanvasKit. The gold fills the clean mark
  (`tool/branding/launcher_monochrome.png`, the logo without its shadow), with
  `logo_icon.png`'s own shadow underneath in dark ink, and the crown from
  `tool/branding/sovereign_shared.mjs` above. Its layers are 432 px PNGs in
  `drawable-nodpi/`: the foreground, the monochrome silhouette and the
  background. The script sizes the artwork by measuring its rendered pixels, so
  it always sits inside the 66 dp safe zone. It also writes
  `tool/branding/sovereign_crest.ico` (16 to 256 px).

A new supporter icon needs its alias in the manifest, an entry in
`AppIconSwitcher.aliases` and an `AppIconPreset` with its group.
