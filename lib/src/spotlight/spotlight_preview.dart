// A small Spotlight that shows how a preset moves: the real SpotlightDeck on
// made-up cards (colour fields standing in for artwork), turning every few
// seconds. Used by Settings › Appearance › Spotlight Experience; it loads no
// images and makes no requests, and its timer stops with it.
import 'dart:async';

import 'package:flutter/material.dart';

import 'spotlight_deck.dart';
import 'spotlight_motion.dart';

class SpotlightPreview extends StatefulWidget {
  const SpotlightPreview({
    super.key,
    required this.motion,
    this.height = 210,
    this.interval = const Duration(milliseconds: 2400),
  });

  final SpotlightMotion motion;
  final double height;

  /// Between turns; none under reduced motion.
  final Duration interval;

  @override
  State<SpotlightPreview> createState() => _SpotlightPreviewState();
}

class _SpotlightPreviewState extends State<SpotlightPreview> {
  /// Stand-ins for artwork: dusk, ocean, ember, forest, violet.
  static const _fields = [
    [Color(0xFF3A1C5C), Color(0xFFD9614C)],
    [Color(0xFF0B3D5C), Color(0xFF2FA4A9)],
    [Color(0xFF4A1A0E), Color(0xFFE59A3A)],
    [Color(0xFF13321F), Color(0xFF6FA35A)],
    [Color(0xFF221A4F), Color(0xFF8C6AE0)],
  ];
  static const _titles = [
    'Night Signal',
    'Low Tide',
    'Ember Road',
    'Green Hours',
    'Violet Hour',
  ];

  PageController? _controller;
  SpotlightMotionStyle? _style;
  Timer? _timer;
  int _page = _fields.length * 100;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final style = SpotlightDeck.styleFor(context, widget.motion);
    if (style != _style) {
      final old = _controller;
      _style = style;
      _controller = SpotlightDeck.controllerFor(style, page: _page);
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    _timer?.cancel();
    _timer = MediaQuery.disableAnimationsOf(context)
        ? null
        : Timer.periodic(widget.interval, (_) => _turn());
  }

  void _turn() {
    final controller = _controller;
    if (!mounted || controller == null || !controller.hasClients) return;
    unawaited(
      controller.animateToPage(
        _page + 1,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: widget.height,
      child: SpotlightDeck(
        controller: _controller!,
        style: _style!,
        itemCount: null,
        borderRadius: 18,
        onPageChanged: (page) => _page = page,
        itemBuilder: (context, page) => _body(page % _fields.length),
        foregroundBuilder: (context, page) => _words(page % _fields.length),
      ),
    ),
  );

  /// The card's body, as the Home card's artwork and scrim.
  Widget _body(int index) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: Stack(
      fit: StackFit.expand,
      children: [
        SpotlightZoom(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: _fields[index],
              ),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xB3000000)],
              stops: [.4, 1],
            ),
          ),
        ),
      ],
    ),
  );

  /// The card's words, drawn flat over the body as on Home.
  Widget _words(int index) => Padding(
    padding: const EdgeInsets.all(14),
    child: Align(
      alignment: Alignment.bottomLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SpotlightReveal(
            order: 0,
            child: Container(
              width: 54,
              height: 6,
              decoration: BoxDecoration(
                color: const Color(0xCCFFFFFF),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SpotlightReveal(
            order: 1,
            child: Text(
              _titles[index],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SpotlightReveal(
            order: 2,
            child: Container(
              width: 90,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0x80FFFFFF),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
