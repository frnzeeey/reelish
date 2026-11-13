// The Home card that offers the genre step to an existing account that has
// no discovery preferences yet. Phone and Windows show it (TV draws its own
// single focus target in tv_pages.dart). It never blocks Home, and Not now
// dismisses it on every device of the account.

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';

class DiscoveryPromptCard extends StatelessWidget {
  const DiscoveryPromptCard({
    super.key,
    required this.onChoose,
    required this.onDismiss,
    this.padding = const EdgeInsets.fromLTRB(18, 8, 18, 10),
  });

  static const title = 'Tell us what you love watching';
  static const message =
      'Pick a few genres and Home will lead with titles picked for you.';

  final VoidCallback onChoose;
  final VoidCallback onDismiss;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg + 2),
        border: Border.all(color: GlassTheme.primary.withValues(alpha: .25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.md + 2,
          AppSpace.sm + 2,
          AppSpace.xs,
          AppSpace.sm + 2,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Narrow phones put the button under the text.
            final narrow = constraints.maxWidth < 520;
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppType.titleSmall.copyWith(
                    color: GlassTheme.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: AppType.bodySmall.copyWith(color: GlassTheme.muted),
                ),
              ],
            );
            final choose = FilledButton(
              onPressed: onChoose,
              child: const Text('Choose genres'),
            );
            final dismiss = IconButton(
              tooltip: 'Not now',
              onPressed: onDismiss,
              icon: Icon(
                ReelishIcons.close,
                size: AppIcon.sm,
                color: GlassTheme.muted,
              ),
            );
            final icon = Padding(
              padding: const EdgeInsets.only(right: AppSpace.sm + 2),
              child: Icon(ReelishIcons.sparkle, color: GlassTheme.primary),
            );
            if (narrow) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: icon),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        text,
                        const SizedBox(height: AppSpace.sm - 2),
                        choose,
                      ],
                    ),
                  ),
                  dismiss,
                ],
              );
            }
            return Row(
              children: [
                icon,
                Expanded(child: text),
                const SizedBox(width: AppSpace.sm),
                choose,
                const SizedBox(width: AppSpace.xxs),
                dismiss,
              ],
            );
          },
        ),
      ),
    ),
  );
}
