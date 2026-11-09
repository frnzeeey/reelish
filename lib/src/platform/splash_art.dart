// The launch screen's artwork: the Reelish logo, or for the Founder the
// Sovereign Crest (FounderPerk.founderSplash). The splash shows before any
// account is restored, so the choice is the last one made on this device,
// kept locally and brought up to date once the saved supporter status is
// read. Android 13 and later show the crest in the system splash too
// (SovereignSplashTheme, set through the `onfeed/splash` channel); earlier
// Android versions keep the Reelish logo there, and Flutter's splash moves
// from it to the crest. Windows has no system splash.
//
// Like every Founder cosmetic this only decides what shows: nothing is
// unlocked by it, and a changed local value changes only this device's
// launch screen.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_controller.dart';
import '../account/supporter_controller.dart';

/// What the launch screen draws.
enum SplashArt { reelish, sovereignCrest }

/// Keeps the launch screen's artwork in step with the signed-in account.
class SplashArtStore {
  SplashArtStore({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel('onfeed/splash'),
      _android = android ?? (!kIsWeb && Platform.isAndroid);

  static final instance = SplashArtStore();

  static const _artKey = 'reelish.splash_art.v1';
  static const _nativeKey = 'reelish.splash_art.native.v1';

  final MethodChannel _channel;
  final bool _android;

  SplashArt _art = SplashArt.reelish;
  SplashArt _native = SplashArt.reelish;

  /// What this launch's splash shows.
  SplashArt get art => _art;

  /// What Android's system splash showed at this launch, which Flutter's
  /// first frame continues from. Always [SplashArt.reelish] off Android.
  SplashArt get nativeArt => _android ? _native : SplashArt.reelish;

  /// Reads the saved choice: before the first frame, so the splash draws
  /// the right artwork from the start. A failed read keeps the Reelish logo.
  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _art = _parse(preferences.getString(_artKey));
      _native = _parse(preferences.getString(_nativeKey));
    } catch (_) {
      _art = SplashArt.reelish;
      _native = SplashArt.reelish;
    }
  }

  static SplashArt _parse(String? name) => SplashArt.values.firstWhere(
    (art) => art.name == name,
    orElse: () => SplashArt.reelish,
  );

  AccountController? _account;
  SupporterController? _supporters;
  Future<void>? _syncing;
  bool _again = false;

  /// Follows [account] and [supporters] from now on: the crest for the
  /// Founder, the logo for anyone else or no one. Call once the saved
  /// supporter status is restored, so a Founder's launch is not mistaken
  /// for a signed-out one.
  void attach(AccountController account, SupporterController supporters) {
    _account?.removeListener(_changed);
    _supporters?.removeListener(_changed);
    _account = account..addListener(_changed);
    _supporters = supporters..addListener(_changed);
    // Every launch: Android's stored splash theme can outlive this app's
    // own record of it (for example after its data is cleared).
    _changed(force: true);
  }

  void _changed({bool force = false}) {
    if (_syncing != null) {
      _again = true;
      return;
    }
    _syncing = _sync(force: force).whenComplete(() {
      _syncing = null;
      if (_again) {
        _again = false;
        _changed();
      }
    });
  }

  /// The pending update, for tests.
  @visibleForTesting
  Future<void> get settled async {
    while (_syncing != null) {
      await _syncing;
    }
  }

  SplashArt get _wanted {
    final account = _account;
    final supporters = _supporters;
    if (account == null || supporters == null || account.userId == null) {
      return SplashArt.reelish;
    }
    return supporters.hasFounderPerk(FounderPerk.founderSplash)
        ? SplashArt.sovereignCrest
        : SplashArt.reelish;
  }

  /// The artwork the system splash was last asked for in this launch: once
  /// per value, since below Android 13 the request never succeeds.
  SplashArt? _nativeAsked;

  Future<void> _sync({bool force = false}) async {
    final wanted = _wanted;
    final nativeStale = _android && _native != wanted && _nativeAsked != wanted;
    if (wanted == _art && !nativeStale && !force) return;
    _art = wanted;
    if (_android) _nativeAsked = wanted;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_artKey, wanted.name);
      if (_android) {
        final applied =
            await _channel.invokeMethod<bool>('set', {
              'crest': wanted == SplashArt.sovereignCrest,
            }) ??
            false;
        // Below Android 13 the system splash always shows the logo.
        _native = applied ? wanted : SplashArt.reelish;
        await preferences.setString(_nativeKey, _native.name);
      }
    } catch (_) {
      // Tried again on the next change or launch; the splash is cosmetic.
    }
  }
}
