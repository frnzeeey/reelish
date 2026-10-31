// The watch party's badge over the player: the room code, who is watching
// (the host marked), and whether this player is in sync. It never takes
// taps; waiting and catching up show always, "in sync" with the controls.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../account/profile_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/party_player_sync.dart';
import '../profile_avatar.dart';

class PartyBadge extends StatelessWidget {
  const PartyBadge({
    super.key,
    required this.sync,
    required this.controlsVisible,
  });

  final PartyPlayerSync sync;
  final ValueListenable<bool> controlsVisible;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([sync, sync.party, controlsVisible]),
    builder: (context, _) {
      final room = sync.room;
      final calm = sync.state == PartySyncState.inSync;
      final visible = room != null && (!calm || controlsVisible.value);
      final people = room?.participants ?? const <PartyParticipant>[];
      return IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.resolve(context, AppMotion.standard),
          child: room == null
              ? const SizedBox.shrink()
              : Semantics(
                  liveRegion: true,
                  label:
                      'Watch party ${formatPartyCode(room.code)}. '
                      '${partySyncLabel(sync)}',
                  excludeSemantics: true,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .62),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                        color: calm
                            ? Colors.white.withValues(alpha: .14)
                            : GlassTheme.primary.withValues(alpha: .6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Faces(people: people),
                        const SizedBox(width: AppSpace.xs),
                        Icon(
                          Symbols.groups_rounded,
                          size: 16,
                          color: GlassTheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${formatPartyCode(room.code)} · ${partySyncLabel(sync)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTextSize.label,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      );
    },
  );
}

/// Up to four faces, overlapping, the host's ringed in the accent.
class _Faces extends StatelessWidget {
  const _Faces({required this.people});

  final List<PartyParticipant> people;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(4).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    const size = 22.0;
    return SizedBox(
      width: size + (shown.length - 1) * 14,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 14.0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: shown[i].host ? GlassTheme.primary : Colors.black,
                    width: 1.5,
                  ),
                ),
                child: ProfileAvatarView(
                  avatar: AvatarPreset.byId(shown[i].avatar) == null
                      ? const ProfileAvatar.initials()
                      : ProfileAvatar.preset(shown[i].avatar!),
                  name: shown[i].name,
                  size: size - 3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
