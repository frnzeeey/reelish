// What a whole page or pane shows when it has nothing yet: a picture, a
// title, a line of help and an optional action, centred. For a notice inside
// a page's flow, use NoticeCard (notice_card.dart).
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';

/// A centred empty state: [leading] (or [icon] in the accent) above an
/// optional [title], the [message] and an optional [action].
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon,
    this.leading,
    this.title,
    this.action,
  }) : assert(icon != null || leading != null);

  final String message;

  /// An icon in the accent, when there is no [leading].
  final IconData? icon;

  /// A picture of its own, such as a friend's avatar; replaces [icon].
  final Widget? leading;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading ?? Icon(icon, size: 40, color: GlassTheme.primary),
          const SizedBox(height: AppSpace.sm),
          if (title case final title?) ...[
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppType.title.copyWith(color: GlassTheme.textPrimary),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: GlassTheme.muted, height: 1.4),
          ),
          if (action case final action?) ...[
            const SizedBox(height: AppSpace.md),
            action,
          ],
        ],
      ),
    ),
  );
}
