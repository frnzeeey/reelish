import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/player/player_pip.dart';

class _Player implements PlayerPipListener {
  final changes = <bool>[];
  var toggles = 0;

  @override
  void onPipChanged(bool inPip) => changes.add(inPip);

  @override
  void onPipTogglePlay() => toggles++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> sent;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    PlayerPip.resetForTest();
    sent = [];
    messenger.setMockMethodCallHandler(PlayerPip.channel, (call) async {
      sent.add(call);
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(PlayerPip.channel, null);
    PlayerPip.resetForTest();
  });

  /// Delivers a call from Android to the Dart side of the channel.
  Future<void> fromAndroid(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        PlayerPip.channel.name,
        PlayerPip.channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  test('the state reaches Android only when it changes', () {
    PlayerPip.report(autoEnter: true, playing: true, ratio: 1.7777);
    PlayerPip.report(autoEnter: true, playing: true, ratio: 1.7781);
    PlayerPip.report(autoEnter: false, playing: false, ratio: 1.7777);
    expect(sent.map((call) => call.arguments), [
      {'autoEnter': true, 'playing': true, 'ratio': 1.78},
      {'autoEnter': false, 'playing': false, 'ratio': 1.78},
    ]);
  });

  test('the attached player hears the window change and its play button; '
      'a replaced one does not', () async {
    final first = _Player(), second = _Player();
    PlayerPip.attach(first);
    await fromAndroid('pipChanged', true);
    await fromAndroid('pipTogglePlay');
    // Switching episodes: the next player attaches before the first closes.
    PlayerPip.attach(second);
    PlayerPip.detach(first);
    await fromAndroid('pipChanged', false);
    expect(first.changes, [true]);
    expect(first.toggles, 1);
    expect(second.changes, [false]);
    expect(second.toggles, 0);
  });

  test('a player opened inside picture in picture can tell', () async {
    PlayerPip.attach(_Player());
    expect(PlayerPip.inPip, isFalse);
    await fromAndroid('pipChanged', true);
    // The next episode's player, started by the countdown in the window.
    PlayerPip.attach(_Player());
    expect(PlayerPip.inPip, isTrue);
    await fromAndroid('pipChanged', false);
    expect(PlayerPip.inPip, isFalse);
  });

  test('closing the player stops leaving the app from opening picture in '
      'picture', () {
    final player = _Player();
    PlayerPip.attach(player);
    PlayerPip.report(autoEnter: true, playing: true, ratio: 2.39);
    PlayerPip.detach(player);
    expect(sent.last.arguments, {
      'autoEnter': false,
      'playing': false,
      'ratio': 2.39,
    });
  });

  test('other platforms send nothing', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    PlayerPip.attach(_Player());
    PlayerPip.report(autoEnter: true, playing: true, ratio: 1.78);
    expect(sent, isEmpty);
  });
}
