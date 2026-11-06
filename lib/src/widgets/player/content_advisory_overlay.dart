// The age rating and content advisory shown briefly when a title starts.
// It is a layer of its own over the video, so its timers and fades rebuild
// nothing else, and it takes no focus from the remote or keyboard.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/content_advisory.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'player_controls.dart';

/// Decides when the advisory shows, at most once per player session.
///
/// It waits for both playback and the advisory, whichever comes last. An
/// advisory that arrives after [lateLimit] is dropped, since a rating
/// appearing partway into a scene would be an interruption.
class ContentAdvisoryController extends ChangeNotifier {
  ContentAdvisoryController({
    this.displayFor = const Duration(seconds: 6),
    this.lateLimit = const Duration(seconds: 12),
  });

  /// How long the advisory stays on screen.
  final Duration displayFor;

  final Duration lateLimit;

  ContentAdvisory? _advisory;
  bool _started = false;
  bool _closed = false;
  bool _visible = false;
  bool _disposed = false;
  Timer? _timer;

  bool get visible => _visible;

  /// What to show; stays set after hiding so it can fade out.
  ContentAdvisory? get advisory => _advisory;

  /// The first frame played. Later calls, from a source or engine switch
  /// within the session, change nothing.
  void playbackStarted() {
    if (_started || _closed || _disposed) return;
    _started = true;
    _advisory == null ? _timer = Timer(lateLimit, _close) : _show();
  }

  /// The title's advisory, once known; null when it has none.
  void provide(ContentAdvisory? advisory) {
    if (_closed || _disposed || _advisory != null) return;
    if (advisory == null) return _close();
    _advisory = advisory;
    if (_started) _show();
  }

  void _show() {
    _timer?.cancel();
    _visible = true;
    _timer = Timer(displayFor, _close);
    notifyListeners();
  }

  /// Ends it for this session: it timed out, or the viewer dismissed it,
  /// paused or otherwise moved on.
  void dismiss() => _close();

  void _close() {
    _timer?.cancel();
    _closed = true;
    if (!_visible || _disposed) return;
    _visible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Top left, below the top bar while the controls show and in its place when
/// they hide, so the two never overlap. Keeps the same side margin as the
/// controls, which on TV is inside the overscan-safe area.
class ContentAdvisoryOverlay extends StatelessWidget {
  const ContentAdvisoryOverlay({
    super.key,
    required this.controller,
    required this.controlsVisible,
    this.tv = false,
    this.extraTop = 0,
  });

  final ContentAdvisoryController controller;
  final ValueListenable<bool> controlsVisible;
  final bool tv;

  /// More room above, for what else sits under the top bar.
  final double extraTop;

  static const _appear = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final width = MediaQuery.sizeOf(context).width;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controlsVisible]),
      builder: (context, _) {
        final advisory = controller.advisory;
        if (advisory == null) return const SizedBox.shrink();
        final visible = controller.visible;
        final clear = controlsVisible.value
            ? PlayerControlsLayout.topBarExtent(tv: tv)
            : PlayerControlsLayout.minimumInsets(tv: tv).top + AppSpace.md;
        return AnimatedPositioned(
          duration: AppMotion.resolve(context, _appear),
          curve: Curves.easeOutCubic,
          top: padding.top + clear + extraTop,
          left: padding.left + PlayerControlsLayout.contentEdge(tv: tv),
          child: IgnorePointer(
            ignoring: !visible,
            // Never a stop for the remote, and hidden from a screen reader
            // once gone.
            child: ExcludeFocus(
              child: ExcludeSemantics(
                excluding: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: AppMotion.resolve(
                    context,
                    visible ? _appear : AppMotion.exitOf(_appear),
                  ),
                  curve: Curves.easeOutCubic,
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    label: advisory.spokenLabel,
                    child: ExcludeSemantics(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: controller.dismiss,
                        child: _AdvisoryCard(
                          advisory: advisory,
                          tv: tv,
                          maxWidth: width < 600
                              ? width * 0.6
                              : (tv ? 440.0 : 360.0),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AdvisoryCard extends StatelessWidget {
  const _AdvisoryCard({
    required this.advisory,
    required this.tv,
    required this.maxWidth,
  });

  final ContentAdvisory advisory;
  final bool tv;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final base = tv ? AppTextSize.bodyLarge : AppTextSize.bodySmall;
    final small = tv ? AppTextSize.body : AppTextSize.micro;
    // No blur: a live BackdropFilter over video is costly for one short
    // card, and the dark fill keeps the contrast over bright frames.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xC70B0B0F),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: const Color(0x24FFFFFF)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tv ? AppSpace.md : AppSpace.sm,
              vertical: tv ? AppSpace.sm : AppSpace.xs + 2,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  advisory.heading,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: small,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: AppSpace.xxs),
                Text(
                  advisory.ratingLabel,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: tv ? AppTextSize.title : AppTextSize.titleSmall,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (advisory.descriptors.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    advisory.descriptorLine,
                    style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: base,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
                if (advisory.descriptorSource.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    advisory.descriptorSource,
                    style: TextStyle(color: Colors.white60, fontSize: small),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
