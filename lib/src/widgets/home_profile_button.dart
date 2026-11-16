// The profile button at the top right of the phone's Home: the account's own
// avatar (photo, preset, Trakt picture or initial) in one ring, the accent's,
// or a supporter's equipped frame colour (the rim AvatarFrameRim would draw)
// instead, never both. 44 px, as tall as the glass capsule beside it, in a
// 48 px touch area.
import 'package:flutter/material.dart';

import '../account/avatar_frames.dart';
import '../theme/avatar_frames.dart';
import '../theme/glass_theme.dart';
import 'profile_avatar.dart';

class HomeProfileButton extends StatelessWidget {
  const HomeProfileButton({super.key, required this.onOpen, this.frames});

  final VoidCallback onOpen;

  /// Whose frame colours the ring; [AvatarFrames.instance] when null.
  final AvatarFrames? frames;

  @override
  Widget build(BuildContext context) {
    final frames = this.frames ?? AvatarFrames.instance;
    return IconButton(
      tooltip: 'Profile',
      onPressed: onOpen,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(48),
        minimumSize: const Size.square(48),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const CircleBorder(),
      ),
      icon: ListenableBuilder(
        listenable: frames,
        builder: (context, avatar) {
          final frame = AvatarFrameStyle.byId(frames.equipped);
          return Container(
            key: const ValueKey('home-profile-ring'),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: frame == null
                    ? [GlassTheme.coralBright, GlassTheme.primary]
                    : [frame.rim, frame.rim],
              ),
            ),
            // A thin gap of page between the ring and the avatar.
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GlassTheme.background,
              ),
              child: avatar,
            ),
          );
        },
        child: const MyProfileAvatar(size: 36),
      ),
    );
  }
}
