// The watch party screens' Windows layout pieces: a page frame centred in
// the window with the action beside the content (not a bar across the whole
// width), the poster, a short "how it works" strip, and the room code as
// eight boxes. Phone and TV keep their own layouts.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Three short steps: what a watch party does.
class PartyHowItWorks extends StatelessWidget {
  const PartyHowItWorks({super.key});

  static const _steps = [
    (Symbols.ios_share_rounded, 'Share the code', 'Friends join with it'),
    (
      Symbols.extension_rounded,
      'Everyone finds a source',
      'From their own plugins',
    ),
    (Symbols.sync_rounded, 'Watch in sync', 'Play, pause and seek together'),
  ];

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (index, (icon, title, detail)) in _steps.indexed) ...[
        if (index > 0) const SizedBox(width: AppSpace.md),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: GlassTheme.primary.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, size: 18, color: GlassTheme.primary),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: AppTextSize.bodySmall,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.label,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}

/// The room code as eight boxes in two groups of four, over one hidden text
/// field: typing, Backspace and Ctrl+V (digits are kept from any pasted
/// text) all work as in a field, and the next box to fill is highlighted.
class PartyCodeBoxes extends StatefulWidget {
  const PartyCodeBoxes({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<PartyCodeBoxes> createState() => _PartyCodeBoxesState();
}

class _PartyCodeBoxesState extends State<PartyCodeBoxes> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refresh);
  }

  @override
  void dispose() {
    _focus.removeListener(_refresh);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Party code',
    textField: true,
    value: widget.controller.text.split('').join(' '),
    child: GestureDetector(
      onTap: _focus.requestFocus,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // The field that takes the keys, out of sight under the boxes.
            Opacity(
              opacity: 0,
              child: ExcludeSemantics(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  keyboardType: TextInputType.number,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  onChanged: widget.onChanged,
                  onSubmitted: (_) => widget.onSubmitted?.call(),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final digits = value.text;
                final focused = _focus.hasFocus;
                Widget box(int index) {
                  final filled = index < digits.length;
                  final current =
                      focused &&
                      (index == digits.length ||
                          (digits.length == 8 && index == 7));
                  return AnimatedContainer(
                    duration: desktopMotion(context),
                    curve: DesktopSurfaces.curve,
                    width: 52,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: filled
                          ? GlassTheme.primary.withValues(alpha: .08)
                          : Colors.white.withValues(alpha: .04),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        width: current ? 2 : 1,
                        color: current
                            ? GlassTheme.primary
                            : filled
                            ? GlassTheme.primary.withValues(alpha: .4)
                            : DesktopSurfaces.hairline,
                      ),
                    ),
                    child: Text(
                      filled ? digits[index] : '',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  );
                }

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 8; i++) ...[
                      if (i == 4)
                        // The two halves, as the code is written.
                        const SizedBox(
                          width: 28,
                          child: Center(
                            child: Text(
                              '–',
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 22,
                              ),
                            ),
                          ),
                        )
                      else if (i > 0)
                        const SizedBox(width: AppSpace.xs),
                      box(i),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
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
