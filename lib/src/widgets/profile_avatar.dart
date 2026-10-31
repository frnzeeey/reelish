// The user's avatar as chosen in their profile: their photo, a preset, or
// the first letter of their name on the accent.

import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../account/profile_controller.dart';
import '../theme/glass_theme.dart';

/// The signed-in person's avatar, as their profile sets it on this device;
/// redrawn when they change it or another account signs in.
class MyProfileAvatar extends StatelessWidget {
  const MyProfileAvatar({
    super.key,
    this.size = 32,
    this.shadow = false,
    this.profile,
    this.account,
  });

  final double size;
  final bool shadow;
  final ProfileController? profile;
  final AccountController? account;

  @override
  Widget build(BuildContext context) {
    final profile = this.profile ?? ProfileController.instance;
    final account = this.account ?? AccountController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([profile, account]),
      builder: (context, _) {
        final photo = profile.photo;
        return ProfileAvatarView(
          avatar: profile.avatar,
          name: profile.nameOr(account.username),
          photo: photo == null ? null : FileImage(photo),
          size: size,
          shadow: shadow,
        );
      },
    );
  }
}

/// Draws [avatar] at [size]. [name] gives the initial when it has none.
class ProfileAvatarView extends StatelessWidget {
  const ProfileAvatarView({
    super.key,
    required this.avatar,
    required this.name,
    this.photo,
    this.size = 56,
    this.shadow = false,
  });

  final ProfileAvatar avatar;
  final String name;
  final ImageProvider? photo;
  final double size;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final preset = avatar.kind == AvatarKind.preset
        ? AvatarPreset.byId(avatar.presetId)
        : null;
    final usePhoto = avatar.kind == AvatarKind.photo && photo != null;
    final colors = [GlassTheme.coralBright, GlassTheme.primary];
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    final decodeWidth = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    if (preset != null) {
      // Drawn whole, not clipped to a circle: some illustrations' hair
      // breaks out of their round backdrop on purpose.
      return ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: shadow
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .35),
                        blurRadius: size * .22,
                        offset: Offset(0, size * .08),
                      ),
                    ]
                  : null,
            ),
            child: Image.asset(
              preset.asset,
              width: size,
              height: size,
              cacheWidth: decodeWidth,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => _Initial(initial, size),
            ),
          ),
        ),
      );
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: usePhoto
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
          color: usePhoto ? GlassTheme.elevatedSurface : null,
          boxShadow: shadow
              ? [
                  BoxShadow(
                    color: colors.last.withValues(alpha: .3),
                    blurRadius: size * .28,
                    offset: Offset(0, size * .1),
                  ),
                ]
              : null,
        ),
        child: usePhoto
            ? Image(
                image: ResizeImage(photo!, width: decodeWidth),
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // A deleted or unreadable file falls back to the initial.
                errorBuilder: (_, _, _) => _Initial(initial, size),
              )
            : _Initial(initial, size),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.letter, this.size);

  final String letter;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    letter,
    style: TextStyle(
      color: Colors.white,
      fontSize: size * .42,
      fontWeight: FontWeight.w800,
      height: 1,
    ),
  );
}
