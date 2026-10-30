// Turns a picked image (untrusted) into a small square PNG avatar: size
// and dimensions are checked before decoding, only a reduced copy is ever
// decoded, and re-encoding drops all of the original's metadata.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

class AvatarImageException implements Exception {
  const AvatarImageException(this.message);
  final String message;
}

abstract final class AvatarImage {
  /// The saved avatar's width and height.
  static const size = 256;

  /// Larger files are refused before they are read as an image.
  static const maxBytes = 15 * 1024 * 1024;

  /// Refused before decoding: a small file can claim a huge image.
  static const maxSide = 12000;
  static const maxPixels = 60 * 1000 * 1000;

  /// The centred square of [bytes], scaled to [size], as PNG.
  static Future<Uint8List> square(
    Uint8List bytes, {
    @visibleForTesting int maxSide = maxSide,
    @visibleForTesting int maxPixels = maxPixels,
  }) async {
    if (bytes.isEmpty) {
      throw const AvatarImageException('That file is empty.');
    }
    if (bytes.length > maxBytes) {
      throw const AvatarImageException(
        'That photo is too large. Choose one under 15 MB.',
      );
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? output;
    try {
      try {
        // Reads the header only.
        descriptor = await ui.ImageDescriptor.encoded(buffer);
      } catch (_) {
        throw const AvatarImageException(
          'That file is not a photo Reelish can read. Try a JPEG or PNG.',
        );
      }
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 ||
          height < 1 ||
          width > maxSide ||
          height > maxSide ||
          width * height > maxPixels) {
        throw const AvatarImageException(
          'That photo is too big to use. Choose a smaller one.',
        );
      }
      // Decode only as much as the square needs (twice its size, for a
      // sharp downscale), never the full image.
      final scale = math.min(1.0, size * 2 / math.min(width, height));
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      decoded = (await codec.getNextFrame()).image;
      final side = math.min(decoded.width, decoded.height).toDouble();
      final source = Rect.fromLTWH(
        (decoded.width - side) / 2,
        (decoded.height - side) / 2,
        side,
        side,
      );
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        decoded,
        source,
        Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      output = await picture.toImage(size, size);
      picture.dispose();
      final png = await output.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw const AvatarImageException('That photo could not be used.');
      }
      return png.buffer.asUint8List();
    } on AvatarImageException {
      rethrow;
    } catch (_) {
      throw const AvatarImageException('That photo could not be used.');
    } finally {
      output?.dispose();
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

typedef Rect = ui.Rect;
