// Profile > Profile card: the card's background, colour and animated accent
// (lib/src/theme/profile_styles.dart), with a live preview of the real card.
// Choices are a draft until Apply; leaving the page, or Discard, keeps the
// card as it was. Everyone can preview everything. Essentials, Gradients and
// the preset colours apply for every account; Cinematic backgrounds, effects
// and a colour of one's own need SupporterPerk.profileStyles, which
// ProfileController.setStyle checks again when saving. Each choice is a
// TvFocusable or a Material control, so touch, remote, mouse, keyboard and
// game controller all work.
import 'dart:async';

import 'package:flutter/material.dart';

import '../account/profile_controller.dart';
import '../account/supporter_controller.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/profile_styles.dart';
import '../theme/reelish_icons.dart';
import '../widgets/profile_card_backdrop.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';
import 'supporters_screen.dart';

class ProfileStyleScreen extends StatefulWidget {
  const ProfileStyleScreen({
    super.key,
    required this.profile,
    required this.supporters,
    required this.preview,
    this.onBack,
  });

  final ProfileController profile;
  final SupporterController supporters;

  /// The profile card as it would look in [style]: the page's own card, so
  /// the preview is what the profile will show.
  final Widget Function(ProfileStyle style) preview;
  final VoidCallback? onBack;

  @override
  State<ProfileStyleScreen> createState() => _ProfileStyleScreenState();
}

class _ProfileStyleScreenState extends State<ProfileStyleScreen> {
  late ProfileStyle _draft = widget.profile.style;
  bool _saving = false;

  bool get _perk => widget.supporters.has(SupporterPerk.profileStyles);

  void _set(ProfileStyle style) => setState(() => _draft = style);

  /// One node per background tile (null is Standard), kept for the page's
  /// life: a node handed from tile to tile would drop the focus of the tile
  /// the remote is on.
  final _tileNodes = <String?, FocusNode>{};

  FocusNode _tileNode(String? id) => _tileNodes[id] ??= FocusNode(
    debugLabel: 'background ${id ?? 'standard'}',
  );

