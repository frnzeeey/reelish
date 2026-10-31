// The watch party screens' Windows layout pieces: a page frame centred in
// the window with the action beside the content (not a bar across the whole
// width), the poster, a short "how it works" strip, and the room code as
// eight boxes. Phone and TV keep their own layouts.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../desktop/desktop_widgets.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';

/// A Windows party page: Back and the title over a centred column no wider
/// than [maxWidth], on the page background with a soft accent glow.
class PartyDesktopFrame extends StatelessWidget {
  const PartyDesktopFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.maxWidth = 1040,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    body: DecoratedBox(
      // The accent glows from the top left, as on the desktop details page;
      // a gradient, so nothing blurs and the colour follows the accent.
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-.9, -1.1),
          radius: 1.2,
          colors: [
            GlassTheme.primary.withValues(alpha: .14),
            GlassTheme.background.withValues(alpha: 0),
          ],
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              DesktopMetrics.pagePadding,
              AppSpace.lg,
              DesktopMetrics.pagePadding,
              DesktopMetrics.pagePadding,
            ),
            child: ConstrainedBox(
              // At least the window's height, so short pages sit a little
              // above centre instead of hugging the top.
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - AppSpace.lg - 40,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Symbols.arrow_back_rounded),
                          ),
                          const SizedBox(width: AppSpace.xs),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: AppTextSize.headline,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -.3,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: const TextStyle(
                                    color: GlassTheme.muted,
                                    fontSize: AppTextSize.body,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.xl),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The title's poster, large, with a soft shadow; a quiet tile without one.
class PartyDesktopPoster extends StatelessWidget {
  const PartyDesktopPoster({
    super.key,
    required this.content,
    this.width = 260,
  });

  final PartyContent content;
  final double width;

  @override
  Widget build(BuildContext context) {
    final url = content.posterUrl;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: width,
      height: width * 1.5,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: DesktopSurfaces.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .45),
            blurRadius: 32,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: url.isEmpty
          ? const Icon(Symbols.movie_rounded, size: 48, color: GlassTheme.muted)
          : Image.network(
              url,
              fit: BoxFit.cover,
              cacheWidth: posterDecodeWidth(width * dpr),
              errorBuilder: (_, _, _) => const Icon(
                Symbols.movie_rounded,
                size: 48,
                color: GlassTheme.muted,
              ),
            ),
    );
  }
}

/// A surface card for the Windows party pages.
class PartyDesktopCard extends StatelessWidget {
  const PartyDesktopCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.xl),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1A1A22), Color(0xFF14141B)],
      ),
      borderRadius: BorderRadius.circular(DesktopSurfaces.radius + 6),
      border: Border.all(color: DesktopSurfaces.hairline),
    ),
    child: child,
  );
}

/// The primary action of a Windows party page: sized to its label.
class PartyDesktopButton extends StatelessWidget {
  const PartyDesktopButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: GlassTheme.primary,
        foregroundColor: GlassTheme.background,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        minimumSize: const Size(200, 52),
      ),
      onPressed: onPressed,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : Icon(icon, fill: 1),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    ),
  );
}
