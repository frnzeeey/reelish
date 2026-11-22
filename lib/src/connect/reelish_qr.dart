// Reelish Connect's one QR component: encodes a shared link (locally, with
// the `qr` package), draws it in Reelish's look for any screen, and renders
// the same code as a PNG card to share or save. Every share uses it.
//
// Scannability comes first: the exact link, dark modules on light cream
// (never inverted), a four-module quiet zone, and the emblem in the centre
// only when the code is small enough to have no alignment pattern there
// and the logo hides under a tenth of the modules (error correction Q
// recovers a quarter). Otherwise the code is drawn plain at H.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../theme/glass_theme.dart';

/// The modules of one QR code, and where its logo may go.
@immutable
class ReelishQrData {
  ReelishQrData._(
    this.link,
    this.moduleCount,
    this.typeNumber,
    this.errorCorrection,
    this._dark,
  ) : logoModules = _logoFor(typeNumber, moduleCount);

  /// Encodes [link] exactly as it is shared, so a camera reads the same
  /// link and offers to open it (scanners treat a link they do not
  /// recognise as text to copy). Error correction Q (25%) keeps every
  /// Reelish link at version 6 or below, with no alignment pattern in the
  /// centre, so the logo fits with a wide margin; anything longer is drawn
  /// plain at H (30%).
  factory ReelishQrData.encode(String link) {
    final payload = QrPayload.fromString(link);
    var code = QrCode(
      payload: payload,
      errorCorrectLevel: QrErrorCorrectLevel.quartile,
    );
    if (code.typeNumber > _lastLogoVersion) {
      code = QrCode(
        payload: payload,
        errorCorrectLevel: QrErrorCorrectLevel.high,
      );
    }
    final image = QrImage(code);
    final count = image.moduleCount;
    final dark = List<bool>.generate(
      count * count,
      (i) => image.isDark(i ~/ count, i % count),
    );
    return ReelishQrData._(
      link,
      count,
      code.typeNumber,
      code.errorCorrectLevel,
      dark,
    );
  }

  /// From version 7 an alignment pattern sits in the centre.
  static const _lastLogoVersion = 6;

  /// How much of the code can be lost and still read.
  final QrErrorCorrectLevel errorCorrection;

  /// The link encoded, as given.
  final String link;
  final int moduleCount;

  /// The QR version, 1–40.
  final int typeNumber;
  final List<bool> _dark;

  /// The logo's side in modules, with its clear margin; 0 for none.
  final int logoModules;

  bool isDark(int row, int col) => _dark[row * moduleCount + col];

  /// Whether the module is part of one of the three finder patterns.
  bool isFinder(int row, int col) {
    final far = moduleCount - 7;
    return (row < 7 && col < 7) ||
        (row < 7 && col >= far) ||
        (row >= far && col < 7);
  }

  /// Whether the logo covers the module (so it is not drawn).
  bool isUnderLogo(int row, int col) {
    if (logoModules == 0) return false;
    final start = (moduleCount - logoModules) ~/ 2;
    final end = start + logoModules;
    return row >= start && row < end && col >= start && col < end;
  }

  /// The share of modules the logo hides; error correction H recovers up
  /// to 30% of codewords, and the logo is kept far below that.
  double get logoCoverage =>
      logoModules * logoModules / (moduleCount * moduleCount);

  /// Versions 2–6 have alignment patterns only away from the centre; from
  /// 7 one sits in the middle, where the logo would hide it.
  static int _logoFor(int typeNumber, int moduleCount) {
    if (typeNumber < 2 || typeNumber > _lastLogoVersion) return 0;
    var side = (moduleCount * .24).round();
    if (side.isEven) side += 1;
    while (side > 0 &&
        side * side / (moduleCount * moduleCount) > maxCoverage) {
      side -= 2;
    }
    return side >= 7 ? side : 0;
  }

  /// The most of the code the logo may hide.
  static const maxCoverage = .1;
}

/// The code's colours: fixed, whatever the theme, so every code scans the
/// same. The emblem's base and cream: 15.7 : 1.
abstract final class ReelishQrColors {
  static const ink = Color(0xFF14110E);
  static const paper = Color(0xFFF4E9D8);
}

/// Paints [data] into a square, quiet zone included.
class ReelishQrPainter extends CustomPainter {
  ReelishQrPainter(this.data, {this.logo});

  final ReelishQrData data;

  /// The emblem, drawn in the centre when the code leaves room for it.
  final ui.Image? logo;

  /// Light modules around the code, as the standard asks.
  static const quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final total = data.moduleCount + quietZone * 2;
    final module = size.shortestSide / total;
    canvas.drawRect(Offset.zero & size, Paint()..color = ReelishQrColors.paper);
    final ink = Paint()
      ..color = ReelishQrColors.ink
      ..isAntiAlias = true;
    Offset at(int row, int col) =>
        Offset((col + quietZone) * module, (row + quietZone) * module);
    // Data modules: softly rounded squares, full size so dark areas stay
    // solid for the camera.
    final radius = Radius.circular(module * .32);
    for (var row = 0; row < data.moduleCount; row++) {
      for (var col = 0; col < data.moduleCount; col++) {
        if (!data.isDark(row, col) ||
            data.isFinder(row, col) ||
            data.isUnderLogo(row, col)) {
          continue;
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            at(row, col) & Size.square(module * 1.02),
            radius,
          ),
          ink,
        );
      }
    }
    // Finder patterns: the rounded square that is the brand shape.
    final far = data.moduleCount - 7;
    for (final (row, col) in [(0, 0), (0, far), (far, 0)]) {
      final origin = at(row, col);
      final outer = RRect.fromRectAndRadius(
        origin & Size.square(module * 7),
        Radius.circular(module * 2),
      );
      final hole = RRect.fromRectAndRadius(
        (origin + Offset(module, module)) & Size.square(module * 5),
        Radius.circular(module * 1.4),
      );
      canvas.drawDRRect(outer, hole, ink);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          (origin + Offset(module * 2, module * 2)) & Size.square(module * 3),
          Radius.circular(module),
        ),
        ink,
      );
    }
    final image = logo;
    if (image != null && data.logoModules > 0) {
      final start = (data.moduleCount - data.logoModules) / 2;
      final box =
          at(0, 0) + Offset(start * module, start * module) &
          Size.square(data.logoModules * module);
      // One clear module inside the cleared square, then the emblem.
      final inner = box.deflate(module);
      paintImage(
        canvas: canvas,
        rect: inner,
        image: image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
  }

  @override
  bool shouldRepaint(ReelishQrPainter old) =>
      old.data.link != data.link || old.logo != logo;
}