  /// The action buttons come and go with the draft, so the one just pressed
  /// can vanish under the remote. With a remote or keyboard in use, focus
  /// moves to the background now selected instead of being lost.
  void _refocus() {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = _tileNodes[_draft.backdrop];
      if (mounted && node != null && node.context != null) {
        node.requestFocus();
      }
    });
  }

  /// [action] from an action button, then focus kept on the page.
  void _act(VoidCallback action) {
    action();
    _refocus();
  }

  @override
  void dispose() {
    for (final node in _tileNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _apply() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _saving = true);
    final applied = await widget.profile.setStyle(_draft, perk: _perk);
    if (!mounted) return;
    setState(() => _saving = false);
    _refocus();
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            applied
                ? 'Your profile card is updated.'
                : 'Cinematic cards are for Reelish Supporters.',
          ),
        ),
      );
  }

  Future<void> _openSupporters() async {
    await Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: widget.supporters),
      ),
    );
    unawaited(widget.supporters.refresh());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.profile, widget.supporters]),
    builder: (context, _) {
      final perk = _perk;
      final saved = widget.profile.style;
      final draftColor = _draft.palette?.primary;
      return SettingsPage(
        title: 'Profile card',
        subtitle:
            'Your card\'s background, colour and effect. Only you see it, '
            'on this device.',
        icon: ReelishIcons.palette,
        onBack: widget.onBack,
        footer: null,
        children: [
          // A picture of the card, not the card: nothing in it is reachable.
          Semantics(
            label: 'Preview of your profile card',
            child: ExcludeSemantics(
              child: ExcludeFocus(
                child: IgnorePointer(child: widget.preview(_draft)),
              ),
            ),
          ),
          _Actions(
            draft: _draft,
            saved: saved,
            perk: perk,
            saving: _saving,
            onApply: _apply,
            onDiscard: () => _act(() => _set(saved)),
            onRestoreDefault: () => _act(() => _set(ProfileStyle.standard)),
            onSupport: _openSupporters,
          ),
          for (final collection in ProfileBackdropCollection.values)
            SettingsSection(
              label: collection.label.toUpperCase(),
              description: collection.forSupporters && !perk
                  ? 'For Reelish Supporters. Preview any of them here.'
                  : null,
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: _BackdropGrid(
                    styles: [
                      // The card as it has always been, first.
                      if (collection == ProfileBackdropCollection.essentials)
                        null,
                      for (final style in ProfileBackdropStyle.all)
                        if (style.collection == collection) style,
                    ],
                    selected: _draft.backdrop,
                    glow: draftColor,
                    perk: perk,
                    onSelect: (id) => _set(_draft.withBackdrop(id)),
                    focusNode: _tileNode,
                  ),
                ),
              ],
            ),
          SettingsSection(
            label: 'PROFILE COLOUR',
            description:
                'The ring, the counts and the glow on your card. The rest of '
                'Reelish keeps its theme.',
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: _Colours(
                  selected: _draft.color,
                  perk: perk,
                  onSelect: (id) => _set(_draft.withColor(id)),
                ),
              ),
              if (_draft.hasCustomColor)
                _CustomColour(
                  colour: _draft.palette!.primary,
                  onChanged: (colour) =>
                      _set(_draft.withColor(AccentPalette.custom(colour).id)),
                ),
            ],
          ),
          SettingsSection(
            label: 'EFFECTS',
            description: [
              if (!perk) 'For Reelish Supporters.',
              DeviceCapabilities.isTv
                  ? 'On TV the card stays still, to keep the remote smooth.'
                  : 'Effects pause with reduced motion and when the card is '
                        'out of sight.',
            ].join(' '),
            children: [
              for (final effect in ProfileEffect.values)
                SettingsTile(
                  title: effect.label,
                  description: effect.description,
                  trailing: _EffectMark(
                    selected: _draft.effect == effect,
                    locked: effect != ProfileEffect.none && !perk,
                  ),
                  onTap: () => _set(_draft.withEffect(effect)),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// What can be done with the draft: apply it, discard it, or for an account
/// without the perk whose draft needs it, the way to the Supporters page.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.draft,
    required this.saved,
    required this.perk,
    required this.saving,
    required this.onApply,
    required this.onDiscard,
    required this.onRestoreDefault,
    required this.onSupport,
  });

  final ProfileStyle draft;
  final ProfileStyle saved;
  final bool perk;
  final bool saving;
  final VoidCallback onApply;
  final VoidCallback onDiscard;
  final VoidCallback onRestoreDefault;
  final VoidCallback onSupport;

  @override
  Widget build(BuildContext context) {
    final changed = draft != saved;
    final locked = draft.needsPerk && !perk;
    final String caption;
    if (!changed) {
      caption = saved.needsPerk && !perk
          ? 'Parts of your card are for Reelish Supporters, so the standard '
                'look shows in their place.'
          : 'This is your card.';
    } else if (locked) {
      caption =
          'Cinematic backgrounds, effects and a colour of your own are for '
          'Reelish Supporters.';
    } else {
      caption = 'Not applied yet.';
    }
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpace.md,
        bottom: SettingsMetrics.sectionGap,
      ),
      child: Column(
        children: [
          Text(
            caption,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.bodySmall,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              if (changed && locked)
                FilledButton.icon(
                  onPressed: onSupport,
                  icon: const Icon(ReelishIcons.supporter, size: 18),
                  label: const Text('Become a Supporter'),
                )
              else if (changed)
                FilledButton.icon(
                  onPressed: saving ? null : onApply,
                  icon: saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(ReelishIcons.check, size: 18),
                  label: const Text('Apply'),
                ),
              if (changed)
                TextButton(
                  onPressed: onDiscard,
                  child: const Text('Discard changes'),
                ),
              if (!draft.isStandard)
                TextButton(
                  onPressed: onRestoreDefault,
                  child: const Text('Standard card'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A collection's backgrounds in even columns; null is the standard card.
class _BackdropGrid extends StatelessWidget {
  const _BackdropGrid({
    required this.styles,
    required this.selected,
    required this.glow,
    required this.perk,
    required this.onSelect,
    required this.focusNode,
  });

  final List<ProfileBackdropStyle?> styles;
  final String? selected;
  final Color? glow;
  final bool perk;
  final ValueChanged<String?> onSelect;

  /// Each tile's own focus node, by background id.
  final FocusNode Function(String? id) focusNode;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpace.sm;
      final narrowest = DeviceCapabilities.usesTvLayout ? 150.0 : 110.0;
      final columns = [5, 4, 3, 2].firstWhere(
        (count) =>
            (constraints.maxWidth - spacing * (count - 1)) / count >= narrowest,
        orElse: () => 2,
      );
      final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final style in styles)
            _BackdropTile(
              style: style,
              width: width,
              glow: glow,
              selected: style?.id == selected,
              locked: (style?.forSupporters ?? false) && !perk,
              onSelect: () => onSelect(style?.id),
              focusNode: focusNode(style?.id),
            ),
        ],
      );
    },
  );
}

class _BackdropTile extends StatelessWidget {
  const _BackdropTile({
    required this.style,
    required this.width,
    required this.glow,
    required this.selected,
    required this.locked,
    required this.onSelect,
    required this.focusNode,
  });

  /// Null: the standard card.
  final ProfileBackdropStyle? style;
  final double width;
  final Color? glow;
  final bool selected;
  final bool locked;
  final VoidCallback onSelect;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final style = this.style;
    final duration = AppMotion.resolve(context, AppMotion.hover);
    final name = style?.name ?? 'Standard';
    return TvFocusable(
      onSelect: onSelect,
      focusNode: focusNode,
      // The remote starts on the card's current background.
      autofocus: DeviceCapabilities.isTv && selected,
      // Focus moved here from a button may be off screen.
      scrollAlignment: DeviceCapabilities.usesTvLayout ? .3 : null,
      borderRadius: AppRadius.lg,
      focusScale: 1.04,
      semanticLabel: [
        '$name background',
        if (selected) 'selected',
        if (locked) 'for Reelish Supporters',
      ].join(', '),
      child: AnimatedContainer(
        duration: duration,
        curve: AppMotion.move,
        width: width,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: selected
              ? GlassTheme.primary.withValues(alpha: .1)
              : GlassTheme.glassBackground,
          border: Border.all(
            color: selected ? GlassTheme.primary : GlassTheme.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: AspectRatio(
                    aspectRatio: 16 / 10,
                    child: style == null
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0, -.75),
                                radius: 1.1,
                                colors: [
                                  (glow ?? GlassTheme.primary).withValues(
                                    alpha: .26,
                                  ),
                                  const Color(0xFF17171E),
                                  const Color(0xFF121218),
                                ],
                                stops: const [0, .5, 1],
                              ),
                            ),
                          )
                        : ProfileCardBackdrop(style: style, glow: glow),
                  ),
                ),
                if (locked)
                  const Positioned(right: 4, bottom: 4, child: _LockMark()),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            ExcludeSemantics(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTextSize.label,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? GlassTheme.textPrimary : GlassTheme.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standard (the theme's and the app's colour), the presets, then a colour
/// of one's own.
class _Colours extends StatelessWidget {
  const _Colours({
    required this.selected,
    required this.perk,
    required this.onSelect,
  });

  final String? selected;
  final bool perk;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final custom = selected?.startsWith(AccentPalette.customPrefix) ?? false;
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        _Swatch(
          label: 'Standard',
          colour: null,
          selected: selected == null,
          locked: false,
          onSelect: () => onSelect(null),
        ),
        for (final accent in GlassTheme.accents)
          _Swatch(
            label: accent.label,
            colour: accent.primary,
            selected: selected == accent.id,
            locked: false,
            onSelect: () => onSelect(accent.id),
          ),
        _Swatch(
          label: 'Your own',
          colour: custom ? AccentPalette.fromId(selected)?.primary : null,
          custom: true,
          selected: custom,
          locked: !perk,
          onSelect: () {
            if (!custom) {
              onSelect(AccentPalette.custom(const Color(0xFF4FC3F7)).id);
            }
          },
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.colour,
    required this.selected,
    required this.locked,
    required this.onSelect,
    this.custom = false,
  });

  final String label;
  final Color? colour;
  final bool selected;
  final bool locked;
  final bool custom;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final size = DeviceCapabilities.isTv ? 48.0 : 40.0;
    final colour = this.colour;
    return TvFocusable(
      onSelect: onSelect,
      borderRadius: size,
      semanticLabel: [
        '$label colour',
        if (selected) 'selected',
        if (locked) 'for Reelish Supporters',
      ].join(', '),
      child: Tooltip(
        message: label,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colour,
                gradient: colour != null
                    ? null
                    : custom
                    ? const SweepGradient(
                        colors: [
                          Color(0xFFFF6B6B),
                          Color(0xFFFFD166),
                          Color(0xFF06D6A0),
                          Color(0xFF4FC3F7),
                          Color(0xFF9B5DE5),
                          Color(0xFFFF6B6B),
                        ],
                      )
                    : LinearGradient(
                        colors: [
                          GlassTheme.textPrimary.withValues(alpha: .25),
                          GlassTheme.textPrimary.withValues(alpha: .08),
                        ],
                      ),
                border: Border.all(
                  color: selected ? GlassTheme.textPrimary : GlassTheme.border,
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected
                  ? Icon(
                      ReelishIcons.check,
                      size: size * .45,
                      color: colour == null
                          ? GlassTheme.textPrimary
                          : const Color(0xFF101015),
                    )
                  : null,
            ),
            if (locked)
              const Positioned(right: -4, bottom: -4, child: _LockMark()),
          ],
        ),
      ),
    );
  }
}

