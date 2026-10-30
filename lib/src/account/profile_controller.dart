// The user's Reelish profile on this device: a display name and an avatar
// (initials, a preset, or their own photo). Kept per Trakt account, so a
// shared device keeps each person's own; nothing is uploaded.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_controller.dart';
import 'avatar_image.dart';

/// A built-in avatar: an illustration from assets/avatars/ (prepared by
/// tool/branding/generate_avatars.ps1).
class AvatarPreset {
  const AvatarPreset(this.id, this.label, this.asset);

  /// Stored in preferences; never rename one. A stored id that is no
  /// longer listed (the earlier symbol presets) shows the initial instead.
  final String id;
  final String label;
  final String asset;

  static const all = [
    AvatarPreset('avatar1', 'Avatar 1', 'assets/avatars/avatar_1.png'),
    AvatarPreset('avatar2', 'Avatar 2', 'assets/avatars/avatar_2.png'),
    AvatarPreset('avatar3', 'Avatar 3', 'assets/avatars/avatar_3.png'),
    AvatarPreset('avatar4', 'Avatar 4', 'assets/avatars/avatar_4.png'),
    AvatarPreset('avatar5', 'Avatar 5', 'assets/avatars/avatar_5.png'),
    AvatarPreset('avatar6', 'Avatar 6', 'assets/avatars/avatar_6.png'),
    AvatarPreset('avatar7', 'Avatar 7', 'assets/avatars/avatar_7.png'),
    AvatarPreset('avatar8', 'Avatar 8', 'assets/avatars/avatar_8.png'),
  ];

