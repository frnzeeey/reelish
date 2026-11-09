// Profile > Avatar frame: the collection of avatar frames, with a live
// preview of the person's own avatar in the frame they are looking at. A
// Supporter equips any frame they may wear (the server decides, and the frame
// follows the account to every device); everyone else sees the collection
// locked, with a way to the Supporters page and no Equip button. The Founder's
// frame shows to the Founder only. Works by touch, remote, mouse, keyboard
// and game controller (each frame is a TvFocusable).
import 'dart:async';

import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../account/avatar_frames.dart';
import '../account/profile_controller.dart';
import '../account/supporter_controller.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../theme/avatar_frames.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/avatar_frame.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';
import 'supporters_screen.dart';

class AvatarFramesScreen extends StatefulWidget {
  const AvatarFramesScreen({
    super.key,
    this.onBack,
    this.frames,
    this.supporters,
    this.account,
    this.profile,
  });

  final VoidCallback? onBack;

  /// [AvatarFrames.instance], [SupporterController.instance] and so on when
  /// null.
  final AvatarFrames? frames;
  final SupporterController? supporters;
  final AccountController? account;
  final ProfileController? profile;

  @override
  State<AvatarFramesScreen> createState() => _AvatarFramesScreenState();
}

class _AvatarFramesScreenState extends State<AvatarFramesScreen> {
  late final AvatarFrames _frames = widget.frames ?? AvatarFrames.instance;
  late final SupporterController _supporters =
      widget.supporters ?? SupporterController.instance;

  /// The frame being looked at; starts on the one worn.
  String? _selected;
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    unawaited(_frames.refresh());
    unawaited(_supporters.refresh());
  }

  bool get _founder => _supporters.hasFounderPerk(FounderPerk.founderFrames);

  /// The frames this account sees: every one but the Founder's, which only
  /// the Founder sees, and closed limited editions it never collected.
  List<AvatarFrameStyle> get _shown => [
    for (final style in AvatarFrameStyle.all)
      if (!style.founderOnly || _founder)
        if (!style.limited ||
            _frames.mayEquip(style.id) ||
            _frames.state.collected.contains(style.id) ||
            _isOpen(style))
          style,
  ];

  static bool _isOpen(AvatarFrameStyle style) {
    final until = style.limitedUntil;
    return until == null ||
        !DateTime.now().toUtc().isAfter(until.add(const Duration(days: 1)));
  }

  Future<void> _equip(String? id) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await _frames.equip(id);
    if (!mounted) return;
    final name = AvatarFrameStyle.byId(id)?.name;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (result) {
            FrameChange.applied =>
              id == null
                  ? 'Frame removed on all your devices.'
                  : '$name is now your frame on all your devices.',
            FrameChange.notAllowed =>
              'Avatar frames are for Reelish Supporters.',
            FrameChange.unavailable =>
              'This limited edition can no longer be collected.',
            FrameChange.failed =>
              'The frame could not be changed. Check your connection and '
                  'try again.',
          }),
        ),
      );
  }

  Future<void> _openSupporters() async {
    await Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: _supporters),
      ),
    );
    unawaited(_supporters.refresh());
    unawaited(_frames.refresh());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_frames, _supporters]),
    builder: (context, _) {
      final selected = AvatarFrameStyle.byId(
        _touched ? _selected : _frames.equipped,
      );
      final shown = _shown;
      return SettingsPage(
        title: 'Avatar frame',
        subtitle:
            'A frame around your avatar, on every device and in '
            'watch parties.',
        icon: ReelishIcons.face,
        onBack: widget.onBack,
        children: [
          _Preview(
            style: selected,
            equipped: _frames.equipped,
            available: selected == null || _frames.mayEquip(selected.id),
            collected:
                selected != null &&
                _frames.state.collected.contains(selected.id),
            saving: _frames.saving,
            account: widget.account,
            profile: widget.profile,
            onEquip: () => _equip(selected?.id),
            onRemove: () => _equip(null),
            onSupport: _openSupporters,
          ),
          for (final collection in FrameCollection.values)
            if (shown.any((style) => style.collection == collection))
              SettingsSection(
                label: collection.label.toUpperCase(),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: _Grid(
                      styles: [
                        for (final style in shown)
                          if (style.collection == collection) style,
                      ],
                      selected: selected?.id,
                      equipped: _frames.equipped,
                      frames: _frames,
                      onSelect: (id) => setState(() {
                        _touched = true;
                        _selected = id;
                      }),
                    ),
                  ),
                ],
              ),
        ],
      );
    },
  );
}