/// The emblem as an image for the painter, loaded once.
abstract final class ReelishQrLogo {
  static const asset = 'assets/icons/reelish_app_emblem.png';
  static Future<ui.Image>? _image;

  static Future<ui.Image> load() => _image ??= () async {
    final bytes = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }();
}

/// A QR code for [link] in Reelish's look, at [size].
class ReelishQrCode extends StatefulWidget {
  const ReelishQrCode({
    super.key,
    required this.link,
    required this.size,
    this.semanticLabel,
  });

  final String link;
  final double size;

  /// Read out instead of the link.
  final String? semanticLabel;

  @override
  State<ReelishQrCode> createState() => _ReelishQrCodeState();
}

class _ReelishQrCodeState extends State<ReelishQrCode> {
  late ReelishQrData _data = ReelishQrData.encode(widget.link);
  ui.Image? _logo;

  @override
  void initState() {
    super.initState();
    ReelishQrLogo.load().then(
      (image) {
        if (mounted) setState(() => _logo = image);
      },
      onError: (Object _) {
        // The code scans without it.
      },
    );
  }

  @override
  void didUpdateWidget(covariant ReelishQrCode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != widget.link) {
      _data = ReelishQrData.encode(widget.link);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: widget.semanticLabel ?? 'QR code',
    child: ClipRRect(
      // Rounded corners stay inside the quiet zone.
      borderRadius: BorderRadius.circular(widget.size * .06),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: ReelishQrPainter(_data, logo: _logo),
        ),
      ),
    ),
  );
}

/// The shareable image: the code on a Reelish card with a title, a line
/// under it, and the link spelled out, as a PNG.
abstract final class ReelishQrCard {
  /// The card's size in pixels: a 4:5 portrait, sharp on any phone.
  static const width = 1080.0;
  static const height = 1350.0;

  static Future<Uint8List> render({
    required String link,
    required String title,
    String subtitle = '',
  }) async {
    final data = ReelishQrData.encode(link);
    ui.Image? logo;
    try {
      logo = await ReelishQrLogo.load();
    } catch (_) {}
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const background = Color(0xFF14110E);
    const surface = Color(0xFF1F1A16);
    const cream = Color(0xFFF4E9D8);
    const muted = Color(0xFFB4AA9C);
    const accent = Color(0xFFD17B5B);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = background,
    );
    // A soft terracotta light from the top, as the app's backdrop.
    canvas.drawCircle(
      const Offset(width / 2, -120),
      720,
      Paint()
        ..shader = ui.Gradient.radial(const Offset(width / 2, -120), 720, [
          accent.withValues(alpha: .22),
          accent.withValues(alpha: 0),
        ]),
    );
    // The code on its panel; below it the title (one line), the subtitle
    // (two at most) and the link, top to bottom without overlap.
    const codeSize = 780.0;
    const codeTop = 230.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(120, codeTop - 30, codeSize + 60, codeSize + 60),
        const Radius.circular(56),
      ),
      Paint()..color = surface,
    );
    canvas.save();
    canvas.translate(150, codeTop);
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, codeSize, codeSize),
        const Radius.circular(40),
      ),
    );
    ReelishQrPainter(
      data,
      logo: logo,
    ).paint(canvas, const Size.square(codeSize));
    canvas.restore();

    void text(
      String value,
      double top, {
      required double size,
      required Color color,
      FontWeight weight = FontWeight.w500,
      double spacing = 0,
      int lines = 1,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: GlassTheme.fontFamily,
            fontSize: size,
            fontWeight: weight,
            color: color,
            letterSpacing: spacing,
            height: 1.25,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: lines,
        ellipsis: '…',
      )..layout(maxWidth: width - 200);
      painter.paint(canvas, Offset((width - painter.width) / 2, top));
      painter.dispose();
    }

    text(
      'REELISH',
      100,
      size: 34,
      color: const Color(0xFFE8B98A),
      weight: FontWeight.w800,
      spacing: 9,
    );
    // 1080–1143: the title; 1155–1235: the subtitle; 1270: the link.
    text(
      title,
      codeTop + codeSize + 70,
      size: 50,
      color: cream,
      weight: FontWeight.w700,
    );
    if (subtitle.isNotEmpty) {
      text(
        subtitle,
        codeTop + codeSize + 145,
        size: 32,
        color: muted,
        lines: 2,
      );
    }
    text(
      link.replaceFirst(RegExp(r'^https://'), ''),
      height - 80,
      size: 26,
      color: muted,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    picture.dispose();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('No image data.');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}
