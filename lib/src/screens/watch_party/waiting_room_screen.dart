// The party's waiting room: the code to share, the title, who has joined
// and what their players are doing, and the host's controls. Leaving this
// screen leaves the party.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../../widgets/settings/settings_components.dart';
import 'party_launcher.dart';
import 'party_widgets.dart';

class WaitingRoomScreen extends StatefulWidget {
  const WaitingRoomScreen({super.key, required this.party, this.openPlayer});

  final WatchPartyController party;

  /// Opens the player for the room's title; [PartyPlayerLauncher.open] by
  /// default (replaced in tests).
  final Future<void> Function(BuildContext context, PartyContent content)?
  openPlayer;

  @override
  State<WaitingRoomScreen> createState() => _WaitingRoomScreenState();
}

class _WaitingRoomScreenState extends State<WaitingRoomScreen> {
  WatchPartyController get _party => widget.party;

  /// The title the player was last opened for (or the room started with),
  /// so closing the player does not reopen it on its own.
  String? _openedFor;
  bool _inPlayer = false;

  @override
  void initState() {
    super.initState();
    _party.addListener(_followRoom);
  }

  @override
  void dispose() {
    _party.removeListener(_followRoom);
    // Leaving the screen any way at all leaves the party.
    _party.dispose();
    super.dispose();
  }

  static String _keyOf(PartyContent content) =>
      '${content.type}:${content.tmdbId}:${content.season}:${content.episode}';