/// The person's own avatar in the frame being looked at, its name and what
/// can be done with it.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.style,
    required this.equipped,
    required this.available,
    required this.collected,
    required this.saving,
    required this.account,
    required this.profile,
    required this.onEquip,
    required this.onRemove,
    required this.onSupport,
  });

  final AvatarFrameStyle? style;
  final String? equipped;
  final bool available;
  final bool collected;
  final bool saving;
  final AccountController? account;
  final ProfileController? profile;
  final VoidCallback onEquip;
  final VoidCallback onRemove;
  final VoidCallback onSupport;

  @override
  Widget build(BuildContext context) {
    final style = this.style;
    final tv = DeviceCapabilities.isTv;
    final size = tv ? 132.0 : 112.0;
    final avatar = MyProfileAvatar(
      size: size,
      account: account,
      profile: profile,
    );
    final worn = style != null && style.id == equipped;
    return Padding(
      padding: const EdgeInsets.only(bottom: SettingsMetrics.sectionGap),
      child: Column(
        children: [
          const SizedBox(height: AppSpace.lg),
          // Room above for a crown, below for a laurel's foot.
          Padding(
            padding: EdgeInsets.symmetric(vertical: size * .16),
            child: AnimatedSwitcher(
              duration: AppMotion.resolve(context, AppMotion.standard),
              child: KeyedSubtree(
                key: ValueKey(style?.id),
                child: style == null
                    ? Padding(
                        padding: EdgeInsets.all(AvatarFrame.paddingFor(size)),
                        child: avatar,
                      )
                    : AvatarFrame(style: style, size: size, child: avatar),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            style?.name ?? 'No frame',
            style: TextStyle(
              fontSize: tv ? AppTextSize.headline : AppTextSize.titleLarge,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpace.xxs),
          Text(
            style == null
                ? 'Your avatar on its own.'
                : _caption(style, collected: collected),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.bodySmall,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (style != null && !available)
            FilledButton.icon(
              onPressed: style.founderOnly ? null : onSupport,
              icon: const Icon(ReelishIcons.supporter, size: 18),
              label: const Text('Become a Supporter'),
            )
          else if (worn)
            OutlinedButton.icon(
              onPressed: saving ? null : onRemove,
              icon: const Icon(ReelishIcons.close, size: 18),
              label: const Text('Remove frame'),
            )
          else if (style != null)
            FilledButton.icon(
              autofocus: tv,
              onPressed: saving ? null : onEquip,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(ReelishIcons.check, size: 18),
              label: Text(
                style.limited && !collected ? 'Collect and equip' : 'Equip',
              ),
            ),
        ],
      ),
    );
  }

  static String _caption(AvatarFrameStyle style, {required bool collected}) {
    final until = style.limitedUntil;
    final edition = until == null
        ? style.collection.label
        : collected
        ? 'Limited edition, in your collection'
        : 'Limited edition, until ${_date(until)}';
    return '${style.description}\n$edition';
  }

  static String _date(DateTime day) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }
}

/// A collection's frames, in even columns.
class _Grid extends StatelessWidget {
  const _Grid({
    required this.styles,
    required this.selected,
    required this.equipped,
    required this.frames,
    required this.onSelect,
  });

  final List<AvatarFrameStyle> styles;
  final String? selected;
  final String? equipped;
  final AvatarFrames frames;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpace.sm;
      final narrowest = DeviceCapabilities.usesTvLayout ? 150.0 : 96.0;
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
            _FrameTile(
              style: style,
              width: width,
              selected: style.id == selected,
              equipped: style.id == equipped,
              locked: !frames.mayEquip(style.id),
              collected: frames.state.collected.contains(style.id),
              onSelect: () => onSelect(style.id),
            ),
        ],
      );
    },
  );
}

class _FrameTile extends StatelessWidget {
  const _FrameTile({
    required this.style,
    required this.width,
    required this.selected,
    required this.equipped,
    required this.locked,
    required this.collected,
    required this.onSelect,
  });

  final AvatarFrameStyle style;
  final double width;
  final bool selected;
  final bool equipped;
  final bool locked;
  final bool collected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final disc = (width * .52).clamp(48.0, 76.0);
    final duration = AppMotion.resolve(context, AppMotion.hover);
    return TvFocusable(
      onSelect: onSelect,
      borderRadius: AppRadius.lg,
      focusScale: 1.04,
      semanticLabel: [
        '${style.name} frame',
        if (equipped) 'equipped',
        if (locked)
          style.founderOnly ? 'for the Founder' : 'for Reelish Supporters',
        if (style.limited)
          collected ? 'limited edition, collected' : 'limited edition',
      ].join(', '),
      child: AnimatedContainer(
        duration: duration,
        curve: AppMotion.move,
        width: width,
        padding: const EdgeInsets.fromLTRB(6, 16, 6, 10),
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedScale(
                  duration: duration,
                  scale: selected ? 1.06 : 1,
                  child: Padding(
                    padding: EdgeInsets.only(top: disc * .12),
                    // A still frame on a quiet disc: the tile shows the
                    // frame, the preview shows it on the avatar.
                    child: AvatarFrame(
                      style: style,
                      size: disc,
                      animate: false,
                      child: Container(
                        width: disc,
                        height: disc,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              GlassTheme.textPrimary.withValues(alpha: .14),
                              GlassTheme.textPrimary.withValues(alpha: .05),
                            ],
                          ),
                        ),
                        child: Icon(
                          ReelishIcons.person,
                          size: disc * .46,
                          color: GlassTheme.textPrimary.withValues(alpha: .4),
                        ),
                      ),
                    ),
                  ),
                ),
                if (equipped)
                  const Positioned(right: -2, top: 0, child: _Mark.equipped()),
                if (locked)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: _Mark.locked(founder: style.founderOnly),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            ExcludeSemantics(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  style.name,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: AppTextSize.label,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? GlassTheme.textPrimary : GlassTheme.muted,
                  ),
                ),
              ),
            ),
            if (style.limited)
              ExcludeSemantics(
                child: Text(
                  collected ? 'Collected' : 'Limited',
                  style: const TextStyle(
                    fontSize: AppTextSize.caption,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE9C46A),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small round mark on a tile: equipped (a check on the accent), or
/// locked (a lock in the Supporter gold, or the Founder's crown).
class _Mark extends StatelessWidget {
  const _Mark.equipped() : locked = false, founder = false;
  const _Mark.locked({required this.founder}) : locked = true;

  final bool locked;
  final bool founder;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: locked ? GlassTheme.surface : GlassTheme.primary,
      border: Border.all(
        color: locked ? const Color(0x66F5B942) : GlassTheme.surface,
        width: locked ? 1 : 2,
      ),
    ),
    child: Icon(
      locked
          ? (founder ? ReelishIcons.founder : ReelishIcons.lock)
          : ReelishIcons.check,
      size: 12,
      color: locked ? const Color(0xFFFFD98A) : GlassTheme.background,
    ),
  );
}
