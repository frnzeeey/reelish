// Phone: the sheet a long press on a recommended title opens, saying why it
// was recommended and offering Not interested, Already watched and More
// like this. Each choice can be undone from the notice that follows.

import 'package:flutter/material.dart';

import '../discovery/discovery_controller.dart';
import '../discovery/discovery_data.dart';
import '../models/media_item.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';

abstract final class RecommendationFeedbackSheet {
  static Future<void> show(
    BuildContext context, {
    required DiscoveryController discovery,
    required MediaItem item,
    required String reason,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final kind = await showModalBottomSheet<FeedbackKind>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _Sheet(item: item, reason: reason),
    );
    if (kind == null) return;
    await discovery.giveFeedback(kind, item);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(confirmation(kind)),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => discovery.undoFeedback(item),
          ),
        ),
      );
  }

  static String confirmation(FeedbackKind kind) => switch (kind) {
    FeedbackKind.notInterested => 'Hidden. You will see less like it.',
    FeedbackKind.alreadyWatched => 'Marked as watched',
    FeedbackKind.moreLikeThis => 'You will see more like it',
  };
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.item, required this.reason});

  final MediaItem item;
  final String reason;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      side: BorderSide(color: GlassTheme.border),
    ),
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: AppSpace.sm, bottom: AppSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: GlassTheme.textPrimary.withValues(alpha: .24),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        ReelishIcons.sparkle,
                        size: 15,
                        color: GlassTheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          reason,
                          style: TextStyle(color: GlassTheme.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _Action(
              icon: ReelishIcons.like,
              label: 'More like this',
              kind: FeedbackKind.moreLikeThis,
            ),
            _Action(
              icon: ReelishIcons.checkCircle,
              label: 'Already watched',
              kind: FeedbackKind.alreadyWatched,
            ),
            _Action(
              icon: ReelishIcons.dislike,
              label: 'Not interested',
              kind: FeedbackKind.notInterested,
            ),
          ],
        ),
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.kind});

  final IconData icon;
  final String label;
  final FeedbackKind kind;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
    leading: Icon(icon, color: GlassTheme.textPrimary),
    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    onTap: () => Navigator.pop(context, kind),
  );
}
