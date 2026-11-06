// The one-time question about sharing crash reports (Android phones, Android
// TV and Google TV, when the build has Firebase configured). It is separate
// from usage statistics: agreeing to one says nothing about the other.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../analytics/analytics_service.dart';
import '../diagnostics/crash_reporter.dart';
import 'update_dialog.dart';

/// Asks once whether to share crash reports. Nothing is sent before the
/// answer, and "No thanks" is focused first, so a remote's OK never opts
/// anyone in by accident.
class CrashReportConsentDialog extends StatelessWidget {
  const CrashReportConsentDialog({super.key});

  static const message =
      'When something goes wrong, a report can show what failed in the app '
      'so it can be fixed. It never includes your account, what you search '
      'for, or which providers or sites you stream from. You can change '
      'this anytime in Settings.';

  /// Shows the question when reports can be sent and the viewer has not
  /// answered yet. Completes once it is answered or not needed.
  static Future<void> maybeAsk(
    BuildContext context, {
    CrashReporter? reporter,
  }) async {
    final reports = reporter ?? CrashReporter.instance;
    await reports.load();
    if (!reports.available.value ||
        reports.consent.value != AnalyticsConsent.unknown ||
        !context.mounted) {
      return;
    }
    final granted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const CrashReportConsentDialog(),
    );
    // Closing without an answer (Back) counts as no.
    await reports.setConsent(granted == true);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.pop(context, false);
    },
    child: UpdateDialogFrame(
      icon: Symbols.bug_report_rounded,
      title: 'Share crash reports?',
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
