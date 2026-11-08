import 'package:flutter/material.dart';
import '../../theme/reelish_icons.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/glass_theme.dart';
import '../glass_button.dart';

/// Shared frame for the player's selection sheets: a drag handle, icon and
/// title, then a scrollable list. A near-opaque glass panel in the player's
/// colours with a painted finish: no blur, since it sits over playing video.
class PlayerSheetFrame extends StatelessWidget {
  const PlayerSheetFrame({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
    this.onBack,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  /// Set on a sub-page: the icon becomes a back button to the page before.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.lerp(
                GlassTheme.playerSurfaces.background,
                GlassTheme.playerSurfaces.surface,
                .6,
              )!.withValues(alpha: .95),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: const Color(0x1FFFFFFF)),
            ),
            child: GlassFinish(
              radius: 26,
              light: .55,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        if (onBack case final back?)
                          IconButton(
                            tooltip: 'Back',
                            onPressed: back,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(ReelishIcons.back, size: 22),
                          )
                        else
                          Icon(icon, color: GlassTheme.playerPrimary, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (subtitle?.isNotEmpty == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: GlassTheme.playerSurfaces.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: children,
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
  );
}

/// One selectable row. Selection shows as a coral radio, a tinted row and a
/// trailing label, so it never depends on color alone.
class PlayerSheetOption extends StatelessWidget {
  const PlayerSheetOption({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.detail,
    this.trailing,
  });

  final String title;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  /// Shown at the end of a selected row, such as `Playing`.
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: selected
          ? GlassTheme.playerPrimary.withValues(alpha: .12)
          : const Color(0x0AFFFFFF),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // A remote opens the sheet on the current choice.
        autofocus: selected && DeviceCapabilities.usesTvLayout,
        child: Semantics(
          selected: selected,
          button: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? ReelishIcons.filled(
                            selected
                                ? ReelishIcons.radioOn
                                : ReelishIcons.radioOff,
                          )
                        : (selected
                              ? ReelishIcons.radioOn
                              : ReelishIcons.radioOff),
                    size: 20,
                    color: selected ? GlassTheme.playerPrimary : Colors.white54,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (detail?.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              detail!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: GlassTheme.playerSurfaces.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selected && trailing != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      trailing!,
                      style: TextStyle(
                        color: GlassTheme.playerPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
