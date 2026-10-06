import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';

/// A provider's icon, or a monogram tile when the catalog has none or the
/// image fails. Never shows a broken-image glyph.
class PluginLogo extends StatelessWidget {
  const PluginLogo({
    super.key,
    required this.name,
    this.url,
    this.size = 46,
    this.radius = 15,
  });

  final String name;
  final Uri? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = _Monogram(name: name, size: size, radius: radius);
    final source = url;
    if (source == null || !isLoadableLogo(source)) return fallback;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Image.network(
          source.toString(),
          // Decode at display size so dozens of logos stay cheap in memory.
          cacheWidth: pixels,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, synchronous) =>
              synchronous || frame != null
              ? AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: child,
                )
              : fallback,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }

  /// Logos come from untrusted catalog data: only HTTPS hostnames are
  /// loaded, never IP literals or local names.
  static bool isLoadableLogo(Uri uri) {
    final host = uri.host.toLowerCase();
    return uri.scheme == 'https' &&
        host.contains('.') &&
        !host.endsWith('.local') &&
        !host.endsWith('.localhost') &&
        InternetAddress.tryParse(host) == null &&
        !host.startsWith('[');
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({
    required this.name,
    required this.size,
    required this.radius,
  });

  final String name;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final letter = name.characters
        .firstWhere((c) => RegExp(r'[A-Za-z0-9]').hasMatch(c), orElse: () => '')
        .toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            GlassTheme.primary.withValues(alpha: .32),
            GlassTheme.primary.withValues(alpha: .1),
          ],
        ),
        border: Border.all(color: GlassTheme.primary.withValues(alpha: .22)),
      ),
      child: letter.isEmpty
          ? Icon(
              Symbols.extension_rounded,
              color: GlassTheme.primary,
              size: size * .46,
            )
          : Text(
              letter,
              style: TextStyle(
                color: GlassTheme.coralBright,
                fontSize: size * .42,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
    );
  }
}
