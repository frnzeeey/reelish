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

## Free and supporter icons

| Group | Icons | Who |
|---|---|---|
| Free | Default, Slate | Everyone, always |
| Signature | Royal Violet, Celestial, Aurora, Rose Luxe, Golden Hour | Reelish Supporters |
| Colours | Amber, Orange, Rose, Violet, Indigo, Blue, Teal, Green, Lime | Reelish Supporters |

The two free icons are full-quality icons, not lesser versions. Slate is the
dark counterpart of the coral default. The Signature icons are the supporter
collection's own artwork and match the [app themes](supporter-themes.md).

Everyone sees the whole collection. Someone who is not a supporter sees the
supporter icons in full with a small lock, and a tap opens a short sheet with
a way to the Supporters page; nothing changes without that tap.

`AppIconController.select` applies a supporter icon only after asking the
server (`SupporterController.refresh`) and getting back an
[entitlement](../backend/entitlements.md) with the `appIcons` perk (supporters,
and the Founder).
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
  CanvasKit (from `tool/icons/`). Their ornaments (stars, aurora ribbons, bokeh,
  spotlight rays, a low sun) are deterministic. The fallback icons and previews
  are the middle two thirds of the composed adaptive icon, as a launcher shows
  it.

A new supporter icon needs its alias in the manifest, an entry in
`AppIconSwitcher.aliases` and an `AppIconPreset` with its group.
