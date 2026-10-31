// Starts a watch party for a movie or episode: the room's settings, then
// the waiting room with the code to share.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../navigation/app_transitions.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../../widgets/settings/settings_components.dart';
import 'party_desktop.dart';
import 'party_widgets.dart';
import 'waiting_room_screen.dart';

class CreatePartyScreen extends StatefulWidget {
  const CreatePartyScreen({
    super.key,
    required this.content,
    this.create = createWatchParty,
    this.open,
  });

  final PartyContent content;

  /// Creates the room and returns its code (replaced in tests).
  final Future<String> Function({
    required PartyContent content,
    PartySettings settings,
  })
  create;

  /// Opens the waiting room for a code; by default a connected controller.
  final void Function(BuildContext context, String code)? open;

  @override
  State<CreatePartyScreen> createState() => _CreatePartyScreenState();
}

class _CreatePartyScreenState extends State<CreatePartyScreen> {
  static const _maxCapacity = 5;
  int _capacity = _maxCapacity;
  bool _guestControl = false;
  bool _waitForAll = true;
  bool _creating = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final code = await widget.create(
        content: widget.content,
        settings: PartySettings(
          capacity: _capacity,
          guestControl: _guestControl,
          waitForAll: _waitForAll,
        ),
      );
      if (!mounted) return;
      final open = widget.open;
      if (open != null) {
        open(context, code);
        return;
      }
      final party = WatchPartyController(code: code);
      await party.start();
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        AppPageRoute<void>(
          context: context,
          builder: (_) => WaitingRoomScreen(party: party),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = partyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Who can join and control playback; the same on every interface.
  Widget _roomSection({String? description}) => SettingsSection(
    label: 'ROOM',
    description: description,
    children: [
      SettingsTile(
        icon: Symbols.group_rounded,
        title: 'Up to $_capacity people',
        description: 'Including you',
        mergeSemantics: false,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Fewer people',
              onPressed: _capacity > 2
                  ? () => setState(() => _capacity--)
                  : null,
              icon: const Icon(Symbols.remove_rounded),
            ),
            IconButton(
              tooltip: 'More people',
              onPressed: _capacity < _maxCapacity
                  ? () => setState(() => _capacity++)
                  : null,
              icon: const Icon(Symbols.add_rounded),
            ),
          ],
        ),
      ),
      SettingsSwitchTile(
        icon: Symbols.play_pause_rounded,
        title: 'Everyone can play and pause',
        description: _guestControl
            ? 'Anyone in the party controls playback'
            : 'Only you control playback',
        value: _guestControl,
        onChanged: (value) => setState(() => _guestControl = value),
      ),
      SettingsSwitchTile(
        icon: Symbols.hourglass_top_rounded,
        title: 'Wait for everyone',
        description: 'Start once everyone’s player is ready',
        value: _waitForAll,
        onChanged: (value) => setState(() => _waitForAll = value),
      ),
    ],
  );

  /// Windows: the poster beside the title and the room's settings, with
  /// the action under them instead of a bar across the window.
  Widget _desktop(BuildContext context) {
    final content = widget.content;
    return PartyDesktopFrame(
      title: 'Watch together',
      subtitle: 'Start a party, share the code, and watch in sync.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below this the poster shrinks rather than squeezing the form.
          final posterWidth = constraints.maxWidth >= 900 ? 280.0 : 200.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PartyDesktopPoster(content: content, width: posterWidth),
              const SizedBox(width: AppSpace.xxl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      content.isSeries ? 'SERIES' : 'MOVIE',
                      style: TextStyle(
                        color: GlassTheme.primary,
                        fontSize: AppTextSize.caption,
                        letterSpacing: 1.6,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      content.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppTextSize.display,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                        letterSpacing: -.6,
                      ),
                    ),
                    if (content.isSeries) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        'Season ${content.season} · Episode ${content.episode}',
                        style: const TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.bodyLarge,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),
                    const PartyHowItWorks(),
                    const SizedBox(height: AppSpace.lg),
                    // The settings section without its page margins.
                    MediaQuery.removePadding(
                      context: context,
                      removeLeft: true,
                      removeRight: true,
                      child: _roomSection(),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Row(
                      children: [
                        Expanded(
                          child: _error == null
                              ? const Text(
                                  'Each person needs a source for this title '
                                  'in their own plugins.',
                                  style: TextStyle(
                                    color: GlassTheme.muted,
                                    fontSize: AppTextSize.bodySmall,
                                  ),
                                )
                              : Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: GlassTheme.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                        const SizedBox(width: AppSpace.md),
                        PartyDesktopButton(
                          label: _creating ? 'Creating party…' : 'Create party',
                          icon: Symbols.celebration_rounded,
                          busy: _creating,
                          onPressed: _creating ? null : _submit,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DeviceCapabilities.isDesktop) return _desktop(context);
    return _phoneAndTv(context);
  }

  Widget _phoneAndTv(BuildContext context) => SettingsScaffold(
    title: 'Watch together',
    subtitle: 'Start a party, share the code, and watch in sync.',
    icon: Symbols.groups_rounded,
    footer: null,
    bottomBar: SafeArea(
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
            // Beside the button that failed, where it is seen.
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: GlassTheme.danger),
                ),
              ),
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
                onPressed: _creating ? null : _submit,
                icon: _creating
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Symbols.celebration_rounded),
                label: Text(
                  _creating ? 'Creating party…' : 'Create party',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    children: [
      SettingsSection(
        label: 'WATCHING',
        children: [PartyContentCard(content: widget.content)],
      ),
      _roomSection(
        description:
            'Everyone plays the title from their own sources, so each '
            'person needs a source for it.',
      ),
    ],
  );
}