  static AvatarPreset? byId(String? id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

enum AvatarKind { initials, preset, photo }

/// What the avatar shows. [presetId] goes with [AvatarKind.preset].
@immutable
class ProfileAvatar {
  const ProfileAvatar.initials() : kind = AvatarKind.initials, presetId = null;
  const ProfileAvatar.preset(String this.presetId) : kind = AvatarKind.preset;
  const ProfileAvatar.photo() : kind = AvatarKind.photo, presetId = null;

  final AvatarKind kind;
  final String? presetId;

  @override
  bool operator ==(Object other) =>
      other is ProfileAvatar &&
      other.kind == kind &&
      other.presetId == presetId;

  @override
  int get hashCode => Object.hash(kind, presetId);
}

/// Thrown when a photo cannot be used; [message] is shown to the user.
class ProfilePhotoException implements Exception {
  const ProfilePhotoException(this.message);
  final String message;
}

class ProfileController extends ChangeNotifier {
  ProfileController({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  /// The app's profile, following [AccountController.instance] once
  /// [attach]ed at startup.
  static ProfileController instance = ProfileController();

  /// SharedPreferences key: `{userId: {displayName, avatar, preset, photo}}`.
  static const storageKey = 'onfeed.profile.v1';

  /// Display names are shown in a few places; long ones would be cut.
  static const maxNameLength = 30;

  static final _photoName = RegExp(r'^avatar-[0-9a-f]{12}-\d{1,20}\.png$');

  final Future<Directory> Function() _directory;
  AccountController? _account;
  String? _userId;

  String? _displayName;
  ProfileAvatar _avatar = const ProfileAvatar.initials();
  String? _photoFile;
  File? _photo;

  /// The name the user chose, or null to show the Trakt username.
  String? get displayName => _displayName;
  ProfileAvatar get avatar => _avatar;

  /// The saved photo, when the avatar is a photo.
  File? get photo => _avatar.kind == AvatarKind.photo ? _photo : null;

  /// Follows the signed-in account: each Trakt account has its own profile.
  void attach(AccountController account) {
    _account?.removeListener(_accountChanged);
    _account = account..addListener(_accountChanged);
    _accountChanged();
  }

  void _accountChanged() {
    final userId = _account?.userId;
    if (userId != _userId) unawaited(loadFor(userId));
  }

  /// The name to show: the chosen one, else [fallback] (the username).
  String nameOr(String? fallback) => _displayName ?? fallback ?? 'Reelish';

  Future<void> loadFor(String? userId) async {
    _userId = userId;
    _displayName = null;
    _avatar = const ProfileAvatar.initials();
    _photoFile = null;
    _photo = null;
    if (userId != null) {
      // Saved by this app, but read defensively: a bad entry means defaults.
      try {
        final entry = (await _readAll())[userId];
        if (_userId != userId) return;
        if (entry is Map) {
          final name = entry['displayName'];
          _displayName = name is String ? cleanDisplayName(name) : null;
          final photoFile = entry['photo'];
          if (photoFile is String && _photoName.hasMatch(photoFile)) {
            final file = File('${(await _photoDirectory()).path}/$photoFile');
            if (await file.exists()) {
              _photoFile = photoFile;
              _photo = file;
            }
          }
          _avatar = switch (entry['avatar']) {
            'preset' when AvatarPreset.byId('${entry['preset']}') != null =>
              ProfileAvatar.preset('${entry['preset']}'),
            'photo' when _photo != null => const ProfileAvatar.photo(),
            _ => const ProfileAvatar.initials(),
          };
        }
      } catch (_) {
        // Keep the defaults.
      }
    }
    notifyListeners();
  }

  /// Saves [raw] as the display name after [cleanDisplayName]; an empty
  /// name goes back to the Trakt username.
  Future<void> setDisplayName(String raw) async {
    _displayName = cleanDisplayName(raw);
    notifyListeners();
    await _save();
  }

  Future<void> setAvatar(ProfileAvatar avatar) async {
    if (avatar.kind == AvatarKind.photo && _photo == null) return;
    if (avatar.kind == AvatarKind.preset &&
        AvatarPreset.byId(avatar.presetId) == null) {
      return;
    }
    _avatar = avatar;
    notifyListeners();
    await _save();
  }

  /// Makes [bytes] (a picked image, untrusted) the avatar: checked, cut to
  /// a square and re-encoded by [AvatarImage], which also drops the
  /// original's metadata such as its location. The original is not kept.
  Future<void> setPhoto(Uint8List bytes) async {
    final userId = _userId;
    if (userId == null) return;
    final Uint8List png;
    try {
      png = await AvatarImage.square(bytes);
    } on AvatarImageException catch (error) {
      throw ProfilePhotoException(error.message);
    }
    final directory = await _photoDirectory();
    final account = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 12);
    // A new name each time, so no cached image of the old one is shown.
    final name = 'avatar-$account-${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(png, flush: true);
    if (_userId != userId) {
      await _deleteQuietly(file);
      return;
    }
    final previous = _photo;
    _photoFile = name;
    _photo = file;
    _avatar = const ProfileAvatar.photo();
    notifyListeners();
    await _save();
    if (previous != null) await _deleteQuietly(previous);
  }

  /// Deletes the photo; the avatar goes back to initials if it was showing.
  Future<void> removePhoto() async {
    final previous = _photo;
    _photo = null;
    _photoFile = null;
    if (_avatar.kind == AvatarKind.photo) {
      _avatar = const ProfileAvatar.initials();
    }
    notifyListeners();
    await _save();
    if (previous != null) await _deleteQuietly(previous);
  }

  /// Trims, folds whitespace, removes control, zero-width and
  /// direction-override characters (which could disguise a name), and
  /// limits the length. Null when nothing is left.
  static String? cleanDisplayName(String raw) {
    var name = raw
        // Line breaks and tabs become spaces before control characters go.
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(
          RegExp(
            r'[\u0000-\u001F\u007F-\u009F\u00AD\u200B-\u200F'
            r'\u202A-\u202E\u2060-\u2069\uFEFF]',
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.characters.length > maxNameLength) {
      name = name.characters.take(maxNameLength).toString().trim();
    }
    return name.isEmpty ? null : name;
  }

  Future<Directory> _photoDirectory() async {
    final directory = Directory('${(await _directory()).path}/profile');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static Future<Map<String, Object?>> _readAll() async {
    final raw = (await SharedPreferences.getInstance()).getString(storageKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : {};
  }

  Future<void> _save() async {
    final userId = _userId;
    if (userId == null) return;
    Map<String, Object?> all;
    try {
      all = await _readAll();
    } catch (_) {
      all = {};
    }
    all[userId] = {
      if (_displayName != null) 'displayName': _displayName,
      'avatar': _avatar.kind.name,
      if (_avatar.presetId != null) 'preset': _avatar.presetId,
      if (_photoFile != null) 'photo': _photoFile,
    };
    await (await SharedPreferences.getInstance()).setString(
      storageKey,
      jsonEncode(all),
    );
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone, or locked for a moment on Windows; harmless.
    }
  }

  @override
  void dispose() {
    _account?.removeListener(_accountChanged);
    super.dispose();
  }
}
