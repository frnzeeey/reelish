// Product analytics through Firebase Analytics on Android (phones, Android
// TV, Google TV), opt-in only. Windows has no Firebase Analytics, so every
// call there is a no-op. Analytics is never needed for the app to work:
// all calls are fire-and-forget and swallow their errors.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_events.dart';

/// Whether the viewer agreed to share usage statistics.
enum AnalyticsConsent { unknown, granted, denied }

/// Sends events to the native Firebase SDK, when it may.
///
/// Nothing leaves the device until [consent] is [AnalyticsConsent.granted]
/// and this build has a Firebase configuration ([available]). Events carry
/// no account details, tokens, search text, stream addresses or provider
/// names (see analytics_events.dart).
class AnalyticsService {
  AnalyticsService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? supportedPlatform,
  }) : _channel = channel ?? const MethodChannel('onfeed/analytics'),
       _supportedPlatform =
           supportedPlatform ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static AnalyticsService instance = AnalyticsService();

  /// Where the choice is kept: `granted` or `denied`; absent until asked.
  static const consentKey = 'onfeed.analytics.consent.v1';

  final MethodChannel _channel;
  final bool _supportedPlatform;

  /// Whether this build can send analytics at all: Android with a Firebase
  /// configuration. Settles after [load].
  final ValueNotifier<bool> available = ValueNotifier(false);

  final ValueNotifier<AnalyticsConsent> consent = ValueNotifier(
    AnalyticsConsent.unknown,
  );

  bool get collecting =>
      available.value && consent.value == AnalyticsConsent.granted;

  Future<void>? _loading;

  /// Reads the saved choice and tells the native SDK. Never throws, never
  /// blocks startup on the network (Firebase initializes locally).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (!_supportedPlatform) return;
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        consentKey,
      );
      consent.value = switch (saved) {
        'granted' => AnalyticsConsent.granted,
        'denied' => AnalyticsConsent.denied,
        _ => AnalyticsConsent.unknown,
      };
      available.value =
          await _channel.invokeMethod<bool>('isConfigured') ?? false;
      if (consent.value == AnalyticsConsent.granted) {
        await _configure(enabled: true);
      }
    } catch (_) {
      available.value = false;
    }
  }

  /// Saves the viewer's choice. Turning it off also deletes the analytics
  /// data still on the device and the device's analytics id.
  Future<void> setConsent(bool granted) async {
    if (!_supportedPlatform) return;
    final was = consent.value;
    consent.value = granted
        ? AnalyticsConsent.granted
        : AnalyticsConsent.denied;
    try {
      await (await SharedPreferences.getInstance()).setString(
        consentKey,
        granted ? 'granted' : 'denied',
      );
    } catch (_) {}
    if (!available.value) return;
    await _configure(enabled: granted, reset: !granted);
    if (granted && was != AnalyticsConsent.granted) {
      log(AnalyticsEvent.analyticsEnabled());
    }
  }

  Future<void> _configure({required bool enabled, bool reset = false}) async {
    try {
      await _channel.invokeMethod<bool>('configure', {
        'enabled': enabled,
        'reset': reset,
      });
    } catch (_) {
      // Analytics is optional; the app works the same without it.
    }
  }

  /// Sends [event] when collecting; otherwise does nothing.
  void log(AnalyticsEvent event) {
    if (!collecting) return;
    unawaited(
      _channel
          .invokeMethod<void>('logEvent', {
            'name': event.name,
            'parameters': event.parameters,
          })
          .catchError((Object _) {}),
    );
  }

  /// A Firebase user property (low-cardinality, never personal), such as
  /// which interface this device uses.
  void setUserProperty(String name, String value) {
    if (!collecting) return;
    unawaited(
      _channel
          .invokeMethod<void>('setUserProperty', {'name': name, 'value': value})
          .catchError((Object _) {}),
    );
  }

  /// A page the viewer moved to. Repeats of the same page are dropped, so a
  /// rebuild or a second tap on the current tab is not counted twice.
  void logScreen(String screen) {
    if (screen == _lastScreen) return;
    _lastScreen = screen;
    log(AnalyticsEvent.screenView(screen));
  }

  String? _lastScreen;
}
