// Turns the Preferred video quality setting into a QualityTarget for this
// device and connection (docs/playback/quality-prioritization.md).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'source_quality.dart';

/// What the device can decode and show, and whether the connection is
/// metered. Heights are the short side in pixels; null is unknown.
@immutable
class VideoDeviceLimits {
  const VideoDeviceLimits({
    this.maxDecodeHeight,
    this.displayHeight,
    this.metered = false,
  });

  static const unknown = VideoDeviceLimits();

  final int? maxDecodeHeight;
  final int? displayHeight;
  final bool metered;
}

abstract final class PlaybackQualityPolicy {
  static const _channel = MethodChannel('onfeed/device');

  /// Reads the device; replaceable in tests.
  static Future<VideoDeviceLimits> Function() readLimits = _readLimits;

  /// The target for [preferredHeight] (0 is Auto) on this device now.
  static Future<QualityTarget> resolve(int preferredHeight) async {
    VideoDeviceLimits limits;
    try {
      limits = await readLimits().timeout(const Duration(seconds: 1));
    } catch (_) {
      limits = VideoDeviceLimits.unknown;
    }
    return targetFor(preferredHeight, limits);
  }

  /// Auto: the tallest size both the hardware decoders and the display
  /// support, rounded down to a tier, 2160 when unknown, and at most 1080 on
  /// a metered connection. A chosen height: that height, never above what
  /// the device can decode.
  static QualityTarget targetFor(int preferredHeight, VideoDeviceLimits d) {
    final decode = _tier(d.maxDecodeHeight);
    if (preferredHeight > 0) {
      return QualityTarget(
        decode == null ? preferredHeight : _min(preferredHeight, decode),
      );
    }
    var ceiling = 2160;
    if (decode != null) ceiling = _min(ceiling, decode);
    final display = _tier(d.displayHeight);
    if (display != null) ceiling = _min(ceiling, display);
    if (d.metered) ceiling = _min(ceiling, 1080);
    return QualityTarget(ceiling);
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// [height] rounded down to a resolution tier; null when unknown.
  static int? _tier(int? height) {
    if (height == null || height <= 0) return null;
    for (final tier in const [2160, 1440, 1080, 720]) {
      if (height >= tier) return tier;
    }
    return 480;
  }

  static Future<VideoDeviceLimits> _readLimits() async {
    if (kIsWeb) return VideoDeviceLimits.unknown;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'videoCapabilities',
      );
      int? positive(Object? value) => value is int && value > 0 ? value : null;
      return VideoDeviceLimits(
        maxDecodeHeight: positive(map?['maxDecodeHeight']),
        displayHeight: positive(map?['displayMaxHeight']),
        metered: map?['metered'] == true,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      // The tallest monitor: the window can move to it. Decoding is libmpv's,
      // in software when it must, so only the screen limits it.
      final displays = WidgetsBinding.instance.platformDispatcher.displays;
      var height = 0;
      for (final display in displays) {
        final size = display.size;
        final shortSide = size.width < size.height ? size.width : size.height;
        if (shortSide > height) height = shortSide.round();
      }
      return VideoDeviceLimits(displayHeight: height > 0 ? height : null);
    }
    return VideoDeviceLimits.unknown;
  }
}