/// A colour of one's own: its hue and how vivid it is. Its lightness is
/// raised as needed (AccentPalette.custom) so it reads on the dark card.
class _CustomColour extends StatelessWidget {
  const _CustomColour({required this.colour, required this.onChanged});

  final Color colour;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(colour);
    Color withHue(double hue) =>
        HSVColor.fromAHSV(1, hue, hsv.saturation.clamp(.35, 1), 1).toColor();
    Color withSaturation(double s) =>
        HSVColor.fromAHSV(1, hsv.hue, s, 1).toColor();
    return Column(
      children: [
        TvSliderNavigation(
          child: SettingsSliderTile(
            title: 'Hue',
            description: 'Round the colour wheel',
            value: hsv.hue.roundToDouble().clamp(0, 359),
            min: 0,
            max: 359,
            divisions: 72,
            valueLabel: '${hsv.hue.round()}°',
            onChanged: (hue) => onChanged(withHue(hue)),
          ),
        ),
        TvSliderNavigation(
          child: SettingsSliderTile(
            title: 'Vividness',
            description: 'From soft to saturated',
            value: (hsv.saturation * 100).roundToDouble().clamp(20, 100),
            min: 20,
            max: 100,
            divisions: 16,
            valueLabel: '${(hsv.saturation * 100).round()}%',
            onChanged: (s) => onChanged(withSaturation(s / 100)),
          ),
        ),
      ],
    );
  }
}

class _EffectMark extends StatelessWidget {
  const _EffectMark({required this.selected, required this.locked});

  final bool selected;
  final bool locked;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (locked) ...[const _LockMark(), const SizedBox(width: AppSpace.xs)],
      Icon(
        selected ? ReelishIcons.radioOn : ReelishIcons.radioOff,
        color: selected ? GlassTheme.primary : GlassTheme.muted,
        size: 22,
      ),
    ],
  );
}

/// A small lock in the Supporter gold.
class _LockMark extends StatelessWidget {
  const _LockMark();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: GlassTheme.surface,
      border: Border.all(color: const Color(0x66F5B942)),
    ),
    child: const Icon(ReelishIcons.lock, size: 12, color: Color(0xFFFFD98A)),
  );
}
