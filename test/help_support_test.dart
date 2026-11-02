import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/help_support_screen.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/support/help_content.dart';
import 'package:onfeed/src/support/support_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records reports instead of sending them.
class _FakeSupport extends SupportService {
  _FakeSupport({this.failWith, this.gate});
  final SupportSubmitException? failWith;
  final Completer<void>? gate;
  final sent = <SupportReport>[];

  @override
  Future<String> submit(SupportReport report) async {
    sent.add(report);
    await gate?.future;
    if (failWith case final error?) throw error;
    return '0123456789abcdef';
  }
}

const _details = SupportDiagnostics({
  'appVersion': '1.27.0',
  'build': '1027000',
  'os': 'android',
  'interface': 'tv',
});

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: GlassTheme.dark, home: page));
  await tester.pumpAndSettle();
}

Widget _form(_FakeSupport service, {ReportKind kind = ReportKind.bug}) =>
    ReportScreen(
      kind: kind,
      service: service,
      diagnostics: () async => _details,
    );

Future<void> _fillReport(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'What went wrong?'),
    'Video stays black',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Details'),
    'Audio plays but the picture is black on episode 2.',
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Settings opens Help & Support, and Back returns', (
    tester,
  ) async {
    final accent = AccentSettingsController();
    addTearDown(accent.dispose);
    await _pump(
      tester,
      Scaffold(
        body: SettingsScreen(
          accentSettings: accent,
          onAppearanceSettings: () {},
          onPlaybackSettings: () {},
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Help & Support'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Help & Support'));
    await tester.pumpAndSettle();
    expect(find.text('Frequently asked questions'), findsOneWidget);
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('Release notes'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Frequently asked questions'), findsNothing);
  });

  testWidgets('email support shows the official address, and copies it '
      'where no email app can open', (tester) async {
    await _pump(tester, const HelpSupportScreen());
    expect(find.text('Email support'), findsOneWidget);
    expect(find.text('reelishofficial@gmail.com'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    // No url_launcher plugin in tests: like a TV without an email app. Its
    // failure arrives on a real platform-channel reply, so let time pass.
    await tester.tap(find.text('Email support'));
    for (var i = 0; i < 10 && copied == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(copied, 'reelishofficial@gmail.com');
    expect(find.textContaining('was copied'), findsOneWidget);
  });

  testWidgets('FAQ searches, filters, expands and says when nothing matches', (
    tester,
  ) async {
    await _pump(tester, const FaqScreen());
    expect(find.text(faqEntries.first.question), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'offline');
    await tester.pumpAndSettle();
    expect(
      find.text('Can I download movies to watch offline?'),
      findsOneWidget,
    );
    expect(find.text('Why do I need to sign in with Trakt?'), findsNothing);

    // Expand, then collapse.
    const answerStart = 'No. Reelish streams; it has no offline downloads.';
    await tester.tap(find.text('Can I download movies to watch offline?'));
    await tester.pumpAndSettle();
    expect(find.textContaining(answerStart), findsOneWidget);
    await tester.tap(find.text('Can I download movies to watch offline?'));
    await tester.pumpAndSettle();
    expect(find.textContaining(answerStart), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz nothing');
    await tester.pumpAndSettle();
    expect(find.text('NO MATCHES'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Watch party'));
    await tester.pumpAndSettle();
    expect(find.text('How does a watch party work?'), findsOneWidget);
    expect(find.text('Why do I need to sign in with Trakt?'), findsNothing);
  });

  testWidgets('an article leads to a report with its problem filled in', (
    tester,
  ) async {
    final service = _FakeSupport();
    await _pump(tester, TroubleshootingScreen(service: service));
    final article = troubleshootingArticles.firstWhere(
      (a) => a.id == 'update_downloads',
    );
    await tester.tap(find.text(article.title));
    await tester.pumpAndSettle();
    expect(find.text('POSSIBLE CAUSES'), findsOneWidget);
    expect(find.text('TRY THIS'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Report this problem'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Report this problem'));
    await tester.pumpAndSettle();
    expect(find.text(article.title), findsWidgets);
    expect(find.text(bugCategories['updates']!), findsOneWidget);
  });

  testWidgets('the form needs a title and details before review', (
    tester,
  ) async {
    final service = _FakeSupport();
    await _pump(tester, _form(service));
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    expect(find.text('Add a short title.'), findsOneWidget);
    expect(find.text('Add a sentence or two.'), findsOneWidget);
    expect(find.text('Review your report'), findsNothing);
    expect(service.sent, isEmpty);
  });

  testWidgets('review shows exactly what is sent, then it is sent once', (
    tester,
  ) async {
    final gate = Completer<void>();
    final service = _FakeSupport(gate: gate);
    await _pump(tester, _form(service));
    await _fillReport(tester);
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    expect(find.text('Review your report'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Reelish version: 1.27.0'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);
    // A second press while sending does nothing.
    await tester.tap(find.text('Sending…'), warnIfMissed: false);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(find.text('Thank you'), findsOneWidget);
    expect(find.textContaining('Reference: 01234567'), findsOneWidget);
    final json = service.sent.single.toJson();
    expect(json['kind'], 'bug');
    expect(json['diagnostics'], _details.values);
  });

  testWidgets('without device details, none are sent', (tester) async {
    final service = _FakeSupport();
    await _pump(tester, _form(service));
    await _fillReport(tester);
    await tester.tap(find.text('Include app and device details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reelish version'), findsNothing);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(service.sent.single.toJson().containsKey('diagnostics'), isFalse);
  });

  testWidgets('a failed send keeps the report, offers retry and copy', (
    tester,
  ) async {
    final service = _FakeSupport(
      failWith: const SupportSubmitException('No connection.'),
    );
    await _pump(tester, _form(service));
    await _fillReport(tester);
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('NOT SENT'), findsOneWidget);
    expect(find.text('No connection.'), findsOneWidget);
    expect(find.text('Review and try again'), findsOneWidget);
    expect(find.text('Video stays black'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.text('Copy report'));
    await tester.pumpAndSettle();
    expect(copied, contains('Video stays black'));
    expect(find.text('Report copied.'), findsOneWidget);
  });

  testWidgets('feedback has its own categories and no steps field', (
    tester,
  ) async {
    await _pump(tester, _form(_FakeSupport(), kind: ReportKind.feedback));
    expect(find.text('Send feedback'), findsWidgets);
    expect(find.text('Feature request'), findsOneWidget);
    expect(find.textContaining('Steps to reproduce'), findsNothing);
  });

  testWidgets('on a TV the remote moves through Help & Support', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    await _pump(tester, const HelpSupportScreen());
    var opened = false;
    for (var i = 0; i < 6 && !opened; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          find
              .descendant(
                of: find.byWidget(focused.widget),
                matching: find.text('Frequently asked questions'),
              )
              .evaluate()
              .isNotEmpty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        opened = true;
      }
    }
    expect(opened, isTrue, reason: 'the D-pad reaches the FAQ row');
    expect(find.text('Search questions'), findsOneWidget);
  });

  group('content', () {
    test('troubleshooting reports use categories the API accepts', () {
      for (final article in troubleshootingArticles) {
        expect(bugCategories, contains(article.reportCategory));
        expect(article.causes, isNotEmpty);
        expect(article.solutions, isNotEmpty);
      }
      expect(
        troubleshootingArticles.map((a) => a.id).toSet(),
        hasLength(troubleshootingArticles.length),
      );
    });

    test('no question appears twice', () {
      expect(
        faqEntries.map((e) => e.question).toSet(),
        hasLength(faqEntries.length),
      );
    });
  });

  group('SupportService', () {
    Future<SupportService> service(
      Future<http.Response> Function(http.Request) handler,
    ) async {
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient(handler),
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final account = AccountController(
        api: api,
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'access',
            accessExpiresAt: now + 900,
            refreshToken: 'refresh',
            refreshExpiresAt: now + 86400,
            userId: 'u',
            username: 'user',
          ),
        ),
      );
      await account.restore();
      return SupportService(account: account, api: api);
    }

    const report = SupportReport(
      kind: ReportKind.feedback,
      category: 'suggestion',
      platform: 'windows',
      title: 'Idea',
      description: 'A queue for what to watch next.',
      steps: 'not sent for feedback',
    );

    test('posts the report and returns its id', () async {
      late http.Request sent;
      final support = await service((request) async {
        sent = request;
        return http.Response(jsonEncode({'id': 'abc-123'}), 201);
      });
      expect(await support.submit(report), 'abc-123');
      expect(sent.url.path, '/api/v1/support/reports');
      expect(sent.headers['Authorization'], 'Bearer access');
      final body = jsonDecode(sent.body) as Map;
      expect(body['kind'], 'feedback');
      expect(body.containsKey('steps'), isFalse);
    });

    test('maps failures to messages, retryable or not', () async {
      Future<SupportSubmitException> failure(int status, String code) async {
        final support = await service(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': code, 'message': 'Server says no.'},
            }),
            status,
          ),
        );
        try {
          await support.submit(report);
        } on SupportSubmitException catch (error) {
          return error;
        }
        fail('expected a failure');
      }

      expect((await failure(503, 'unavailable')).retryable, isTrue);
      final limit = await failure(429, 'report_limit');
      expect(limit.retryable, isFalse);
      expect(limit.message, 'Server says no.');
      expect((await failure(404, 'not_found')).retryable, isFalse);
    });
  });
}
