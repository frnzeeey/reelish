// A notice in the flow of a page: an icon tile, a title, a line of help and
// an optional action. Empty sections (no collections yet, an empty library)
// and setup prompts (no source installed) use it, on every interface.
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';

/// A card that tells the viewer what is missing here and, with [action],
/// how to fix it. A solid surface, not glass: it sits in the page, not over
/// it.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.action,
  });

  final IconData icon;

  /// A bold first line; a one-line notice has only its [message].
  final String? title;
  final String message;

  /// A button at the end, such as Browse or Create.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, size: AppIcon.sm, color: GlassTheme.primary),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title case final title?) ...[
                Text(
                  title,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.body,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpace.xxs),
              ],
              Text(
                message,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        if (action case final action?) ...[
          const SizedBox(width: AppSpace.xs),
          action,
        ],
      ],
    ),
  );
}
