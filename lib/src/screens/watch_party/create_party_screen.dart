// Starts a watch party for a movie or episode: the room's settings, then
// the waiting room with the code to share. Hosting is for Reelish Supporters,
// so anyone else sees what hosting offers and how to support instead; joining
// a party stays open to everyone.

import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/reelish_icons.dart';

import '../../account/account_api.dart';
import '../../account/supporter_controller.dart';
import '../../navigation/app_transitions.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../../widgets/account_badges.dart';
import '../../widgets/settings/settings_components.dart';
import '../supporters_screen.dart';
import 'join_party_screen.dart';
import 'party_desktop.dart';
import 'party_widgets.dart';
import 'waiting_room_screen.dart';
import '../../widgets/glass_button.dart';

class CreatePartyScreen extends StatefulWidget {
  const CreatePartyScreen({
    super.key,
    required this.content,
    this.create = createWatchParty,
    this.open,
    this.supporters,
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

  /// Whether this account may host; [SupporterController.instance] when null.
  /// Only chooses what to show: the server decides when the room is created.
  final SupporterController? supporters;

  @override
  State<CreatePartyScreen> createState() => _CreatePartyScreenState();
}

/// What the screen offers: the room's settings, or how to become able to host.
enum _Hosting { checking, allowed, supportersOnly }

class _CreatePartyScreenState extends State<CreatePartyScreen> {
  static const _maxCapacity = 5;
  late final SupporterController _supporters =
      widget.supporters ?? SupporterController.instance;

  /// The first status check has finished, whatever its answer.
  bool _checked = false;

  /// The server refused to create the room: this account is not a supporter.
  bool _refused = false;
  int _capacity = _maxCapacity;
  bool _guestControl = false;
  bool _waitForAll = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _supporters.addListener(_supportersChanged);
    unawaited(_checkSupport());
  }

  @override
  void dispose() {
    _supporters.removeListener(_supportersChanged);
    super.dispose();
  }

  void _supportersChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkSupport() async {
    await _supporters.refresh();
    if (mounted) setState(() => _checked = true);
  }

  _Hosting get _hosting {
    if (_refused) return _Hosting.supportersOnly;
    final status = _supporters.status;
    if (status != null) {
      return _supporters.has(SupporterPerk.hostWatchParty)
          ? _Hosting.allowed
          : _Hosting.supportersOnly;
    }
    // Unknown: wait for the answer. If it cannot be had (offline), offer the
    // settings and let the server decide.
    return _checked ? _Hosting.allowed : _Hosting.checking;
  }

  /// The Supporters page; on return, hosting opens up if the support counted.
  Future<void> _openSupporters() async {
    await Navigator.push(
      context,
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: _supporters),
      ),
    );
    await _supporters.refresh();
    if (mounted) setState(() => _refused = false);
  }

  void _openJoin() => unawaited(
    Navigator.pushReplacement(
      context,
      AppPageRoute<void>(
        context: context,
        builder: (_) => const JoinPartyScreen(),
      ),
    ),
  );

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
      if (!mounted) {
        party.dispose();
        return;
      }
      await Navigator.pushReplacement(
        context,
        AppPageRoute<void>(
          context: context,
          builder: (_) => WaitingRoomScreen(party: party),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      if (error is AccountApiException && error.code == 'supporter_required') {
        // The saved status was out of date (a refund, say): show why.
        setState(() => _refused = true);
        unawaited(_supporters.refresh());
        return;
      }
      setState(() => _error = partyErrorMessage(error));
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
        icon: ReelishIcons.people,
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
              icon: const Icon(ReelishIcons.minus),
            ),
            IconButton(
              tooltip: 'More people',
              onPressed: _capacity < _maxCapacity
                  ? () => setState(() => _capacity++)
                  : null,
              icon: const Icon(ReelishIcons.add),
            ),
          ],
        ),
      ),
      SettingsSwitchTile(
        icon: ReelishIcons.playPause,
        title: 'Everyone can play and pause',
        description: _guestControl
            ? 'Anyone in the party controls playback'
            : 'Only you control playback',
        value: _guestControl,
        onChanged: (value) => setState(() => _guestControl = value),
      ),
      SettingsSwitchTile(
        icon: ReelishIcons.hourglass,
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
                        style: TextStyle(
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
                              ? Text(
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
                          icon: ReelishIcons.celebration,
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
    final desktop = DeviceCapabilities.isDesktop;
    switch (_hosting) {
      case _Hosting.allowed:
        return desktop ? _desktop(context) : _phoneAndTv(context);
      case _Hosting.supportersOnly:
        return desktop
            ? _supportersOnlyDesktop(context)
            : _supportersOnlyPhoneAndTv(context);
      case _Hosting.checking:
        return desktop
            ? const PartyDesktopFrame(
                title: 'Watch together',
                subtitle: 'Start a party, share the code, and watch in sync.',
                child: Center(child: CircularProgressIndicator()),
              )
            : const SettingsScaffold(
                title: 'Watch together',
                subtitle: 'Start a party, share the code, and watch in sync.',
                children: [
                  Padding(
                    padding: EdgeInsets.all(AppSpace.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
              );
    }
  }

  Widget get _becomeSupporter => FilledButton.icon(
    // The remote starts on the main action.
    autofocus: DeviceCapabilities.isTv,
    style: FilledButton.styleFrom(
      backgroundColor: GlassTheme.primary,
      foregroundColor: GlassTheme.background,
      minimumSize: const Size(0, 54),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
    ),
    onPressed: _openSupporters,
    icon: const Icon(ReelishIcons.supporter),
    label: const Text(
      'Become a Supporter',
      style: TextStyle(fontWeight: FontWeight.w800),
    ),
  );

  Widget get _joinInstead => TextButton(
    onPressed: _openJoin,
    child: const Text('Have a code? Join a party'),
  );

  /// Phone and TV: what hosting is, who it is for, and the two ways on. The
  /// phone keeps the actions in reach at the bottom; on TV they follow the
  /// words, so nothing covers them and the remote needs no scrolling.
  Widget _supportersOnlyPhoneAndTv(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    const hosting = SettingsSection(
      label: 'HOSTING',
      children: [
        Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: PartyHostingForSupporters(),
        ),
      ],
    );
    return SettingsScaffold(
      title: 'Watch together',
      subtitle: 'Start a party, share the code, and watch in sync.',
      bottomBar: tv
          ? null
          : SafeArea(
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _becomeSupporter,
                    const SizedBox(height: AppSpace.xs),
                    _joinInstead,
                  ],
                ),
              ),
            ),
      children: tv
          ? [
              hosting,
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Wrap(
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [_becomeSupporter, _joinInstead],
                ),
              ),
            ]
          : [
              SettingsSection(
                label: 'WATCHING',
                children: [PartyContentCard(content: widget.content)],
              ),
              hosting,
            ],
    );
  }

  /// Windows: the poster beside the same words, the actions under them.
  Widget _supportersOnlyDesktop(BuildContext context) => PartyDesktopFrame(
    title: 'Watch together',
    subtitle: 'Start a party, share the code, and watch in sync.',
    child: LayoutBuilder(
      builder: (context, constraints) {
        final posterWidth = constraints.maxWidth >= 900 ? 280.0 : 200.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PartyDesktopPoster(content: widget.content, width: posterWidth),
            const SizedBox(width: AppSpace.xxl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PartyDesktopCard(
                    padding: EdgeInsets.all(AppSpace.xl),
                    child: PartyHostingForSupporters(),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Wrap(
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PartyDesktopButton(
                        label: 'Become a Supporter',
                        icon: ReelishIcons.supporter,
                        onPressed: _openSupporters,
                      ),
                      TextButton(
                        onPressed: _openJoin,
                        child: const Text('Have a code? Join a party'),
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

  Widget _phoneAndTv(BuildContext context) => SettingsScaffold(
    title: 'Watch together',
    subtitle: 'Start a party, share the code, and watch in sync.',
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
                    ? const GlassButtonProgress()
                    : const Icon(ReelishIcons.celebration),
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
      _roomSection(),
      // What happens next, for a first party; each person needs a source.
      const SettingsSection(
        label: 'HOW IT WORKS',
        children: [PartyHowItWorks(vertical: true)],
      ),
    ],
  );
}

/// Hosting is a Supporter privilege: what it offers, and that joining is not.
/// Shown where someone tries to host, and nowhere else.
class PartyHostingForSupporters extends StatelessWidget {
  const PartyHostingForSupporters({super.key});

  static const title = 'Host your own Watch Party';

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SupporterEmblem(size: tv ? 40 : 34),
        const SizedBox(height: AppSpace.md),
        Text(
          title,
          style: TextStyle(
            fontSize: tv ? AppTextSize.headline : AppTextSize.title,
            fontWeight: FontWeight.w800,
            letterSpacing: -.3,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          'Bring your friends and family together and watch in sync.',
          style: TextStyle(color: GlassTheme.muted, height: 1.4),
        ),
        const SizedBox(height: AppSpace.md),
        const Text(
          'Hosting is a privilege for Reelish Supporters. Support Reelish’s '
          'development to host your own parties.',
          style: TextStyle(height: 1.4),
        ),
        const SizedBox(height: AppSpace.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                ReelishIcons.people,
                size: AppIcon.sm,
                color: GlassTheme.muted,
              ),
            ),
            SizedBox(width: AppSpace.xs),
            Expanded(
              child: Text(
                'Anyone can join a party with a code. The people you invite '
                'don’t need to be supporters.',
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.bodySmall,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
