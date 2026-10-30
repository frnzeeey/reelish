import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/avatar_image.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/account_settings_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session(String userId, String username) => StoredSession(
  sessionId: 's-$userId',
  accessToken: 'a',
  accessExpiresAt: _now() + 900,
  refreshToken: 'r',
  refreshExpiresAt: _now() + 86400,
  userId: userId,
  username: username,
);

/// A real PNG of [width] × [height], left half red, right half blue.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    ui.Paint()..color = const Color(0xFFFF0000),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
    ui.Paint()..color = const Color(0xFF0000FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A tiny file whose valid PNG header claims [width] × [height].
Uint8List _pngClaiming(int width, int height) {
  final ihdr = BytesBuilder()
    ..add(ascii.encode('IHDR'))
    ..add(
      (ByteData(8)
            ..setUint32(0, width)
            ..setUint32(4, height))
          .buffer
          .asUint8List(),
    )
    ..add([8, 6, 0, 0, 0]);
  final chunk = ihdr.toBytes();
  return (BytesBuilder()
        ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add((ByteData(4)..setUint32(0, 13)).buffer.asUint8List())
        ..add(chunk)
        ..add((ByteData(4)..setUint32(0, _crc32(chunk))).buffer.asUint8List()))
      .toBytes();
}

void main() {
  late Directory directory;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('reelish-profile-');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a shown photo open; the OS cleans temp.
    }
  });

  ProfileController controller() =>
      ProfileController(directory: () async => directory);

  group('Display names', () {
    test('are trimmed, folded, limited and stripped of hidden characters', () {
      expect(
        ProfileController.cleanDisplayName('  Franze   Lobos '),
        'Franze Lobos',
      );
      expect(ProfileController.cleanDisplayName('   '), isNull);
      expect(ProfileController.cleanDisplayName(''), isNull);
      // Direction overrides could make a name read differently.
      expect(
        ProfileController.cleanDisplayName(
          'Admin${String.fromCharCode(0x202E)}nimda',
        ),
        'Adminnimda',
      );
      expect(
        ProfileController.cleanDisplayName(
          'A${String.fromCharCode(0x200B)}B${String.fromCharCode(0x0007)}C',
        ),
        'ABC',
      );
      expect(ProfileController.cleanDisplayName('Line\nbreak'), 'Line break');
      final long = ProfileController.cleanDisplayName('x' * 80)!;
      expect(long.length, ProfileController.maxNameLength);
      // Counted in characters, so an emoji is never cut in half.
      final emoji = ProfileController.cleanDisplayName('🎬' * 40)!;
      expect(emoji.characters.length, ProfileController.maxNameLength);
      expect(emoji.characters.every((c) => c == '🎬'), true);
    });
  });

  group('AvatarImage', () {
    testWidgets('crops the centre to a 256 px square PNG', (tester) async {
      final out = await tester.runAsync(() async {
        final png = await AvatarImage.square(await _png(600, 300));
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final pixels = (await image.toByteData())!;
        final result = (
          width: image.width,
          height: image.height,
          isPng: png[1] == 0x50 && png[2] == 0x4E && png[3] == 0x47,
          // RGBA at the left and right edges of the middle row.
          left: pixels.getUint32((128 * 256 + 4) * 4),
          right: pixels.getUint32((128 * 256 + 250) * 4),
        );
        image.dispose();
        return result;
      });
      expect(out!.width, 256);
      expect(out.height, 256);
      expect(out.isPng, true);
      // The 300 px centred square of a 600 × 300 image spans both halves.
      expect(out.left, 0xFF0000FF);
      expect(out.right, 0x0000FFFF);
    });

    testWidgets('refuses files that are not images, empty or too large', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await expectLater(
          AvatarImage.square(Uint8List.fromList(utf8.encode('<svg>no</svg>'))),
          throwsA(isA<AvatarImageException>()),
        );
        await expectLater(
          AvatarImage.square(Uint8List(0)),
          throwsA(isA<AvatarImageException>()),
        );
        await expectLater(
          AvatarImage.square(Uint8List(AvatarImage.maxBytes + 1)),
          throwsA(isA<AvatarImageException>()),
        );
      });
    });

    testWidgets('refuses images over the size limits, before decoding', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final wide = await _png(600, 300);
        final tooBig = throwsA(
          isA<AvatarImageException>().having(
            (e) => e.message,
            'message',
            contains('too big'),
          ),
        );
        await expectLater(AvatarImage.square(wide, maxSide: 500), tooBig);
        await expectLater(
          AvatarImage.square(wide, maxPixels: 600 * 300 - 1),
          tooBig,
        );
        // A tiny file claiming a 40000 px image never reaches the decoder.
        await expectLater(
          AvatarImage.square(_pngClaiming(40000, 40000)),
          throwsA(isA<AvatarImageException>()),
        );
      });
    });
  });

  group('ProfileController', () {
    test('keeps each Trakt account’s profile apart and remembers it', () async {
      final profile = controller();
      await profile.loadFor('user-a');
      await profile.setDisplayName('Alice');
      await profile.setAvatar(const ProfileAvatar.preset('avatar3'));

      await profile.loadFor('user-b');
      expect(profile.displayName, isNull);
      expect(profile.avatar, const ProfileAvatar.initials());
      expect(profile.nameOr('bob_trakt'), 'bob_trakt');

      final reloaded = controller();
      await reloaded.loadFor('user-a');
      expect(reloaded.displayName, 'Alice');
      expect(reloaded.avatar, const ProfileAvatar.preset('avatar3'));
    });

    test('ignores unknown presets and tampered photo paths', () async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: jsonEncode({
          'u1': {'avatar': 'preset', 'preset': 'no-such-preset'},
          // An earlier symbol preset, no longer offered.
          'u5': {'avatar': 'preset', 'preset': 'rocket'},
          'u2': {'avatar': 'photo', 'photo': '../../secrets.png'},
          'u3': 'not a map',
          'u4': {'displayName': 42, 'avatar': 7},
        }),
      });
      File('${directory.path}/secrets.png').writeAsBytesSync([1, 2, 3]);
      final profile = controller();
      for (final user in ['u1', 'u2', 'u3', 'u4', 'u5']) {
        await profile.loadFor(user);
        expect(profile.avatar, const ProfileAvatar.initials(), reason: user);
        expect(profile.photo, isNull, reason: user);
        expect(profile.displayName, isNull, reason: user);
      }
      // Unreadable JSON falls back to defaults too.
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: '{broken',
      });
      await profile.loadFor('u1');
      expect(profile.avatar, const ProfileAvatar.initials());
    });

    testWidgets('a photo is saved re-encoded, replaced, and deleted', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final profile = controller();
        await profile.loadFor('user-a');
        await profile.setPhoto(await _png(800, 800));
        final first = profile.photo!;
        expect(profile.avatar, const ProfileAvatar.photo());
        // Inside the app's own folder, under profile/.
        expect(
          first.parent.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
          'profile',
        );
        expect(first.parent.parent.path, directory.path);
        final saved = first.readAsBytesSync();
        expect(saved.sublist(1, 4), ascii.encode('PNG'));

        await profile.setPhoto(await _png(400, 900));
        final second = profile.photo!;
        expect(second.path, isNot(first.path));
        expect(first.existsSync(), false, reason: 'the old photo is deleted');

        // Survives a restart.
        final reloaded = controller();
        await reloaded.loadFor('user-a');
        expect(reloaded.photo?.path, second.path);

        await profile.removePhoto();
        expect(second.existsSync(), false);
        expect(profile.avatar, const ProfileAvatar.initials());
      });
    });

    testWidgets('a bad photo leaves the profile as it was', (tester) async {
      await tester.runAsync(() async {
        final profile = controller();
        await profile.loadFor('user-a');
        await profile.setAvatar(const ProfileAvatar.preset('avatar5'));
        await expectLater(
          profile.setPhoto(Uint8List.fromList([1, 2, 3, 4])),
          throwsA(isA<ProfilePhotoException>()),
        );
        expect(profile.avatar, const ProfileAvatar.preset('avatar5'));
        expect(profile.photo, isNull);
      });
    });
  });

  group('Account page profile', () {
    Future<(AccountController, ProfileController)> setUpAccount() async {
      final account = AccountController(
        store: MemorySessionStore(_session('user-a', 'trakt_user')),
      );
      await account.restore();
      final profile = controller()..attach(account);
      await profile.loadFor('user-a');
      return (account, profile);
    }

    Widget page(
      AccountController account,
      ProfileController profile, {
      Future<Uint8List?> Function()? pickPhoto,
    }) => MaterialApp(
      theme: GlassTheme.dark,
      home: Scaffold(
        body: AccountSettingsScreen(
          account: account,
          profile: profile,
          pickPhoto: pickPhoto,
          onBack: () {},
        ),
      ),
    );

    testWidgets('sets a display name and a preset avatar', (tester) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (account, profile) = await setUpAccount();
      await tester.pumpWidget(page(account, profile));
      await tester.pump();

      expect(
        find.text(
          'trakt_user'.replaceAll('_', '_${String.fromCharCode(0x200B)}'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Display name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Movie   Night  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(profile.displayName, 'Movie Night');
      expect(find.text('Movie Night'), findsWidgets);

      await tester.tap(find.bySemanticsLabel('Avatar 3'));
      await tester.pumpAndSettle();
      expect(profile.avatar, const ProfileAvatar.preset('avatar3'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('chooses a photo through the picker, and reports bad files', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (account, profile) = await setUpAccount();
      final good = (await tester.runAsync(() => _png(500, 500)))!;
      var next = good;
      await tester.pumpWidget(
        page(account, profile, pickPhoto: () async => next),
      );
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('Choose a photo'));
        for (var i = 0; i < 50 && profile.photo == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(profile.avatar, const ProfileAvatar.photo());
      expect(find.text('Remove photo'), findsOneWidget);

      next = Uint8List.fromList(utf8.encode('not an image'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose another photo'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not a photo Reelish can read'),
        findsOneWidget,
      );
      expect(profile.avatar, const ProfileAvatar.photo());

      await tester.runAsync(() async {
        await tester.tap(find.text('Remove photo'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(profile.photo, isNull);
      expect(find.text('Choose a photo'), findsOneWidget);
    });

    testWidgets('TV offers the presets but no photo picker', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final (account, profile) = await setUpAccount();
      await tester.pumpWidget(page(account, profile));
      await tester.pump();
      expect(find.text('Choose a photo'), findsNothing);
      expect(find.bySemanticsLabel('Avatar 3'), findsOneWidget);
    });
  });
}
