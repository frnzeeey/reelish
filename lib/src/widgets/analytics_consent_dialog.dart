// The one-time question about sharing usage statistics (Android phones,
// Android TV and Google TV, when the build has analytics configured).
import 'package:flutter/material.dart';
import '../theme/reelish_icons.dart';

import '../analytics/analytics_service.dart';
import 'update_dialog.dart';

/// Asks once whether to share anonymous usage statistics. Nothing is sent
/// before the answer, and "No thanks" is focused first, so a remote's OK
/// never opts anyone in by accident.
class AnalyticsConsentDialog extends StatelessWidget {
  const AnalyticsConsentDialog({super.key});

  static const message =
      'Help improve Reelish by sharing how the app is used: which pages '
      'and features you open, and whether playback starts or fails. It '
      'never includes your account, what you search for, or which providers '
      'or sites you stream from. You can change this anytime in Settings.';

  /// Shows the question when analytics can run and the viewer has not
  /// answered yet. Completes once it is answered or not needed.
  static Future<void> maybeAsk(
    BuildContext context, {
    AnalyticsService? service,
  }) async {
    final analytics = service ?? AnalyticsService.instance;
    await analytics.load();
    if (!analytics.available.value ||
        analytics.consent.value != AnalyticsConsent.unknown ||
        !context.mounted) {
      return;
    }
    final granted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AnalyticsConsentDialog(),
    );
    // Closing without an answer (Back) counts as no.
    await analytics.setConsent(granted == true);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.pop(context, false);
    },
    child: UpdateDialogFrame(
      icon: ReelishIcons.insights,
      title: 'Share usage statistics?',
      actions: [
        UpdateDialogButton(
          label: 'No thanks',
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        UpdateDialogButton(
          label: 'Share',
          primary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
      children: [Text(message, style: updateDialogBodyStyle(context))],
    ),
  );
}
