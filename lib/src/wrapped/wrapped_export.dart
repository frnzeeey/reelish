// Exports a Reelish Wrapped card as a PNG: the system share sheet and the
// gallery on Android phones and tablets (the app's own `onfeed/share`
// channel, ShareChannel.kt), a file in Pictures\Reelish on Windows. Not on
// TV, which has nowhere to share to. Only the image the viewer chose to
// share leaves the app, and only when they press Share or Save.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../platform/device_capabilities.dart';

abstract final class WrappedExport {
  static const _channel = MethodChannel('onfeed/share');

  /// The system share sheet: Android phones and tablets.
  static bool get canShare =>
      !kIsWeb && Platform.isAndroid && !DeviceCapabilities.isTv;

  /// Saving an image: Android 10 and later (the shared Pictures folder
  /// needs no permission there), and Windows.
  static Future<bool> canSave() async {
    if (kIsWeb || DeviceCapabilities.isTv) return false;
    if (Platform.isWindows) return true;
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canSave') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The image of [boundary], [pixelRatio] times its logical size.
  static Future<Uint8List> capture(
    RenderRepaintBoundary boundary, {
    double pixelRatio = 3,
  }) async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('No image data.');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Opens the share sheet with [png]; false when it could not.
  static Future<bool> share(Uint8List png, String name, {String? text}) async {
    if (!canShare) return false;
    try {
      return await _channel.invokeMethod<bool>('shareImage', {
            'bytes': png,
            'name': _safe(name),
            'text': ?text,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Saves [png]; returns where (a gallery folder, or a file path on
  /// Windows), or null when it could not.
  static Future<String?> save(Uint8List png, String name) async {
    final file = _safe(name);
    try {
      if (!kIsWeb && Platform.isWindows) {
        final home = Platform.environment['USERPROFILE'];
        if (home == null || home.isEmpty) return null;
        final dir = Directory('$home\\Pictures\\Reelish');
        await dir.create(recursive: true);
        final path = '${dir.path}\\$file.png';
        await File(path).writeAsBytes(png, flush: true);
        // Shows it in Explorer; the save stands either way.
        try {
          await Process.start('explorer.exe', ['/select,', path]);
        } catch (_) {}
        return path;
      }
      if (!kIsWeb && Platform.isAndroid) {
        final saved = await _channel.invokeMethod<bool>('saveImage', {
          'bytes': png,
          'name': file,
        });
        return saved == true ? 'Pictures/Reelish' : null;
      }
    } catch (_) {}
    return null;
  }

  /// A file name of letters, digits and dashes only.
  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-');
    return cleaned.isEmpty ? 'reelish-wrapped' : cleaned;
  }
}
