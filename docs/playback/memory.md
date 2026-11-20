# Player memory

How the player's memory over repeated opens is measured, and the leak
found and fixed on 2026-11-20.

## Measuring

`integration_test/windows_soak_test.dart` opens and closes the full player
screen on a public HLS stream (20 times by default,
`--dart-define=SOAK_CYCLES=60` for a longer run) and records the process's
resident memory. It turns accessibility on (`ensureSemantics`), because the
leak below only showed with it, and Windows turns it on for any UI
Automation client, not only screen readers.

To tell Dart objects from native memory, the investigation also read the
Dart VM through `vm_service` after each cycle: `getAllocationProfile` with a
forced garbage collection (live instances per class) and, for a class that
kept growing, `getRetainingPath` on one instance (what holds it alive).

## The leak: closed players kept by the semantics tree

**Symptom.** Each player open kept about 1.5 MB after warm-up and never gave
it back: 456 → 645 MB over 60 opens. The Dart heap grew with it, and every
open left one `_CustomVideoPlayerState` alive with its controller,
coordinator, metrics and about 350 render objects.

**Cause (Flutter 3.44.8).** `SemanticsOwner._traversalChildNodes` is keyed
by each `OverlayPortal`'s state. When the portal's semantics node detaches,
Flutter empties the key's set but never removes the key, so the portal's
state, and through its element the whole closed route, stays reachable.
Material's `Slider` shows an `OverlayPortal` (its value indicator) as soon as
it is built, and the player's volume control is always built on Windows.
Retaining path, from the leaked state: the volume slider's focus node, its
ancestors list, the `_OverlayPortalState`, the `_traversalChildNodes` key,
the live app's `SemanticsOwner`. No public Flutter issue was found for it.

**Fix.** The player's sliders (volume, subtitle position) are
`ReelishSlider` (`lib/src/widgets/reelish_slider.dart`), which needs no
`OverlayPortal` and keeps what the player used: tap and drag with start and
end callbacks, divisions, arrow keys (Left and Right only in directional
navigation, as on TV), the focus and hover ring, and slider semantics with
increase and decrease.

**After.** With accessibility on, 60 opens: peaks about 580 MB, with
frequent drops back to 490–520 MB as memory is freed; no player class keeps
instances (`vm_service` allocation profile over 6 opens).

## What remains is working memory, not a leak

The peaks still crept up by about 0.5 MB per open over 60 opens, inside a
swing of ±40 MB between samples. Measured layer by layer (30 opens each,
process memory and Dart heap after a forced GC, one process):

| Layer | Process memory (MB) | Dart heap (MB) |
|---|---|---|
| Full player screen | 564, 626, 617, 623, 638, 632 | 119 → 122 |
| Engine and video widget only | 625, 571, 625, 622, 620, 630 | 122, flat |
| libmpv alone, no video output | 544, 547, 545, 545, 546, 546 | 122, flat |

The Dart heap no longer grows in any layer. Process memory levels off after
the first opens with the video pipeline, and libmpv alone holds level. When
the run moved on to libmpv alone, the process fell from about 630 to 545 MB:
the 80 MB the video pipeline held (decoder frames, HLS buffers, the video
texture and its ANGLE surfaces) was handed back once video stopped, which
leaked memory cannot be. Nothing was changed for it.

## Every slider

Every slider in the app is a `ReelishSlider`
(`lib/src/widgets/reelish_slider.dart`): the player's, the settings slider
in `settings_components.dart`, the subtitle colour, gradient and hue
sliders in `playback_settings_screen.dart` (the gradient is the slider's
own `trackColors`) and the icon gallery's. Material's `Slider` showed its
value in a bubble while dragging; every Reelish slider already shows its
value beside it, so nothing is lost. `test/reelish_slider_test.dart` fails
if `lib/` uses Material's `Slider` again.

Each slider has a `label`, its title, so screen readers name it ("Subtitle
size, 25%"); the Settings sliders had none before.

## Checked on devices (2026-11-20)

- **Android phone (emulator):** a real touch swipe through `adb` moved the
  Settings slider; TalkBack's view (`uiautomator dump`) shows an
  `android.widget.SeekBar`, focusable, read as "50%, Check slider".
- **Android TV interface (emulator):** a real D-pad Right (`adb shell input
  keyevent KEYCODE_DPAD_RIGHT`) stepped it.
- **Windows (the release app, MSAA, as a screen reader reads it):** Settings
  then Playback opened through accessibility actions; the sliders read
  "Subtitle size, 25%" and "Subtitle position, 36%", and the screen reader's
  focus request focused the slider. Arrow keys posted to the window from
  outside were not taken (Flutter does not take keys sent to a window in the
  background), so the keyboard path on Windows rests on the widget tests and
  the same key handling seen on Android.
- Not done: a physical TV or phone, and Narrator or TalkBack speaking.
