// Help & Support plumbing: where to reach the developer, the diagnostic
// summary a report carries (shown to the viewer before sending), and the
// submission to the Reelish API.
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../platform/device_capabilities.dart';
import '../services/app_metadata.dart';

/// Contact details: Reelish's official support address and project page.
/// A build can use another address with
/// `--dart-define=REELISH_SUPPORT_EMAIL=...` (empty hides the email row).
abstract final class SupportConfig {
  static const contactEmail = String.fromEnvironment(
    'REELISH_SUPPORT_EMAIL',
    defaultValue: 'reelishofficial@gmail.com',
  );
  static Uri get projectPage => Uri.parse(AppMetadata.projectUrl);
  static Uri get releaseNotes =>
      Uri.parse('${AppMetadata.projectUrl}/releases');

  /// GitHub's public issue tracker, for reports people want to follow.
  static Uri get publicIssues => Uri.parse('${AppMetadata.projectUrl}/issues');
}

enum ReportKind { bug, feedback }

/// Categories the Reelish API accepts, with their labels.
const bugCategories = <String, String>{
  'playback': 'Playback',
  'sources': 'Providers & sources',
  'catalog': 'Movies & series',
  'subtitles': 'Subtitles',
  'trakt': 'Trakt',
  'watch_party': 'Watch party',
  'updates': 'Updates',
  'account': 'Account & sign-in',
  'performance': 'Crashes & performance',
  'other': 'Something else',
};

const feedbackCategories = <String, String>{
  'feature_request': 'Feature request',
  'suggestion': 'Suggestion',
  'question': 'Question',
  'other': 'Something else',
};

const reportPlatforms = <String, String>{
  'android_phone': 'Android phone or tablet',
  'android_tv': 'Android TV or Google TV',
  'windows': 'Windows',
  'other': 'Other',
};

/// What a report says about the app and device: version, build, operating
/// system, interface, language and time. No account, device id, tokens,
/// history, providers or logs.
class SupportDiagnostics {
  const SupportDiagnostics(this.values);

  final Map<String, String> values;

  /// The platform this device most likely is, for the report form.
  static String currentPlatform() {
    if (DeviceCapabilities.isTv) return 'android_tv';
    if (defaultTargetPlatform == TargetPlatform.windows) return 'windows';
    if (defaultTargetPlatform == TargetPlatform.android) return 'android_phone';
    return 'other';
  }

  static Future<SupportDiagnostics> collect() async {
    String? version;
    String? build;
    try {
      final info = await AppMetadata.packageInfo;
      version = info.version;
      build = info.buildNumber;
    } catch (_) {}
    return SupportDiagnostics({
      'appVersion': ?version,
      'build': ?build,
      'os': kIsWeb ? 'web' : Platform.operatingSystem,
      if (!kIsWeb) 'osVersion': _short(Platform.operatingSystemVersion),
      'interface': DeviceCapabilities.isTv
          ? 'tv'
          : DeviceCapabilities.isDesktop
          ? 'desktop'
          : 'phone',
      if (!kIsWeb) 'locale': _short(Platform.localeName),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static String _short(String value) =>
      value.length > 100 ? value.substring(0, 100) : value;

  /// Labels for the review screen.
  static const labels = {
    'appVersion': 'Reelish version',
    'build': 'Build',
    'os': 'Operating system',
    'osVersion': 'System version',
    'interface': 'Interface',
    'locale': 'Language',
    'timestamp': 'Time (UTC)',
  };
}

/// One report as the viewer filled it in.
class SupportReport {
  const SupportReport({
    required this.kind,
    required this.category,
    required this.platform,
    required this.title,
    required this.description,
    this.steps = '',
    this.diagnostics,
  });

  final ReportKind kind;
  final String category;
  final String platform;
  final String title;
  final String description;
  final String steps;

  /// Null when the viewer chose not to include it.
  final SupportDiagnostics? diagnostics;

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'category': category,
    'platform': platform,
    'title': title.trim(),
    'description': description.trim(),
    if (kind == ReportKind.bug && steps.trim().isNotEmpty)
      'steps': steps.trim(),
    'diagnostics': ?diagnostics?.values,
  };

  /// The report as plain text, to copy when it cannot be sent.
  String toText() {
    final lines = <String>[
      title.trim(),
      '',
      description.trim(),
      if (steps.trim().isNotEmpty) ...['', 'Steps:', steps.trim()],
      '',
      'Category: ${(kind == ReportKind.bug ? bugCategories : feedbackCategories)[category] ?? category}',
      'Platform: ${reportPlatforms[platform] ?? platform}',
      if (diagnostics case final d?)
        for (final MapEntry(:key, :value) in d.values.entries)
          '${SupportDiagnostics.labels[key] ?? key}: $value',
    ];
    return lines.join('\n');
  }
}

/// A submission that did not go through, with a message for the viewer.
class SupportSubmitException implements Exception {
  const SupportSubmitException(this.message, {this.retryable = true});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

/// Sends reports to the Reelish API with the signed-in session.
class SupportService {
  SupportService({AccountController? account, AccountApi? api})
    : _account = account ?? AccountController.instance,
      _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);

  final AccountController _account;
  final AccountApi _api;

  /// Returns the report's reference id.
  Future<String> submit(SupportReport report) async {
    final token = await _account.accessToken();
    if (token == null) {
      throw const SupportSubmitException(
        'Sign in again to send a report.',
        retryable: false,
      );
    }
    try {
      return await _api.submitSupportReport(token, report.toJson());
    } on AccountApiException catch (error) {
      throw switch (error.code) {
        'network' => const SupportSubmitException(
          'No connection. Check your internet and try again.',
        ),
        'not_configured' => const SupportSubmitException(
          'Reports cannot be sent from this build.',
          retryable: false,
        ),
        'report_limit' => SupportSubmitException(
          error.message,
          retryable: false,
        ),
        'invalid_report' => SupportSubmitException(
          error.message,
          retryable: false,
        ),
        _ when error.status == 404 => const SupportSubmitException(
          'Reports are not available yet. Copy the report and email it to '
          'support, or post it on the project page.',
          retryable: false,
        ),
        _ => const SupportSubmitException(
          'The report could not be sent right now. Try again in a moment.',
        ),
      };
    }
  }
}