  /// Everyone's player opens when the host starts (or changes the title).
  void _followRoom() {
    final room = _party.room;
    if (room == null || room.phase != PartyPhase.watching || _inPlayer) return;
    if (_keyOf(room.content) == _openedFor) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPlayer());
  }

  Future<void> _openPlayer() async {
    final room = _party.room;
    final open = widget.openPlayer ?? PartyPlayerLauncher.open;
    if (!mounted || room == null || open == null || _inPlayer) return;
    if (_party.endReason != null) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    setState(() {
      _inPlayer = true;
      _openedFor = _keyOf(room.content);
    });
    _party.reportStatus(ParticipantStatus.loading);
    final sessions = _party.playerSessions;
    try {
      await open(context, room.content);
    } finally {
      if (mounted) {
        // No player opened: this device found no source for the title.
        if (_party.playerSessions == sessions) {
          _party.reportStatus(ParticipantStatus.unavailable);
        }
        final now = _party.room;
        setState(() {
          _inPlayer = false;
          if (now != null) _openedFor = _keyOf(now.content);
        });
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _leave() async {
    final host = _party.isHost;
    final others = (_party.room?.participants.length ?? 1) > 1;
    final confirmed = await _confirm(
      title: 'Leave the party?',
      body: host && others
          ? 'Someone else becomes the host and the party goes on.'
          : 'You can join again with the code while the party is open.',
      action: 'Leave',
    );
    if (!confirmed) return;
    await _party.leave();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _end() async {
    final confirmed = await _confirm(
      title: 'End the party?',
      body: 'Everyone leaves and the code stops working.',
      action: 'End party',
    );
    if (!confirmed) return;
    await _party.endParty();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _party,
    builder: (context, _) {
      final reason = _party.endReason;
      if (reason != null && reason != PartyEndReason.left) {
        return _EndedView(message: partyEndMessage(reason));
      }
      final room = _party.room;
      return PopScope(
        canPop: reason != null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: SettingsScaffold(
          title: 'Watch party',
          subtitle: room == null
              ? 'Connecting…'
              : _party.isHost
              ? 'Share the code. You control playback.'
              : 'Hosted by ${room.hostName}',
          icon: Symbols.groups_rounded,
          footer: null,
          bottomBar: _bottomBar(),
          children: room == null
              ? const [_Connecting()]
              : [
                  if (_party.connection == PartyConnection.reconnecting)
                    const _Banner(
                      icon: Symbols.wifi_off_rounded,
                      text: 'Reconnecting to the party…',
                    )
                  else if (!room.hostConnected)
                    const _Banner(
                      icon: Symbols.hourglass_top_rounded,
                      text:
                          'The host lost their connection. If they don’t '
                          'return in a minute, someone else becomes host.',
                    ),
                  SettingsSection(
                    children: [
                      PartyCodeBlock(
                        code: room.code,
                        title: room.content.title,
                      ),
                    ],
                  ),
                  SettingsSection(
                    label: 'WATCHING',
                    children: [PartyContentCard(content: room.content)],
                  ),
                  SettingsSection(
                    label:
                        'PEOPLE  ${room.participants.length}/${room.settings.capacity}',
                    children: [
                      for (final person in room.participants)
                        _ParticipantTile(
                          person: person,
                          you: person.pid == _party.you,
                          canManage: _party.isHost && person.pid != _party.you,
                          onMakeHost: () => _party.makeHost(person.pid),
                          onRemove: () => _party.remove(person.pid),
                        ),
                    ],
                  ),
                  if (_party.isHost)
                    SettingsSection(
                      label: 'ROOM',
                      children: [
                        SettingsSwitchTile(
                          icon: Symbols.play_pause_rounded,
                          title: 'Everyone can play and pause',
                          value: room.settings.guestControl,
                          onChanged: (value) =>
                              _party.updateSettings(guestControl: value),
                        ),
                        SettingsSwitchTile(
                          icon: Symbols.hourglass_top_rounded,
                          title: 'Wait for everyone',
                          description: 'Start once everyone’s player is ready',
                          value: room.settings.waitForAll,
                          onChanged: (value) =>
                              _party.updateSettings(waitForAll: value),
                        ),
                      ],
                    ),
                ],
        ),
      );
    },
  );

  Widget _bottomBar() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_primaryAction() case final action?) ...[
            SizedBox(
              height: 54,
              width: double.infinity,
              child: FilledButton.icon(
                // The remote starts on the main action.
                autofocus: DeviceCapabilities.isTv,
                style: FilledButton.styleFrom(
                  backgroundColor: GlassTheme.primary,
                  foregroundColor: GlassTheme.background,
                ),
                onPressed: action.onPressed,
                icon: Icon(action.icon, fill: 1),
                label: Text(
                  action.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
          ],
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _leave,
                    icon: const Icon(Symbols.logout_rounded),
                    label: const Text('Leave'),
                  ),
                ),
              ),
              if (_party.isHost) ...[
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: GlassTheme.danger,
                      ),
                      onPressed: _end,
                      icon: const Icon(Symbols.cancel_rounded),
                      label: const Text('End party'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );

  /// The host starts the party; once it is on, anyone back in the room can
  /// return to the player.
  ({String label, IconData icon, VoidCallback? onPressed})? _primaryAction() {
    final room = _party.room;
    if (room == null || _party.connection != PartyConnection.connected) {
      return null;
    }
    if (room.phase == PartyPhase.lobby) {
      if (!_party.isHost) return null;
      return (
        label: 'Start watching',
        icon: Symbols.play_arrow_rounded,
        onPressed: _party.startWatching,
      );
    }
    return (
      label: _inPlayer ? 'Opening the player…' : 'Back to the player',
      icon: Symbols.play_arrow_rounded,
      onPressed: _inPlayer ? null : _openPlayer,
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.person,
    required this.you,
    required this.canManage,
    required this.onMakeHost,
    required this.onRemove,
  });

  final PartyParticipant person;
  final bool you;
  final bool canManage;
  final VoidCallback onMakeHost;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = you ? '${person.name} (you)' : person.name;
    final status = participantStatusLabel(person.status);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      child: Row(
        children: [
          PartyAvatar(name: person.name, avatar: person.avatar),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (person.host) ...[
                        const SizedBox(width: AppSpace.sm),
                        _HostChip(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(
                      color:
                          person.status == ParticipantStatus.unavailable ||
                              person.status == ParticipantStatus.error
                          ? GlassTheme.warning
                          : GlassTheme.muted,
                      fontSize: AppTextSize.caption,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (canManage)
            PopupMenuButton<String>(
              tooltip: 'Options for ${person.name}',
              icon: const Icon(Symbols.more_vert_rounded),
              onSelected: (action) =>
                  action == 'host' ? onMakeHost() : onRemove(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'host', child: Text('Make host')),
                PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from party'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _HostChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: GlassTheme.primary.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      border: Border.all(color: GlassTheme.primary.withValues(alpha: .35)),
    ),
    child: Text(
      'HOST',
      style: TextStyle(
        color: GlassTheme.primary,
        fontSize: AppTextSize.micro,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.lg,
      0,
      AppSpace.lg,
      AppSpace.md,
    ),
    child: Row(
      children: [
        Icon(icon, color: GlassTheme.warning, size: 20),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(text, style: const TextStyle(color: GlassTheme.warning)),
        ),
      ],
    ),
  );
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(child: CircularProgressIndicator(color: GlassTheme.primary)),
  );
}

class _EndedView extends StatelessWidget {
  const _EndedView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Symbols.groups_rounded,
                size: 48,
                color: GlassTheme.muted,
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: AppTextSize.title,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
