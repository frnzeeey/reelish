// Friends & privacy: turning Friends on or off, the handle and friend code,
// what friends see and who can find the account. One settings page for phone,
// TV and Windows (opened from Profile, like Manage account); text entry uses
// the remote-friendly dialog on TV. The server enforces every setting here.
// docs/friends-activity/.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../account/profile_controller.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../social/social_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/tv/tv_focus.dart';

class FriendsPrivacyScreen extends StatefulWidget {
  const FriendsPrivacyScreen({
    super.key,
    this.controller,
    this.friends,
    this.recommendations,
    this.onBack,
  });

  /// [SocialController.instance] when null.
  final SocialController? controller;

  /// [FriendsController.instance] when null; its saved list is forgotten
  /// when Friends is turned off.
  final FriendsController? friends;

  /// [RecommendationsController.instance] when null; its saved inbox is
  /// forgotten when Friends is turned off.
  final RecommendationsController? recommendations;
  final VoidCallback? onBack;

  @override
  State<FriendsPrivacyScreen> createState() => _FriendsPrivacyScreenState();
}

class _FriendsPrivacyScreenState extends State<FriendsPrivacyScreen> {
  late final SocialController _social =
      widget.controller ?? SocialController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_social.refresh());
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Asks for text until the server accepts it or the person cancels.
  /// [save] returns an error to show, or null when it was accepted.
  Future<void> _askText({
    required String title,
    required String initial,
    required String hint,
    required String helper,
    required int maxLength,
    required Future<String?> Function(String text) save,
    String? Function(String text)? check,
    String? prefix,
  }) async {
    if (DeviceCapabilities.isTv) {
      var value = initial;
      for (;;) {
        if (!mounted) return;
        final entered = await TvTextEntryDialog.show(
          context,
          title: title,
          initialValue: value,
          hint: hint,
        );
        if (entered == null || !mounted) return;
        value = entered;
        final error = check?.call(entered) ?? await save(entered);
        if (error == null) return;
        _show(error);
      }
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _TextDialog(
        title: title,
        initial: initial,
        hint: hint,
        helper: helper,
        maxLength: maxLength,
        prefix: prefix,
        check: check,
        save: save,
      ),
    );
  }

  static String? _checkHandle(String text) => handlePattern.hasMatch(text)
      ? null
      : '3 to 20 letters, digits or underscores, starting with a letter.';

  Future<void> _turnOn() => _askText(
    title: 'Choose a handle',
    initial: '',
    hint: 'e.g. movie_night',
    helper: 'Friends find you by it. It is not your Trakt username.',
    maxLength: maxHandleLength,
    prefix: '@',
    check: _checkHandle,
    save: _social.enable,
  );

  Future<void> _changeHandle(SocialProfile profile) {
    final at = profile.handleChangeableAt;
    if (at != null && at.isAfter(DateTime.now().toUtc())) {
      _show('You can change your handle again on ${_date(at)}.');
      return Future.value();
    }
    return _askText(
      title: 'Handle',
      initial: profile.handle,
      hint: profile.handle,
      helper: 'You can change it once a week.',
      maxLength: maxHandleLength,
      prefix: '@',
      check: _checkHandle,
      save: (text) =>
          text == profile.handle ? Future.value() : _social.setHandle(text),
    );
  }

  Future<void> _changeName(SocialProfile profile) => _askText(
    title: 'Name friends see',
    initial: profile.displayName ?? '',
    hint: 'Leave empty to show only your handle',
    helper: 'Leave empty to show only your handle.',
    maxLength: maxSocialNameLength,
    save: _social.setDisplayName,
  );

  Future<void> _chooseAvatar(SocialProfile profile) async {
    final chosen = await showDialog<(String?,)>(
      context: context,
      builder: (context) => _AvatarDialog(selected: profile.avatar),
    );
    if (chosen == null || chosen.$1 == profile.avatar) return;
    final error = await _social.setAvatar(chosen.$1);
    if (error != null) _show(error);
  }

  Future<void> _set(SocialSetting setting, bool value) async {
    final error = await _social.setSetting(setting, value);
    if (error != null) _show(error);
  }

  Future<void> _copyCode(SocialProfile profile) async {
    await Clipboard.setData(ClipboardData(text: profile.formattedCode));
    _show('Friend code copied');
  }

  Future<void> _newCode() async {
    final confirmed = await _confirm(
      title: 'Get a new friend code?',
      message:
          'Your current code stops working. Friends you already have stay '
          'your friends.',
      action: 'New code',
    );
    if (!confirmed) return;
    final error = await _social.resetCode();
    _show(error ?? 'You have a new friend code');
  }

  Future<void> _turnOff() async {
    final confirmed = await _confirm(
      title: 'Turn off Friends?',
      message:
          'This deletes your handle, your friends, friend requests, the '
          'people you blocked and recommendations you received. Shared '
          'collections become private. Your library is not affected. Your '
          'handle is kept for you for 30 days.',
      action: 'Turn off',
      destructive: true,
    );
    if (!confirmed) return;
    final error = await _social.disable();
    if (error == null) {
      await (widget.friends ?? FriendsController.instance).forget();
      await (widget.recommendations ?? RecommendationsController.instance)
          .forget();
    }
    _show(error ?? 'Friends is off');
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
              // The safe choice is focused, so Select on a remote never
              // confirms by accident.
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

  static String _date(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = at.toLocal();
    return '${months[local.month - 1]} ${local.day}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _social,
    builder: (context, _) {
      final profile = _social.profile;
      return SettingsPage(
        title: 'Friends & privacy',
        subtitle: 'Who can find you and what friends see.',
        icon: ReelishIcons.people,
        onBack: widget.onBack,
        footer: null,
        children: [
          if (profile != null)
            ..._on(profile)
          else if (_social.known)
            ..._off()
          else if (_social.failed)
            _Unavailable(onRetry: () => unawaited(_social.refresh()))
          else
            const _Loading(),
        ],
      );
    },
  );

  List<Widget> _off() => [
    SettingsSection(
      label: 'FRIENDS',
      description:
          'Add friends with a code, send them titles to watch and share the '
          'collections you choose. Nothing is shared until you turn it on, '
          'and friends never see your Trakt username.',
      children: [
        SettingsTile(
          icon: ReelishIcons.personAdd,
          title: 'Turn on Friends',
          description: 'Choose a handle that friends will see',
          enabled: !_social.busy,
          onTap: () => unawaited(_turnOn()),
        ),
      ],
    ),
  ];

  List<Widget> _on(SocialProfile profile) {
    final busy = _social.busy;
    final avatar = AvatarPreset.byId(profile.avatar);
    return [
      SettingsSection(
        label: 'WHAT FRIENDS SEE',
        description:
            'Your handle always; a name and avatar only if you choose them '
            'here. Your Trakt username and photo are never shown.',
        children: [
          SettingsTile(
            icon: ReelishIcons.tag,
            title: 'Handle',
            value: '@${profile.handle}',
            enabled: !busy,
            onTap: () => unawaited(_changeHandle(profile)),
          ),
          SettingsTile(
            icon: ReelishIcons.badge,
            title: 'Name',
            value: profile.displayName ?? 'Not shared',
            enabled: !busy,
            onTap: () => unawaited(_changeName(profile)),
          ),
          SettingsTile(
            icon: ReelishIcons.face,
            title: 'Avatar',
            value: avatar?.label ?? 'Not shared',
            trailing: avatar == null ? null : _PresetImage(avatar, size: 32),
            enabled: !busy,
            onTap: () => unawaited(_chooseAvatar(profile)),
          ),
        ],
      ),
      SettingsSection(
        label: 'FRIEND CODE',
        description:
            'Give it to someone so they can add you. A new code stops the '
            'old one from working.',
        children: [
          SettingsTile(
            icon: ReelishIcons.hash,
            title: profile.formattedCode,
            description: DeviceCapabilities.isTv ? null : 'Copy',
            // A remote has no clipboard to copy to.
            onTap: DeviceCapabilities.isTv
                ? null
                : () => unawaited(_copyCode(profile)),
            trailing: DeviceCapabilities.isTv
                ? null
                : Icon(ReelishIcons.copy, color: GlassTheme.muted, size: 20),
          ),
          SettingsTile(
            icon: ReelishIcons.refresh,
            title: 'Get a new code',
            enabled: !busy,
            onTap: () => unawaited(_newCode()),
          ),
        ],
      ),
      SettingsSection(
        label: 'PRIVACY',
        children: [
          SettingsSwitchTile(
            icon: ReelishIcons.hash,
            title: 'Found by friend code',
            description: 'People with your code can send you a request',
            value: profile.findByCode,
            enabled: !busy,
            onChanged: (value) =>
                unawaited(_set(SocialSetting.findByCode, value)),
          ),
          SettingsSwitchTile(
            icon: ReelishIcons.search,
            title: 'Found by handle',
            description:
                'People who type your exact handle can send you a request',
            value: profile.findByHandle,
            enabled: !busy,
            onChanged: (value) =>
                unawaited(_set(SocialSetting.findByHandle, value)),
          ),
          SettingsSwitchTile(
            icon: ReelishIcons.send,
            title: 'Recommendations from friends',
            description: 'Friends can send you titles to watch',
            value: profile.allowRecommendations,
            enabled: !busy,
            onChanged: (value) =>
                unawaited(_set(SocialSetting.allowRecommendations, value)),
          ),
          SettingsSwitchTile(
            icon: ReelishIcons.playCircle,
            title: "Share what I'm watching",
            description:
                'Friends see the title you are playing while you watch it. '
                'Not during a Watch Party; gone when you stop.',
            value: profile.shareActivity,
            enabled: !busy,
            onChanged: (value) =>
                unawaited(_set(SocialSetting.shareActivity, value)),
          ),
        ],
      ),
      SettingsSection(
        children: [
          SettingsTile(
            icon: ReelishIcons.power,
            title: 'Turn off Friends',
            description:
                'Deletes your handle, friends and requests from Reelish',
            enabled: !busy,
            onTap: () => unawaited(_turnOff()),
          ),
        ],
      ),
    ];
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpace.xl),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SettingsSection(
    description:
        'Friends could not be loaded. Check your connection and try again.',
    children: [
      SettingsTile(
        icon: ReelishIcons.refresh,
        title: 'Try again',
        onTap: onRetry,
      ),
    ],
  );
}

