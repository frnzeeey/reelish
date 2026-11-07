// Settings → Appearance → App icon: the launcher icon presets in a grid.
// Android phones and tablets only (see lib/src/platform/app_icon.dart). Two
// icons are free; the supporter collection shows to everyone, and opens for
// Reelish Supporters.

import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/reelish_icons.dart';

import '../account/supporter_controller.dart';
import '../navigation/app_transitions.dart';
import '../platform/app_icon.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/account_badges.dart';
import '../widgets/settings/settings_components.dart';
import 'supporters_screen.dart';

class AppIconSettingsScreen extends StatefulWidget {
  const AppIconSettingsScreen({
    super.key,
    this.controller,
    this.onBack,
    this.supporters,
  });

  /// Defaults to a controller over the Android launcher.
  final AppIconController? controller;
  final VoidCallback? onBack;

  /// For the default controller and the Supporters page;
  /// [SupporterController.instance] when null.
  final SupporterController? supporters;

  @override
  State<AppIconSettingsScreen> createState() => _AppIconSettingsScreenState();
}

class _AppIconSettingsScreenState extends State<AppIconSettingsScreen> {
  late final SupporterController _supporters =
      widget.supporters ?? SupporterController.instance;
  late final AppIconController _controller =
      widget.controller ?? AppIconController(supporters: _supporters);

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  Future<void> _select(AppIconPreset preset) async {
    if (!_controller.unlocked(preset)) return _explain(preset);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await _controller.select(preset.id);
    if (!mounted) return;
    // The server said no: the saved status was out of date.
    if (result == AppIconChange.supportersOnly) return _explain(preset);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (result) {
            AppIconChange.applied =>
              'App icon changed to ${preset.label}. The previous icon '
                  'goes away when you leave Reelish.',
            AppIconChange.unverified =>
              'Your Supporter status could not be checked. Check your '
                  'connection and try again.',
            _ => 'The icon could not be changed. Try again.',
          }),
        ),
      );
  }

  /// A supporter icon, for someone who is not one: what it is, and the way
  /// to support. Asked for by a tap, never shown unprompted.
  Future<void> _explain(AppIconPreset preset) async {
    final support = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (context) => _SupporterIconSheet(preset: preset),
    );
    if (support != true || !mounted) return;
    await Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: _supporters),
      ),
    );
    // A donation that counted opens the collection on the way back.
    unawaited(_supporters.refresh());
  }

  Widget _grid(List<AppIconPreset> presets) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpace.xs;
      final columns = constraints.maxWidth >= 520 ? 5 : 3;
      final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final preset in presets)
            _IconChoice(
              preset: preset,
              width: width,
              selected: _controller.loaded && preset.id == _controller.current,
              // The icon already on the launcher is never shown locked.
              locked:
                  !_controller.unlocked(preset) &&
                  preset.id != _controller.current,
              busy: _controller.applying == preset.id,
              enabled: _controller.loaded && _controller.applying == null,
              onTap: () => _select(preset),
            ),
        ],
      );
    },
  );

  static Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      text,
      style: const TextStyle(
        color: GlassTheme.muted,
        fontSize: AppTextSize.label,
        fontWeight: FontWeight.w700,
        letterSpacing: .4,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => SettingsPage(
      title: 'App icon',
      subtitle: 'Choose the launcher icon that suits your Reelish.',
      icon: ReelishIcons.grid,
      onBack: widget.onBack,
      children: [
        SettingsSection(
          label: 'FREE',
          description:
              'Yours to use, always. Changing the icon does not affect your '
              'account, My list or history.',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: _grid(
                AppIconPreset.all
                    .where((p) => p.group == AppIconGroup.free)
                    .toList(),
              ),
            ),
          ],
        ),
        SettingsSection(
          label: 'SUPPORTER COLLECTION',
          description: _controller.supporter
              ? 'Thank you for supporting Reelish. Every icon is yours.'
              : 'A thank-you to Reelish Supporters. Tap an icon to see how '
                    'to unlock it.',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _caption('Signature'),
                  _grid(
                    AppIconPreset.all
                        .where((p) => p.group == AppIconGroup.signature)
                        .toList(),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _caption('Colours'),
                  _grid(
                    AppIconPreset.all
                        .where((p) => p.group == AppIconGroup.colour)
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!_controller.supporter &&
            !AppIconPreset.byId(_controller.current).free)
          const _FootNote(
            text:
                'Your current icon is from the supporter collection. It stays '
                'until you choose another.',
          ),
        const _FootNote(
          text:
              'Your selected icon appears in the app list straight away and '
              'replaces the previous one when you leave Reelish. A Reelish '
              'shortcut on your home screen may be removed when the icon '
              'changes; add it again from the app list.',
        ),
      ],
    ),
  );
}

