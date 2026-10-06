import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';
import 'glass_box.dart';

/// "Searching providers…" while a play request looks for a stream. Back is
/// blocked so the search is not abandoned by accident; [onCancel] stops it.
class ProviderSearchDialog extends StatelessWidget {
  const ProviderSearchDialog({
    super.key,
    required this.title,
    required this.onCancel,
    this.season,
    this.episode,
  });

  final String title;
  final int? season;
  final int? episode;
  final VoidCallback onCancel;

  /// Shows the dialog on the root navigator. Dismiss it by popping that
  /// navigator; the returned future completes then.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required VoidCallback onCancel,
    int? season,
    int? episode,
  }) => showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => ProviderSearchDialog(
      title: title,
      season: season,
      episode: episode,
      onCancel: onCancel,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Dialog(
      backgroundColor: Colors.transparent,
      child: GlassBox(
        padding: const EdgeInsets.fromLTRB(22, 22, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: GlassTheme.primary),
                  const SizedBox(width: 18),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Searching providers…',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Finding a stream for $title'
                          '${season == null || episode == null ? '' : ' · S$season E$episode'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    ),
  );
}