class _PresetImage extends StatelessWidget {
  const _PresetImage(this.preset, {required this.size});

  final AvatarPreset preset;
  final double size;

  @override
  Widget build(BuildContext context) => ClipOval(
    child: Image.asset(
      preset.asset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
    ),
  );
}

/// The avatar friends see: a preset or none. Returns the choice in a record,
/// so "none" differs from dismissing the dialog.
class _AvatarDialog extends StatelessWidget {
  const _AvatarDialog({required this.selected});

  final String? selected;

  @override
  Widget build(BuildContext context) {
    Widget option({
      required String? id,
      required String label,
      required Widget child,
    }) {
      final chosen = id == selected;
      return Semantics(
        label: label,
        selected: chosen,
        button: true,
        child: InkWell(
          autofocus: chosen,
          customBorder: const CircleBorder(),
          onTap: () => Navigator.pop(context, (id,)),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: chosen ? GlassTheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    return AlertDialog(
      title: const Text('Avatar friends see'),
      content: SizedBox(
        width: 360,
        child: Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            option(
              id: null,
              label: 'Not shared',
              child: CircleAvatar(
                radius: 28,
                backgroundColor: GlassTheme.elevatedSurface,
                child: Icon(ReelishIcons.blocked, color: GlassTheme.muted),
              ),
            ),
            for (final preset in AvatarPreset.all)
              option(
                id: preset.id,
                label: preset.label,
                child: _PresetImage(preset, size: 56),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Text entry for phone and Windows: [check] runs first, then [save]; an
/// error from either shows under the field and the dialog stays open.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.helper,
    required this.maxLength,
    required this.save,
    this.check,
    this.prefix,
  });

  final String title;
  final String initial;
  final String hint;
  final String helper;
  final int maxLength;
  final String? prefix;
  final String? Function(String text)? check;
  final Future<String?> Function(String text) save;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final text = _controller.text.trim();
    final invalid = widget.check?.call(text);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.save(text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_saving,
        maxLength: widget.maxLength,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_submit()),
        decoration: InputDecoration(
          prefixText: widget.prefix,
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 2,
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : () => unawaited(_submit()),
        child: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Save'),
      ),
    ],
  );
}
