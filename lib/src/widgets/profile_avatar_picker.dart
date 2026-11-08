// The avatar choices for the signed-in profile, shared by the account screen
// and the profile page's avatar sheet. Choosing one saves it at once.
import 'package:flutter/material.dart';

import '../account/profile_controller.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import 'profile_avatar.dart';

/// The avatar choices: the Trakt picture, the saved photo, the initial, and
/// each preset. Shown in the account screen and the profile's avatar sheet.
class ProfileAvatarPicker extends StatelessWidget {
  const ProfileAvatarPicker({
    super.key,
    required this.profile,
    required this.name,
    required this.enabled,
    required this.traktUrl,
    this.showHeading = true,
  });

  final ProfileController profile;
  final String name;
  final bool enabled;

  /// The Trakt picture, offered first when the account has one.
  final String? traktUrl;

  /// The "Avatar" heading; off where a dialog already titles it.
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.usesTvLayout && !DeviceCapabilities.isDesktop;
    final size = tv ? 56.0 : 48.0;
    final photo = profile.photo;
    // Without a Trakt picture, the default shows the initial: mark that.
    final shown = profile.avatar.kind == AvatarKind.trakt && traktUrl == null
        ? const ProfileAvatar.initials()
        : profile.avatar;
    Widget choice(ProfileAvatar avatar, String label) => _AvatarChoice(
      label: label,
      selected: shown == avatar,
      enabled: enabled,
      onTap: () => profile.setAvatar(avatar),
      child: ProfileAvatarView(
        avatar: avatar,
        name: name,
        photo: photo == null ? null : FileImage(photo),
        traktUrl: traktUrl,
        size: size,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeading) ...[
            const Text(
              'Avatar',
              style: TextStyle(
                fontSize: AppTextSize.titleSmall,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
          ],
          Wrap(
            spacing: AppSpace.xs,
            runSpacing: AppSpace.xs,
            children: [
              if (traktUrl != null)
                choice(const ProfileAvatar.trakt(), 'Trakt picture'),
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
        ? GlassTheme.textPrimary
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
                        ReelishIcons.check,
                        size: 12,
                        color: Colors.white,
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
