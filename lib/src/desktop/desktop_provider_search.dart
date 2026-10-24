import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_theme.dart';
import 'desktop_widgets.dart';

/// "Searching providers…" over the Windows interface while a play request
/// from Home looks for a stream: a frosted card on the dimmed page, with
/// what is being looked for and a way to stop. Esc cancels too.
class DesktopProviderSearch extends StatefulWidget {
  const DesktopProviderSearch({
    super.key,
    required this.title,
    required this.onCancel,
    this.season,
    this.episode,
  });

  final String title;
  final int? season;
  final int? episode;
  final VoidCallback onCancel;

  @override
  State<DesktopProviderSearch> createState() => _DesktopProviderSearchState();
}

class _DesktopProviderSearchState extends State<DesktopProviderSearch> {
  @override
  void initState() {
    super.initState();
    // A key handler rather than focus, so focus is where it was once the
    // search ends.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    widget.onCancel();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.season == null || widget.episode == null
        ? null
        : 'S${widget.season} E${widget.episode}';
    final radius = BorderRadius.circular(24);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ModalBarrier(dismissible: false, color: Color(0xB8050507)),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: desktopMotion(context, 260),
              curve: DesktopSurfaces.curve,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.scale(scale: .96 + .04 * t, child: child),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 48,
                        offset: Offset(0, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    // One fixed-size blur, behind the card only.
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(
                                GlassTheme.primary.withValues(alpha: .1),
                                const Color(0xCC15151B),
                              ),
                              const Color(0xE60F0F14),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .1),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const _Spinner(),
                              const SizedBox(height: 22),
                              const Text(
                                'Searching providers…',
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text.rich(
                                TextSpan(
                                  children: [
                                    const TextSpan(
                                      text: 'Finding a stream for ',
                                    ),
                                    TextSpan(
                                      text: widget.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (episode != null)
                                      TextSpan(text: '  ·  $episode'),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xCCFFFFFF),
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Sources are checked as they arrive; this '
                                'can take a moment.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: GlassTheme.muted,
                                  fontSize: 12.5,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                onPressed: widget.onCancel,
                                icon: const Icon(
                                  Symbols.close_rounded,
                                  size: 18,
                                ),
                                label: const Text('Cancel'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: .06,
                                  ),
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: .2),
                                  ),
                                  shape: const StadiumBorder(),
                                  minimumSize: const Size(140, 44),
                                  textStyle: const TextStyle(
                                    fontFamily: GlassTheme.fontFamily,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'or press Esc',
                                style: TextStyle(
                                  color: GlassTheme.muted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coral ring turning around a search glyph, on a faint track.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 64,
    child: Stack(
      alignment: Alignment.center,
      children: [
        SizedBox.square(
          dimension: 64,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            strokeCap: StrokeCap.round,
            color: GlassTheme.primary,
            backgroundColor: Colors.white.withValues(alpha: .08),
          ),
        ),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: GlassTheme.primary.withValues(alpha: .14),
          ),
          child: Icon(
            Symbols.travel_explore_rounded,
            size: 22,
            color: GlassTheme.coralBright,
          ),
        ),
      ],
    ),
  );
}
