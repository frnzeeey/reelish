import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/analytics/analytics_service.dart';
import 'package:onfeed/src/diagnostics/crash_reporter.dart';
import 'package:onfeed/src/diagnostics/error_scrubber.dart';
import 'package:onfeed/src/diagnostics/local_error_log.dart';
import 'package:onfeed/src/diagnostics/playback_diagnostics.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/crash_report_consent_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('onfeed/crash-reports-test');

/// Records what the native side would receive.
List<MethodCall> _fakeNative({bool configured = true}) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isConfigured' => configured,
          'configure' => configured,
          _ => null,
        };
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

CrashReporter _reporter({bool sends = true, LocalErrorLog? log}) =>
    CrashReporter(channel: _channel, sendsReports: sends, localLog: log);

Future<CrashReporter> _granted() async {
  SharedPreferences.setMockInitialValues({CrashReporter.consentKey: 'granted'});
  final reporter = _reporter();
  await reporter.load();
  return reporter;
}

Iterable<Map<Object?, Object?>> _records(List<MethodCall> calls) => calls
    .where((call) => call.method == 'record')
    .map((call) => call.arguments as Map<Object?, Object?>);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ErrorScrubber', () {
    test('removes what must never leave the device', () {
      const secrets = {
        'https://cdn.example.net/v/abc.m3u8?token=s3cret': 'cdn.example',
        'magnet:?xt=urn:btih:abcdef': 'btih',
        'Authorization: Bearer abc.def': 'abc.def',
        'token=abcd1234': 'abcd1234',
        'viewer@example.com': 'viewer@',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig': 'eyJhbGci',
        'rnt_0123456789': 'rnt_0123',
        r'C:\Users\Sam\AppData\file.txt': 'Sam',
        '/data/user/0/app/file': '/data/user',
        'party 12345678': '12345678',
        'party 1234-5678': '1234-5678',
        'host 192.168.1.20': '192.168',
        'provider.example.to failed': 'provider.example',
      };
      for (final MapEntry(key: text, value: secret) in secrets.entries) {
        expect(
          ErrorScrubber.scrub(text),
          isNot(contains(secret)),
          reason: text,
        );
      }
    });

    test('keeps a programming error readable, on one short line', () {
      expect(
        ErrorScrubber.scrub('Bad state: No element\n  at index 3'),
        'Bad state: No element at index 3',
      );
      expect(
        ErrorScrubber.scrub('word ' * 200).length,
        ErrorScrubber.maxLength,
      );
    });

    test('keeps no message from errors that quote remote data', () {
      expect(
        ErrorScrubber.safeMessage(
          const SocketException('Failed host lookup: secret.example'),
        ),
        isNull,
      );
      expect(
        ErrorScrubber.safeMessage(const FormatException('{"token":"abc"}')),
        isNull,
      );
      expect(ErrorScrubber.safeMessage(Exception('viewer data')), isNull);
      expect(
        ErrorScrubber.safeMessage(
          PlatformException(code: 'x', message: 'https://a.example'),
        ),
        isNull,
      );
      expect(ErrorScrubber.safeMessage(StateError('No element')), isNotNull);
    });

    test('sorts errors into categories', () {
      expect(
        ErrorScrubber.categorize(const SocketException('x')),
        ErrorCategory.network,
      );
      expect(
        ErrorScrubber.categorize(TimeoutException('x')),
        ErrorCategory.timeout,
      );
      expect(ErrorScrubber.categorize(StateError('x')), ErrorCategory.unknown);
      expect(ErrorCategory.network.isExpected, isTrue);
      expect(ErrorCategory.framework.isExpected, isFalse);
    });
  });

  group('ParsedStack', () {
    test('reads release addresses and keeps them for symbolizing', () {
      final parsed = ParsedStack.of(
        StackTrace.fromString('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1, tid: 2, name 1.ui
build_id: 'abc123'
isolate_dso_base: 7000, vm_dso_base: 7000
isolate_instructions: 7100, vm_instructions: 7200
    #00 abs 0000007000a000 virt 00000000a000 _kDartIsolateSnapshotInstructions+0x1234
    #01 abs 0000007000b000 _kDartIsolateSnapshotInstructions+0x2234
'''),
      );
      expect(parsed.buildId, 'abc123');
      expect(parsed.frames.map((frame) => frame.method), [
        '_kDartIsolateSnapshotInstructions+0x1234',
        '_kDartIsolateSnapshotInstructions+0x2234',
      ]);
      expect(parsed.frames.first.file, 'libapp.so');
      expect(parsed.raw, contains('isolate_dso_base'));
    });

    test('keeps only file names from symbolic frames', () {
      final parsed = ParsedStack.of(
        StackTrace.fromString(
          '#0      Foo.bar.baz (file:///C:/Users/Sam/app/lib/foo.dart:12:3)\n'
          '#1      main (package:onfeed/main.dart:7:1)\n',
        ),
      );
      expect(parsed.frames.first.owner, 'Foo');
      expect(parsed.frames.first.method, 'bar.baz');
      expect(parsed.frames.first.file, 'foo.dart');
      expect(parsed.frames.first.line, 12);
      expect(parsed.frames.last.method, 'main');
      expect(parsed.raw, isEmpty);
    });
  });

  group('CrashReporter', () {
    test('sends nothing without consent and does not start Firebase', () async {
      final calls = _fakeNative();
      final reporter = _reporter();
      await reporter.load();
      reporter.recordError(StateError('x'), StackTrace.current);
      reporter.note('something');
      reporter.setContext(CrashContext.feature, 'home');
      await pumpEventQueue();
      expect(calls.map((call) => call.method), ['isConfigured']);
    });

    test('a refusal is remembered and sends nothing', () async {
      final calls = _fakeNative();
      SharedPreferences.setMockInitialValues({
        CrashReporter.consentKey: 'denied',
      });
      final reporter = _reporter();
      await reporter.load();
      reporter.recordError(StateError('x'), StackTrace.current);
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
      expect(calls.firstWhere((call) => call.method == 'configure').arguments, {
        'enabled': false,
      });
    });

    test('a build without Firebase never collects', () async {
      final calls = _fakeNative(configured: false);
      SharedPreferences.setMockInitialValues({
        CrashReporter.consentKey: 'granted',
      });
      final reporter = _reporter();
      await reporter.load();
      expect(reporter.collecting, isFalse);
      reporter.recordError(StateError('x'), StackTrace.current);
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
    });

    test('debug and Windows builds never reach the channel', () async {
      final calls = _fakeNative();
      final reporter = _reporter(sends: false);
      await reporter.load();
      await reporter.setConsent(true);
      reporter.recordError(StateError('x'), StackTrace.current);
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(reporter.available.value, isFalse);
    });

    test('with consent, sends a safe report with its category', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      reporter.recordError(StateError('bad state'), StackTrace.current);
      await pumpEventQueue();
      final report = _records(calls).single;
      expect(report['severity'], 'nonFatal');
      expect(report['category'], 'unknown');
      expect(report['message'], contains('bad state'));
      expect(report['frames'], isNotEmpty);
    });

    test('expected failures are notes, never reports', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      reporter.recordUncaught(
        const SocketException('Failed host lookup: secret.example'),
        StackTrace.current,
      );
      reporter.recordUncaught(TimeoutException('slow'), StackTrace.current);
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
      final logs = calls.where((call) => call.method == 'log');
      expect(logs, hasLength(2));
      expect(logs.toString(), isNot(contains('secret')));
    });

    test('an unknown exception reports its type, not its text', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      reporter.recordError(
        const FormatException('https://stream.example/a?token=1'),
        StackTrace.current,
      );
      await pumpEventQueue();
      expect(_records(calls).single['message'], '');
      expect(_records(calls).toString(), isNot(contains('stream.example')));
    });

    test('the same error is reported once a run', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      final stack = StackTrace.current;
      for (var i = 0; i < 50; i++) {
        reporter.recordError(StateError('x'), stack);
      }
      await pumpEventQueue();
      expect(_records(calls), hasLength(1));
    });

    test('at most maxReports distinct errors are sent in a run', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      for (var i = 0; i < CrashReporter.maxReports + 10; i++) {
        reporter.recordError(
          StateError('x'),
          StackTrace.current,
          reason: 'case $i',
        );
      }
      await pumpEventQueue();
      expect(_records(calls), hasLength(CrashReporter.maxReports));
    });

    test('errors before the choice is known are held, then sent', () async {
      final calls = _fakeNative();
      SharedPreferences.setMockInitialValues({
        CrashReporter.consentKey: 'granted',
      });
      final reporter = _reporter();
      reporter.recordError(StateError('early'), StackTrace.current);
      await reporter.load();
      await pumpEventQueue();
      expect(_records(calls), hasLength(1));
    });

    test('errors held before a refusal are dropped', () async {
      final calls = _fakeNative();
      final reporter = _reporter();
      reporter.recordError(StateError('early'), StackTrace.current);
      await reporter.load();
      await reporter.setConsent(false);
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
    });

    test('turning it on and off reaches the native side', () async {
      final calls = _fakeNative();
      final reporter = _reporter();
      await reporter.load();
      await reporter.setConsent(true);
      await reporter.setConsent(false);
      final switches = calls.where((call) => call.method == 'configure');
      expect(switches.map((call) => call.arguments), [
        {'enabled': true},
        {'enabled': false},
      ]);
      final saved = await SharedPreferences.getInstance();
      expect(saved.getString(CrashReporter.consentKey), 'denied');
    });

    test('context is sent on agreeing, and only short words pass', () async {
      final calls = _fakeNative();
      final reporter = _reporter();
      await reporter.load();
      reporter.setContext(CrashContext.feature, 'home');
      reporter.setContext(CrashContext.partyRole, '12345678');
      reporter.setContext(CrashContext.playbackState, 'A Movie Title');
      await reporter.setConsent(true);
      await pumpEventQueue();
      final keys = calls.where((call) => call.method == 'setKey').toList();
      expect(keys.single.arguments, {'key': 'feature', 'value': 'home'});
    });

    test('a broken poster and a silent error are not reports', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      reporter.recordFlutterError(
        FlutterErrorDetails(
          exception: StateError('image'),
          library: 'image resource service',
        ),
      );
      reporter.recordFlutterError(
        FlutterErrorDetails(exception: StateError('quiet'), silent: true),
      );
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
    });

    test('a framework error is reported as fatal', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      reporter.recordFlutterError(
        FlutterErrorDetails(
          exception: FlutterError('Build failed\nwidget tree'),
          stack: StackTrace.current,
        ),
      );
      await pumpEventQueue();
      final report = _records(calls).single;
      expect(report['severity'], 'fatal');
      expect(report['category'], 'framework');
      expect(report['message'], 'Build failed');
    });

    test('install reports, then runs the earlier handlers', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      final original = FlutterError.onError;
      final originalDispatcher = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = original;
        PlatformDispatcher.instance.onError = originalDispatcher;
      });
      var earlier = 0;
      FlutterError.onError = (_) => earlier++;
      PlatformDispatcher.instance.onError = null;

      reporter.install();
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('a'),
          stack: StackTrace.current,
        ),
      );
      final handled = PlatformDispatcher.instance.onError!(
        StateError('b'),
        StackTrace.current,
      );
      await pumpEventQueue();

      expect(earlier, 1, reason: 'the error is not swallowed');
      expect(handled, isFalse, reason: 'the default handling still runs');
      expect(_records(calls), hasLength(2));
    });

    test('a failing channel never reaches the caller', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'isConfigured') return true;
            throw PlatformException(code: 'broken');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );
      final reporter = await _granted();
      reporter.recordError(StateError('x'), StackTrace.current);
      await pumpEventQueue();
    });
  });

  group('Windows error log', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('reelish_log'));
    tearDown(() => directory.deleteSync(recursive: true));

    File logFile() => File(
      '${directory.path}${Platform.pathSeparator}logs'
      '${Platform.pathSeparator}errors.log',
    );

    test('writes scrubbed reports and notes locally', () async {
      final log = LocalErrorLog(directory: () async => directory);
      final calls = _fakeNative();
      final reporter = _reporter(sends: false, log: log);
      reporter.setContext(CrashContext.feature, 'home');
      await reporter.load();
      reporter.recordError(
        StateError('failed at https://a.example/x?token=1'),
        StackTrace.fromString('#0      Foo.bar (package:onfeed/foo.dart:1:2)'),
      );
      reporter.note('party 12345678 failed');
      await log.append('end');
      final text = logFile().readAsStringSync();
      expect(text, contains('nonFatal unknown StateError'));
      expect(text, contains('feature=home'));
      expect(text, contains('Foo.bar foo.dart:1'));
      expect(text, isNot(contains('a.example')));
      expect(text, isNot(contains('12345678')));
      expect(calls, isEmpty);
    });

    test('rotates instead of growing without limit', () async {
      final log = LocalErrorLog(directory: () async => directory);
      final line = 'x' * (LocalErrorLog.maxBytes ~/ 2);
      for (var i = 0; i < 5; i++) {
        await log.append(line);
      }
      expect(logFile().lengthSync(), lessThan(LocalErrorLog.maxBytes * 2));
      expect(
        File(
          '${logFile().parent.path}${Platform.pathSeparator}errors.old.log',
        ).existsSync(),
        isTrue,
      );
    });

    test('an unwritable folder is ignored', () async {
      final log = LocalErrorLog(
        directory: () async => throw const FileSystemException('denied'),
      );
      await log.append('entry');
    });
  });

  group('Playback failures', () {
    test('each kind has one side', () {
      for (final kind in PlaybackFailureKind.values) {
        expect(PlaybackDiagnostics.sideOf(kind), isNotNull);
      }
      expect(
        PlaybackDiagnostics.sideOf(PlaybackFailureKind.http),
        PlaybackFailureSide.provider,
      );
      expect(
        PlaybackDiagnostics.sideOf(PlaybackFailureKind.network),
        PlaybackFailureSide.network,
      );
      expect(
        PlaybackDiagnostics.sideOf(PlaybackFailureKind.decoder),
        PlaybackFailureSide.app,
      );
    });

    test('only app-side failures become reports', () async {
      final calls = _fakeNative();
      final reporter = await _granted();
      for (final kind in [
        PlaybackFailureKind.http,
        PlaybackFailureKind.network,
        PlaybackFailureKind.timeout,
        PlaybackFailureKind.source,
        PlaybackFailureKind.cancelled,
      ]) {
        PlaybackDiagnostics.failed(
          kind,
          engine: 'media3',
          wasPlaying: false,
          reporter: reporter,
        );
      }
      await pumpEventQueue();
      expect(_records(calls), isEmpty);
      expect(calls.where((call) => call.method == 'log'), hasLength(4));

      PlaybackDiagnostics.failed(
        PlaybackFailureKind.decoder,
        engine: 'mpv',
        wasPlaying: true,
        reporter: reporter,
      );
      await pumpEventQueue();
      final report = _records(calls).single;
      expect(report['category'], 'playback');
      expect(report['message'], 'playback decoder on mpv while_playing');
    });
  });

  group('Consent dialog', () {
    Future<CrashReporter> ask(
      WidgetTester tester, {
      required String tap,
    }) async {
      _fakeNative();
      final reporter = _reporter();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => CrashReportConsentDialog.maybeAsk(
                context,
                reporter: reporter,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
      return reporter;
    }

    testWidgets('Share turns reports on', (tester) async {
      final reporter = await ask(tester, tap: 'Share');
      expect(reporter.consent.value, AnalyticsConsent.granted);
      expect(reporter.collecting, isTrue);
    });

    testWidgets('No thanks refuses', (tester) async {
      final reporter = await ask(tester, tap: 'No thanks');
      expect(reporter.consent.value, AnalyticsConsent.denied);
      expect(reporter.collecting, isFalse);
    });
  });
}
