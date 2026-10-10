import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/liquid_glass.dart';

/// What kind of device Reelish is running on, read once during startup.
///
/// Android reports it from `MainActivity.deviceCapabilities()`: a device is a
/// TV when its UI mode is `UI_MODE_TYPE_TELEVISION` or it declares the
/// leanback feature (every Android TV and Google TV device does). Screen size
/// is never used, so a large tablet stays a tablet and a small TV stays a TV.
///
/// The interface reads [DeviceCapabilities.isTv] to choose between the mobile layouts and the
/// TV ones; services, models and playback are the same on both.
@immutable
class DeviceCapabilities {
  const DeviceCapabilities({
    this.isTelevision = false,
    this.hasTouchscreen = true,
    this.supportsPictureInPicture = true,
  });

  /// Shows the TV interface on any device, for testing the TV layouts on a
  /// phone or a regular emulator:
  /// `flutter run --dart-define=REELISH_FORCE_TV=true`.
  static const forceTv = bool.fromEnvironment('REELISH_FORCE_TV');

  static const _channel = MethodChannel('onfeed/device');

  /// Remote-first, landscape, viewed from across the room.
  final bool isTelevision;
  final bool hasTouchscreen;
  final bool supportsPictureInPicture;

  static final ValueNotifier<DeviceCapabilities> _current = ValueNotifier(
    const DeviceCapabilities(isTelevision: forceTv, hasTouchscreen: !forceTv),
  );

  /// The device Reelish is running on. Mobile until [load] completes.
  static DeviceCapabilities get current => _current.value;

  /// Notifies when [load] finds a different device than the default, so the
  /// app can switch to the TV theme before the first screen appears.
  static ValueListenable<DeviceCapabilities> get listenable => _current;

  /// Whether to show the TV interface.
  static bool get isTv => _current.value.isTelevision;

  /// Replaces the detected device, for tests.
  @visibleForTesting
  static set debugOverride(DeviceCapabilities value) => _apply(value);

  /// Asks Android what this device is. Never throws: an unanswered or failed
  /// query keeps the mobile interface, which is what every release before TV
  /// support shipped.
  static Future<DeviceCapabilities> load() async {
    var detected = current;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final values = await _channel
            .invokeMapMethod<String, Object?>('capabilities')
            .timeout(const Duration(seconds: 2));
        if (values != null) {
          detected = DeviceCapabilities(
            isTelevision: forceTv || values['isTelevision'] == true,
            hasTouchscreen: !forceTv && values['hasTouchscreen'] != false,
            supportsPictureInPicture:
                values['supportsPictureInPicture'] != false,
          );
        }
      } catch (_) {
        // Keep the mobile defaults.
      }
    }
    _apply(detected);
    return detected;
  }

  /// Whether [_apply] changed the app-wide settings below for a TV, so a
  /// switch back (in tests) restores them. Mobile never changes them.
  static bool _tvSettingsApplied = false;

  static void _apply(DeviceCapabilities value) {
    _current.value = value;
    if (value.isTelevision) {
      _tvSettingsApplied = true;
      // TV hardware is often a low-power streaming stick: every glass
      // surface drops its backdrop blur and keeps the painted material only.
      LiquidGlass.qualityCeiling = LiquidGlassQuality.low;
      // With a remote, focus is the only cursor, so it is always drawn, even
      // before the first key press switches Flutter out of touch mode.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
    } else if (_tvSettingsApplied) {
      _tvSettingsApplied = false;
      LiquidGlass.qualityCeiling = LiquidGlassQuality.high;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceCapabilities &&
      other.isTelevision == isTelevision &&
      other.hasTouchscreen == hasTouchscreen &&
      other.supportsPictureInPicture == supportsPictureInPicture;

  @override
  int get hashCode =>
      Object.hash(isTelevision, hasTouchscreen, supportsPictureInPicture);
}
