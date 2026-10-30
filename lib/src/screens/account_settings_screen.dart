// The signed-in Trakt account in Settings: the profile (display name and
// avatar, kept on this device), sign out here or everywhere, and delete
// the Reelish account.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/avatar_image.dart';
import '../account/profile_controller.dart';
import '../account/watchlist_sync.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';

enum _Action { signOut, signOutEverywhere, delete, photo }

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({
    super.key,
    required this.account,
    this.onBack,
    this.profile,
    this.pickPhoto,
    this.watchlistSync,
  });

  /// Defaults to [WatchlistSync.instance].
  final WatchlistSync? watchlistSync;

  final AccountController account;
  final VoidCallback? onBack;

  /// Defaults to [ProfileController.instance].
  final ProfileController? profile;

  /// Picks an image and returns its bytes, or null when cancelled.
  /// Defaults to the system photo picker (a file dialog on Windows).
  final Future<Uint8List?> Function()? pickPhoto;

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  /// The action in progress; the other rows wait while it runs.
  _Action? _busy;

  ProfileController get _profile =>
      widget.profile ?? ProfileController.instance;

  WatchlistSync get _sync => widget.watchlistSync ?? WatchlistSync.instance;

  Future<void> _setWatchlistSync(bool value) async {
    if (value) {
      final ok = await _confirm(
        title: 'Sync My list with Trakt?',
        message:
            'Reelish combines My list with your Trakt watchlist, then keeps '
            'them the same: titles added or removed on one appear on the '
            'other, on every device signed in with this Trakt account. '
            'Nothing is deleted when you turn this on.',
        action: 'Turn on',
      );
      if (!ok || !mounted) return;
    }
    await _sync.setEnabled(value);
  }

  String _syncStatus() {
    if (_sync.syncing) return 'Syncing…';
    final error = _sync.error;
    if (error != null) return error;
    final at = _sync.lastSynced;
    if (at == null) return 'Not synced yet';
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return 'Synced just now';
    if (ago.inHours < 1) return 'Synced ${ago.inMinutes} min ago';
    if (ago.inDays < 1) return 'Synced ${ago.inHours} h ago';
    return 'Synced ${ago.inDays} d ago';
  }

  /// TV hardware has no photo picker; it offers the presets.
  bool get _canPickPhoto => !DeviceCapabilities.isTv;

  static Future<Uint8List?> _systemPicker() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Android scales and re-encodes before handing the file over; the
      // result is processed again by AvatarImage either way.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    if (await file.length() > AvatarImage.maxBytes) {
      throw const ProfilePhotoException(
        'That photo is too large. Choose one under 15 MB.',
      );
    }
    return file.readAsBytes();
  }

  Future<void> _choosePhoto() async {
    setState(() => _busy = _Action.photo);
    try {
      final bytes = await (widget.pickPhoto ?? _systemPicker)();
      if (bytes != null) await _profile.setPhoto(bytes);
    } on ProfilePhotoException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('That photo could not be used.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editName() async {
    final current = _profile.displayName ?? '';
    final String? entered;
    if (DeviceCapabilities.isTv) {
      entered = await TvTextEntryDialog.show(
        context,
        title: 'Display name',
        initialValue: current,
        hint: widget.account.username ?? '',
      );
    } else {
      entered = await showDialog<String>(
        context: context,
        builder: (context) => _NameDialog(
          initialValue: current,
          fallback: widget.account.username,
        ),
      );
    }
    if (entered != null) await _profile.setDisplayName(entered);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: GlassTheme.danger,
                      foregroundColor: Colors.white,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _run(_Action action, Future<void> Function() task) async {
    setState(() => _busy = action);
    try {
      await task();
    } on AccountApiException catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not finish'),
          content: Text(
            error.code == 'network'
                ? 'Reelish could not be reached. Check your connection and try again.'
                : 'Something went wrong. Try again later.',
          ),
          actions: [
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      // Signing out replaces this page with the sign-in screen.
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget? _progress(_Action action) => _busy == action
      ? const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : null;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.account, _profile, _sync]),
    builder: (context, _) => SettingsPage(
      title: 'Account',
      subtitle: 'Your profile and Trakt sign-in on this device.',
      icon: Symbols.account_circle_rounded,
      onBack: widget.onBack,
      children: [
        _ProfileCard(profile: _profile, username: widget.account.username),
        SettingsSection(
          label: 'PROFILE',
          description:
              'Your name and avatar stay on this device; they are not '
              'uploaded or shown to anyone else.',
          children: [
            SettingsTile(
              icon: Symbols.badge_rounded,
              title: 'Display name',
              description: _profile.displayName == null
                  ? 'Not set: Reelish shows your Trakt username'
                  : null,
              value: _profile.displayName,
              enabled: _busy == null,
              onTap: _editName,
            ),
            _AvatarPicker(
              profile: _profile,
              name: _profile.nameOr(widget.account.username),
              enabled: _busy == null,
            ),
            if (_canPickPhoto)
              SettingsTile(
                icon: Symbols.add_photo_alternate_rounded,
                title: _profile.photo == null
                    ? 'Choose a photo'
                    : 'Choose another photo',
                description:
                    'Cropped to a square and saved only on this device',
                enabled: _busy == null,
                trailing: _progress(_Action.photo),
                onTap: _choosePhoto,
              ),
            if (_profile.photo != null)
              SettingsTile(
                icon: Symbols.hide_image_rounded,
                title: 'Remove photo',
                description: 'Deletes it from this device',
                enabled: _busy == null,
                showChevron: false,
                onTap: _profile.removePhoto,
              ),
          ],
        ),
        SettingsSection(
          label: 'TRAKT SYNC',
          description:
              'Keep My list the same on every device signed in with this '
              'Trakt account. Watch history sync is coming later.',
          children: [
            SettingsSwitchTile(
              icon: Symbols.bookmarks_rounded,
              title: 'Sync My list with Trakt watchlist',
              description: _sync.enabled
                  ? _syncStatus()
                  : 'Off: My list stays on this device only',
              value: _sync.enabled,
              enabled: _busy == null,
              onChanged: _setWatchlistSync,
            ),
            if (_sync.enabled)
              SettingsTile(
                icon: Symbols.sync_rounded,
                title: 'Sync now',
                description: 'Sync also runs on its own after changes',
                enabled: _busy == null && !_sync.syncing,
                trailing: _sync.syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _sync.sync,
              ),
          ],
        ),
        SettingsSection(
          label: 'SESSIONS',
          description:
              'Signing out keeps My list, history and plugins on this '
              'device.',
          children: [
            SettingsTile(
              icon: Symbols.logout_rounded,
              title: 'Sign out',
              description: 'Sign out of Reelish on this device',
              enabled: _busy == null,
              trailing: _progress(_Action.signOut),
              onTap: () async {
                final ok = await _confirm(
                  title: 'Sign out?',
                  message:
                      'You will need to sign in with Trakt again to browse.',
                  action: 'Sign out',
                );
                if (ok && mounted) {
                  await _run(_Action.signOut, widget.account.signOut);
                }
              },
            ),
            SettingsTile(
              icon: Symbols.devices_rounded,
              title: 'Sign out everywhere',
              description: 'Sign out of Reelish on all your devices',
              enabled: _busy == null,
              trailing: _progress(_Action.signOutEverywhere),
              onTap: () async {
                final ok = await _confirm(
                  title: 'Sign out everywhere?',
                  message:
                      'Every device signed in to Reelish with this Trakt '
                      'account will need to sign in again.',
                  action: 'Sign out everywhere',
                );
                if (ok && mounted) {
                  await _run(
                    _Action.signOutEverywhere,
                    widget.account.signOutEverywhere,
                  );
                }
              },
            ),
          ],
        ),
        SettingsSection(
          label: 'DANGER ZONE',
          children: [
            _DangerTile(
              icon: Symbols.delete_forever_rounded,
              title: 'Delete Reelish account',
              description:
                  'Removes your Reelish account and its access to Trakt. '
                  'Your Trakt account is not affected.',
              enabled: _busy == null,
              trailing: _progress(_Action.delete),
              onTap: () async {
                final ok = await _confirm(
                  title: 'Delete your Reelish account?',
                  message:
                      'Reelish forgets your account, signs out every device '
                      'and gives up its access to your Trakt account. Your '
                      'Trakt account and the data on this device are not '
                      'deleted.',
                  action: 'Delete account',
                  destructive: true,
                );
                if (ok && mounted) {
                  await _run(_Action.delete, widget.account.deleteAccount);
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}

/// Who is signed in: their avatar, display name (or Trakt username), the
/// username beneath a chosen name, and where the sign-in lives.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.username});

  final ProfileController profile;
  final String? username;

  /// Long names wrap at underscores, not mid-word: a zero-width space
  /// follows each.
  static String _wrappable(String text) =>
      text.replaceAll('_', '_${String.fromCharCode(0x200B)}');

  @override
  Widget build(BuildContext context) {
    final name = profile.nameOr(username);
    final photo = profile.photo;
    return Padding(
      padding: const EdgeInsets.only(bottom: SettingsMetrics.sectionGap),
      child: MergeSemantics(
        child: Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SettingsMetrics.sectionRadius),
            border: Border.all(
              color: GlassTheme.primary.withValues(alpha: .22),
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                GlassTheme.primary.withValues(alpha: .16),
                const Color(0xFF14141B),
              ],
              stops: const [0, .7],
            ),
          ),
          child: Row(
            children: [
              ProfileAvatarView(
                avatar: profile.avatar,
                name: name,
                photo: photo == null ? null : FileImage(photo),
                size: 60,
                shadow: true,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Signed in with Trakt',
                      style: TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _wrappable(name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppTextSize.title,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    if (profile.displayName != null && username != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _wrappable('@$username'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.label,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpace.xs),
                    _Pill(
                      icon: Symbols.verified_user_rounded,
                      label: 'Connected on this ${_deviceNoun()}',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _deviceNoun() => switch (AccountController.platformName) {
    'android_tv' => 'TV',
    'windows' => 'PC',
    _ => 'device',
  };
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 3),
    decoration: BoxDecoration(
      color: GlassTheme.primary.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIcon.xs, color: GlassTheme.coralBright),
        const SizedBox(width: AppSpace.xxs),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.coralBright,
              fontSize: AppTextSize.caption,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A [SettingsTile] for an irreversible action, in the danger colour
/// whatever the accent, so it never looks like an ordinary setting.
class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.enabled = true,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: AnimatedOpacity(
      duration: AppMotion.resolve(context, AppMotion.hover),
      opacity: enabled ? 1 : .45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: GlassTheme.danger.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(36 * .32),
                  border: Border.all(
                    color: GlassTheme.danger.withValues(alpha: .22),
                  ),
                ),
                child: Icon(icon, color: GlassTheme.danger, size: 36 * .52),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: GlassTheme.danger,
                        fontSize: AppTextSize.titleSmall,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.label,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  const Icon(
                    Symbols.chevron_right_rounded,
                    color: GlassTheme.muted,
                    size: 22,
                  ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The avatar choices: the saved photo, initials, and each preset.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.profile,
    required this.name,
    required this.enabled,
  });

  final ProfileController profile;
  final String name;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.usesTvLayout && !DeviceCapabilities.isDesktop;
    final size = tv ? 56.0 : 48.0;
    final photo = profile.photo;
    Widget choice(ProfileAvatar avatar, String label) => _AvatarChoice(
      label: label,
      selected: profile.avatar == avatar,
      enabled: enabled,
      onTap: () => profile.setAvatar(avatar),
      child: ProfileAvatarView(
        avatar: avatar,
        name: name,
        photo: photo == null ? null : FileImage(photo),
        size: size,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Avatar',
            style: TextStyle(
              fontSize: AppTextSize.titleSmall,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.xs,
            runSpacing: AppSpace.xs,
            children: [
              if (photo != null)
                choice(const ProfileAvatar.photo(), 'Your photo'),
              choice(const ProfileAvatar.initials(), 'Initial'),
              for (final preset in AvatarPreset.all)
                choice(ProfileAvatar.preset(preset.id), preset.label),
            ],
          ),
        ],
      ),
    );
  }
}

/// One avatar in the picker: an accent ring marks the chosen one, and a
/// white ring the focused one (keyboard, gamepad and D-pad).
class _AvatarChoice extends StatefulWidget {
  const _AvatarChoice({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_AvatarChoice> createState() => _AvatarChoiceState();
}

class _AvatarChoiceState extends State<_AvatarChoice> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ring = _focused
        ? Colors.white
        : widget.selected
        ? GlassTheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.enabled ? widget.onTap : null,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: AnimatedContainer(
            duration: AppMotion.resolve(context, AppMotion.hover),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: 2.5),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                widget.child,
                if (widget.selected)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: GlassTheme.primary,
                        border: Border.all(color: GlassTheme.surface, width: 2),
                      ),
                      child: const Icon(
                        Symbols.check_rounded,
                        size: 12,
                        color: Colors.white,
                        weight: 700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Edits the display name on phone and Windows; TV uses
/// [TvTextEntryDialog]. Returns the text, '' to clear, or null on Cancel.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initialValue, required this.fallback});

  final String initialValue;
  final String? fallback;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Display name'),
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: ProfileController.maxNameLength,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          hintText: widget.fallback,
          helperText: 'Leave empty to use your Trakt username.',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