/// A note under a section, in the section description's style.
class _FootNote extends StatelessWidget {
  const _FootNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, SettingsMetrics.sectionGap),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            ReelishIcons.info,
            size: AppIcon.xs,
            color: GlassTheme.muted,
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.label,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

class _IconChoice extends StatefulWidget {
  const _IconChoice({
    required this.preset,
    required this.width,
    required this.selected,
    required this.locked,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final AppIconPreset preset;
  final double width;
  final bool selected;

  /// A supporter icon this account cannot choose yet: shown in full, with a
  /// small lock; a tap explains instead of applying.
  final bool locked;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_IconChoice> createState() => _IconChoiceState();
}

class _IconChoiceState extends State<_IconChoice> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.resolve(context, AppMotion.hover);
    final icon = (widget.width - 28).clamp(48.0, 76.0);
    final border = _focused
        ? Colors.white
        : widget.selected
        ? GlassTheme.primary
        : GlassTheme.border;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.locked
          ? '${widget.preset.label} icon, for Reelish Supporters'
          : '${widget.preset.label} icon',
      child: SizedBox(
        width: widget.width,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: widget.enabled && !widget.selected ? widget.onTap : null,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: AnimatedContainer(
              duration: duration,
              curve: AppMotion.move,
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                color: widget.selected
                    ? GlassTheme.primary.withValues(alpha: .1)
                    : GlassTheme.glassBackground,
                border: Border.all(
                  color: border,
                  width: widget.selected || _focused ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedScale(
                        duration: duration,
                        scale: widget.selected ? 1.04 : 1,
                        child: Container(
                          width: icon,
                          height: icon,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(icon * .24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x55000000),
                                blurRadius: 12,
                                offset: Offset(0, 5),
                              ),
                            ],
                          ),
                          child: ExcludeSemantics(
                            child: Image.asset(
                              widget.preset.preview,
                              width: icon,
                              height: icon,
                              cacheWidth:
                                  (icon *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .ceil(),
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        ),
                      ),
                      if (widget.busy)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x88000000),
                              borderRadius: BorderRadius.circular(icon * .24),
                            ),
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (widget.locked)
                        const Positioned(right: -5, bottom: -5, child: _Lock()),
                      if (widget.selected)
                        Positioned(
                          right: -6,
                          top: -6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: GlassTheme.primary,
                              border: Border.all(
                                color: GlassTheme.surface,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              ReelishIcons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  // Already the button's label; read out once.
                  ExcludeSemantics(
                    child: Text(
                      widget.preset.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTextSize.label,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: widget.selected
                            ? GlassTheme.textPrimary
                            : GlassTheme.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small lock on a supporter icon: quiet, in the Supporter gold.
class _Lock extends StatelessWidget {
  const _Lock();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: GlassTheme.surface,
      border: Border.all(color: const Color(0x66F5B942)),
    ),
    child: const Icon(ReelishIcons.lock, size: 12, color: Color(0xFFFFD98A)),
  );
}

/// What a supporter icon is, for someone who is not a supporter yet.
class _SupporterIconSheet extends StatelessWidget {
  const _SupporterIconSheet({required this.preset});

  final AppIconPreset preset;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      side: BorderSide(color: GlassTheme.border),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset(
                preset.preview,
                width: 96,
                height: 96,
                cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SupporterEmblem(size: 18),
                const SizedBox(width: AppSpace.xs),
                Flexible(
                  child: Text(
                    preset.label,
                    style: const TextStyle(
                      fontSize: AppTextSize.title,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            const Text(
              'Part of the supporter collection: every app icon, as a '
              'thank-you to the people who fund Reelish. Default and Slate '
              'stay free for everyone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GlassTheme.muted, height: 1.4),
            ),
            const SizedBox(height: AppSpace.lg),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: GlassTheme.primary,
                  foregroundColor: GlassTheme.background,
                ),
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(ReelishIcons.supporter),
                label: const Text(
                  'Become a Supporter',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
}
