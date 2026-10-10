import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

/// Visual constants shared with the native launch screen in
/// `android/app/src/main/res`; change them together so the hand-off from
/// the system splash to Flutter has no jump.
abstract final class SplashSpec {
  static const background = Color(0xFF0B0B0F);

  /// Matches the 128dp logo in `launch_background.xml` and `splash_icon.xml`.
  static const logoSize = 128.0;
  static const logoAsset = 'assets/icons/reelish_icon.png';
}

/// The startup screen shown while [SplashGate] restores what the first
/// screen needs.
///
/// On Android the system splash has already shown the logo at this size and
/// position, so the logo is drawn fully visible from the first frame and
/// only a soft coral glow blooms in behind it: fading the logo out and back
/// in would read as a flicker. Platforms without a native splash get a
/// fade and gentle 0.94 → 1 scale reveal instead.
class SplashView extends StatefulWidget {
  const SplashView({
    super.key,
    this.showProgress = false,
    this.error,
    this.onRetry,
    this.revealLogo,
  });

  /// Shows a slim loading bar, only once startup is taking a noticeable time.
  final bool showProgress;

  /// When set, startup stopped and needs the user to retry.
  final String? error;
  final VoidCallback? onRetry;

  /// Fade and scale the logo in. Defaults to true except on Android, where
  /// the native splash already shows it.
  final bool? revealLogo;

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoScale;
  late final Animation<double> _glow;
  late final bool _reveal;

  @override
  void initState() {
    super.initState();
    _reveal =
        widget.revealLogo ?? defaultTargetPlatform != TargetPlatform.android;
    // One controller drives the whole entrance, then stops: nothing runs
    // continuously while the splash waits.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _logoOpacity = _reveal
        ? CurvedAnimation(
            parent: _controller,
            curve: const Interval(0, .7, curve: Curves.easeOut),
          )
        : kAlwaysCompleteAnimation;
    _logoScale = _reveal
        ? Tween<double>(begin: .94, end: 1).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
          )
        : kAlwaysCompleteAnimation;
    _glow = CurvedAnimation(
      parent: _controller,
      curve: const Interval(.25, 1, curve: Curves.easeOutCubic),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // A plain colored box, not a Scaffold: the logo centers on the whole
    // window, as the native splash does, regardless of system bar insets.
    return ColoredBox(
      color: SplashSpec.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: SizedBox.square(
              dimension: SplashSpec.logoSize,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Ambient coral light: a painted radial gradient, no blur.
                  Positioned(
                    left: -SplashSpec.logoSize,
                    right: -SplashSpec.logoSize,
                    top: -SplashSpec.logoSize,
                    bottom: -SplashSpec.logoSize,
                    child: FadeTransition(
                      opacity: _glow,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            colors: [
                              Color(0x47FF4D6D),
                              Color(0x14FF4D6D),
                              Color(0x00FF4D6D),
                            ],
                            stops: [0, .45, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                  FadeTransition(
                    opacity: _logoOpacity,
                    child: ScaleTransition(
                      scale: _logoScale,
                      child: Image.asset(
                        SplashSpec.logoAsset,
                        width: SplashSpec.logoSize,
                        height: SplashSpec.logoSize,
                        // Decoded once, at display size.
                        cacheWidth:
                            (SplashSpec.logoSize *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        filterQuality: FilterQuality.medium,
                        semanticLabel: 'Reelish',
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 32,
            right: 32,
            bottom: bottomInset + 56,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: widget.error != null
                  ? _StartupError(
                      key: const ValueKey('error'),
                      message: widget.error!,
                      onRetry: widget.onRetry,
                    )
                  : widget.showProgress
                  ? const _StartupProgress(key: ValueKey('progress'))
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          minHeight: 2.5,
          color: GlassTheme.primary,
          backgroundColor: Colors.white.withValues(alpha: .08),
          semanticsLabel: 'Starting Reelish',
        ),
      ),
    ),
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: GlassTheme.muted,
          fontSize: 13,
          height: 1.45,
        ),
      ),
      if (onRetry != null) ...[
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
      ],
    ],
  );
}

/// Restores what the first screen needs, shows [SplashView] meanwhile, and
/// fades to the screen [builder] returns as soon as that work finishes.
///
/// There is no minimum display time. [initialize] should contain only
/// critical, local work; anything optional belongs after the first screen.
/// The progress bar appears only if startup passes [progressDelay], and a
/// startup that passes [timeout] shows a retry instead of an endless splash.
class SplashGate<T> extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.initialize,
    required this.builder,
    this.progressDelay = const Duration(milliseconds: 1200),
    this.timeout = const Duration(seconds: 10),
    this.revealLogo,
  });

  final Future<T> Function() initialize;
  final Widget Function(BuildContext context, T result) builder;
  final Duration progressDelay;
  final Duration timeout;
  final bool? revealLogo;

  @override
  State<SplashGate<T>> createState() => _SplashGateState<T>();
}

class _SplashGateState<T> extends State<SplashGate<T>> {
  /// Boxed so a null [T] still counts as finished.
  ({T value})? _result;
  String? _error;
  bool _showProgress = false;
  Timer? _progressTimer;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final attempt = ++_attempt;
    _progressTimer?.cancel();
    _progressTimer = Timer(widget.progressDelay, () {
      if (mounted && attempt == _attempt && _result == null) {
        setState(() => _showProgress = true);
      }
    });
    try {
      final value = await widget.initialize().timeout(widget.timeout);
      // A retry or disposal since this attempt started wins.
      if (!mounted || attempt != _attempt || _result != null) return;
      _progressTimer?.cancel();
      setState(() => _result = (value: value));
    } catch (_) {
      if (!mounted || attempt != _attempt || _result != null) return;
      _progressTimer?.cancel();
      setState(() {
        _showProgress = false;
        _error = 'Reelish could not finish starting.';
      });
    }
  }

  void _retry() {
    setState(() => _error = null);
    _run();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: Duration(milliseconds: reduceMotion ? 0 : 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // The splash fades out with a slight forward drift while the first
      // screen fades in over the same dark background.
      transitionBuilder: (child, animation) {
        final isSplash = child.key == const ValueKey('splash');
        return FadeTransition(
          opacity: animation,
          child: isSplash && !reduceMotion
              ? ScaleTransition(
                  scale: Tween<double>(begin: 1.04, end: 1).animate(animation),
                  child: child,
                )
              : child,
        );
      },
      child: result == null
          ? SplashView(
              key: const ValueKey('splash'),
              showProgress: _showProgress,
              error: _error,
              onRetry: _retry,
              revealLogo: widget.revealLogo,
            )
          : KeyedSubtree(
              key: const ValueKey('app'),
              child: widget.builder(context, result.value),
            ),
    );
  }
}
