// Settings › Appearance › Spotlight Experience: choose how the Home Spotlight
// moves. Every preset can be previewed here; Cinematic Depth and Minimal
// Motion are free, and the others are a supporter perk
// (SupporterPerk.spotlightMotion) that SpotlightMotionController refuses
// without it. The preview runs on made-up cards, so it costs no network
// requests or image decoding. Phone and Windows: TV Home has no Spotlight.
import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation/app_transitions.dart';
import '../spotlight/spotlight_preview.dart';
import '../spotlight/spotlight_motion.dart';
import '../spotlight/spotlight_motion_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/account_badges.dart';
import '../widgets/settings/settings_components.dart';
import 'supporters_screen.dart';

class SpotlightExperienceScreen extends StatefulWidget {
  const SpotlightExperienceScreen({super.key, this.controller, this.onBack});

  /// [SpotlightMotionController.instance] when null.
  final SpotlightMotionController? controller;
  final VoidCallback? onBack;

  @override
  State<SpotlightExperienceScreen> createState() =>
      _SpotlightExperienceScreenState();
}

class _SpotlightExperienceScreenState extends State<SpotlightExperienceScreen> {
  late final SpotlightMotionController _controller =
      widget.controller ?? SpotlightMotionController.instance;

  /// The preset shown in the preview; the saved one at first.
  late SpotlightMotion _previewing = _controller.saved;

  @override
  void initState() {
    super.initState();
    unawaited(
      _controller.load().then((_) {
        if (mounted) setState(() => _previewing = _controller.saved);
      }),
    );
  }

  void _show(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _apply() async {
    final motion = _previewing;
    if (!_controller.mayUse(motion)) return _explain();
    if (await _controller.select(motion)) {
      if (mounted) _show('${motion.label} is your Spotlight animation');
    }
  }

  /// An exclusive preset, for someone without the perk: what it is, and
  /// the way to support. Asked for by a tap, never shown unprompted.
  Future<void> _explain() async {
    final support = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const SupporterEmblem(size: 32),
        title: const Text('Spotlight animations'),
        content: Text(
          '${_previewing.label} is a thank-you to Reelish Supporters, with '
          'the other exclusive Spotlight animations. Cinematic Depth and '
          'Minimal Motion stay free for everyone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Become a Supporter'),
          ),
        ],
      ),
    );
    if (support != true || !mounted) return;
    await Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: _controller.supporters),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, _controller.supporters]),
    builder: (context, _) {
      final saved = _controller.saved;
      final inEffect = _controller.value;
      final previewing = _previewing;
      final locked = !_controller.mayUse(previewing);
      final reduced = MediaQuery.disableAnimationsOf(context);
      return SettingsPage(
        title: 'Spotlight Experience',
        subtitle:
            'Make your Reelish Spotlight feel the way you want. Choose the '
            'animation that matches your style.',
        icon: ReelishIcons.sparkle,
        onBack: widget.onBack,
        footer: null,
        children: [
          SettingsSection(
            label: 'PREVIEW',
            description: reduced
                ? 'Your device asks for reduced motion, so the Spotlight uses '
                      'Minimal Motion and does not turn on its own.'
                : null,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                child: SpotlightPreview(
                  key: ValueKey(previewing),
                  motion: previewing,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        previewing.label,
                        style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: AppTextSize.titleSmall,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (saved == previewing && !locked)
                      Text('In use', style: TextStyle(color: GlassTheme.muted))
                    else
                      FilledButton.icon(
                        onPressed: () => unawaited(_apply()),
                        icon: Icon(
                          locked ? ReelishIcons.lock : ReelishIcons.check,
                          size: 18,
                        ),
                        label: Text(locked ? 'Supporters only' : 'Use this'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (saved != inEffect)
            SettingsSection(
              description:
                  '${saved.label} returns when your support is confirmed '
                  'again. Until then, the Spotlight uses ${inEffect.label}.',
              children: const [],
            ),
          SettingsSection(
            label: 'ANIMATIONS',
            description: _controller.unlocked
                ? 'Thank you for supporting Reelish: every animation is yours.'
                : 'Choose one to preview it. The animations marked with a lock '
                      'are for Reelish Supporters.',
            children: [
              for (final motion in SpotlightMotion.values)
                _MotionTile(
                  motion: motion,
                  previewing: motion == previewing,
                  inUse: motion == inEffect,
                  locked: !_controller.mayUse(motion),
                  onTap: () => setState(() => _previewing = motion),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// A preset in the list: choosing it previews it.
class _MotionTile extends StatelessWidget {
  const _MotionTile({
    required this.motion,
    required this.previewing,
    required this.inUse,
    required this.locked,
    required this.onTap,
  });

  final SpotlightMotion motion;
  final bool previewing;
  final bool inUse;
  final bool locked;
  final VoidCallback onTap;

  static IconData _icon(SpotlightMotion motion) => switch (motion) {
    SpotlightMotion.cinematicDepth => ReelishIcons.movieFilter,
    SpotlightMotion.minimal => ReelishIcons.minus,
    SpotlightMotion.coverFlow => ReelishIcons.swapHorizontal,
    SpotlightMotion.reveal => ReelishIcons.sparkle,
    SpotlightMotion.floating => ReelishIcons.cloud,
    SpotlightMotion.stacked => ReelishIcons.stack,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    selected: inUse,
    child: SettingsTile(
      icon: _icon(motion),
      title: motion.label,
      description: motion.description,
      value: previewing ? 'Previewing' : null,
      onTap: onTap,
      showChevron: false,
      trailing: inUse
          ? Icon(
              ReelishIcons.checkCircleFilled,
              color: GlassTheme.primary,
              semanticLabel: 'In use',
            )
          : locked
          ? Icon(
              ReelishIcons.lock,
              color: GlassTheme.muted,
              semanticLabel: 'For Reelish Supporters',
            )
          : null,
    ),
  );
}
