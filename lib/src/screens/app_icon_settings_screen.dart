// Settings → Appearance → App icon: the launcher icon presets in a grid.
// Android phones and tablets only (see lib/src/platform/app_icon.dart).

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../platform/app_icon.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';

class AppIconSettingsScreen extends StatefulWidget {
  const AppIconSettingsScreen({super.key, this.controller, this.onBack});

  /// Defaults to a controller over the Android launcher.
  final AppIconController? controller;
  final VoidCallback? onBack;

  @override
  State<AppIconSettingsScreen> createState() => _AppIconSettingsScreenState();
}

class _AppIconSettingsScreenState extends State<AppIconSettingsScreen> {
  late final AppIconController _controller =
      widget.controller ?? AppIconController();

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
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await _controller.select(preset.id);
    if (!mounted) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'App icon changed to ${preset.label}. The previous icon '
                      'goes away when you leave Reelish.'
                : 'The icon could not be changed. Try again.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => SettingsPage(
      title: 'App icon',
      subtitle: 'Choose the launcher icon that suits your Reelish.',
      icon: Symbols.apps_rounded,
      onBack: widget.onBack,
      children: [
        SettingsSection(
          label: 'ICONS',
          description:
              'Changing the icon does not affect your account, My list or '
              'history.',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = AppSpace.xs;
                  final columns = constraints.maxWidth >= 520 ? 5 : 3;
                  final width =
                      (constraints.maxWidth - spacing * (columns - 1)) /
                      columns;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final preset in AppIconPreset.all)
                        _IconChoice(
                          preset: preset,
                          width: width,
                          selected:
                              _controller.loaded &&
                              preset.id == _controller.current,
                          busy: _controller.applying == preset.id,
                          enabled:
                              _controller.loaded &&
                              _controller.applying == null,
                          onTap: () => _select(preset),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
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
            Symbols.info_rounded,
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
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final AppIconPreset preset;
  final double width;
  final bool selected;
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
      label: '${widget.preset.label} icon',
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
                              Symbols.check_rounded,
                              size: 14,
                              color: Colors.white,
                              weight: 700,
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
