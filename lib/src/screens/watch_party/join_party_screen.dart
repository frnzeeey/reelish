// Joins a watch party by its 8-digit code: typed or pasted, previewed
// (title, host, how full), then the waiting room.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../navigation/app_transitions.dart';
import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/tv/tv_focus.dart';
import '../../desktop/desktop_widgets.dart';
import 'party_desktop.dart';
import 'party_widgets.dart';
import 'waiting_room_screen.dart';

class JoinPartyScreen extends StatefulWidget {
  const JoinPartyScreen({
    super.key,
    this.preview = previewWatchParty,
    this.open,
  });

  /// Looks a code up (replaced in tests).
  final Future<PartyPreview> Function(String code) preview;

  /// Opens the waiting room for a code; by default a connected controller.
  final void Function(BuildContext context, String code)? open;

  @override
  State<JoinPartyScreen> createState() => _JoinPartyScreenState();
}

class _JoinPartyScreenState extends State<JoinPartyScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  PartyPreview? _found;
  String? _error;
  bool _looking = false;
  bool _joining = false;
  String? _lookedUp;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String text) {
    final code = partyCodeFrom(text);
    if (code == null) {
      if (_found != null || _error != null) {
        setState(() {
          _found = null;
          _error = null;
          _lookedUp = null;
        });
      }
      return;
    }
    if (code != _lookedUp) _lookUp(code);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final code = partyCodeFrom(data?.text ?? '');
    if (!mounted) return;
    if (code == null) {
      setState(() => _error = 'The clipboard has no 8-digit party code.');
      return;
    }
    _field.text = code;
    _changed(code);
  }

  Future<void> _lookUp(String code) async {
    setState(() {
      _lookedUp = code;
      _looking = true;
      _error = null;
      _found = null;
    });
    try {
      final preview = await widget.preview(code);
      if (!mounted || _lookedUp != code) return;
      setState(() => _found = preview);
      _focus.unfocus();
    } catch (error) {
      if (mounted && _lookedUp == code) {
        setState(() => _error = partyErrorMessage(error));
      }
    } finally {
      if (mounted && _lookedUp == code) setState(() => _looking = false);
    }
  }

  Future<void> _join() async {
    final found = _found;
    if (found == null || found.full) return;
    final open = widget.open;
    if (open != null) {
      open(context, found.code);
      return;
    }
    setState(() => _joining = true);
    final party = WatchPartyController(code: found.code);
    await party.start();
    if (!mounted) {
      party.dispose();
      return;
    }
    setState(() => _joining = false);
    await Navigator.pushReplacement(
      context,
      AppPageRoute<void>(
        context: context,
        builder: (_) => WaitingRoomScreen(party: party),
      ),
    );
  }

  /// Windows: one centred card with the code as eight boxes, Paste and
  /// Join beside each other, and the party shown in place once found.
  Widget _desktop(BuildContext context) {
    final found = _found;
    final canJoin = found != null && !found.full && !_joining;
    return PartyDesktopFrame(
      title: 'Join a party',
      subtitle: 'Watch in sync with a friend who started one.',
      maxWidth: 640,
      child: PartyDesktopCard(
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: GlassTheme.primary.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Symbols.groups_rounded,
                size: 28,
                color: GlassTheme.primary,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            const Text(
              'Enter the party code',
              style: TextStyle(
                fontSize: AppTextSize.titleLarge,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppSpace.xxs),
            const Text(
              'The host sees it in their waiting room. Pasting a whole '
              'invitation works too.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GlassTheme.muted),
            ),
            const SizedBox(height: AppSpace.lg),
            PartyCodeBoxes(
              controller: _field,
              focusNode: _focus,
              onChanged: _changed,
              onSubmitted: canJoin ? _join : null,
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _paste,
                    icon: const Icon(Symbols.content_paste_rounded),
                    label: const Text('Paste code'),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                PartyDesktopButton(
                  label: found?.full == true
                      ? 'This party is full'
                      : 'Join party',
                  icon: Symbols.login_rounded,
                  busy: _joining,
                  onPressed: canJoin ? _join : null,
                ),
              ],
            ),
            // Where the lookup's answer appears: a spinner, the reason it
            // failed, or the party itself.
            AnimatedSize(
              duration: desktopMotion(context, 220),
              curve: DesktopSurfaces.curve,
              alignment: Alignment.topCenter,
              child: Column(
                children: [
                  if (_looking)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.lg),
                      child: CircularProgressIndicator(
                        color: GlassTheme.primary,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.lg),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: GlassTheme.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (found != null) ...[
                    const SizedBox(height: AppSpace.lg),
                    const Divider(height: 1, color: DesktopSurfaces.hairline),
                    const SizedBox(height: AppSpace.xs),
                    PartyContentCard(
                      content: found.content,
                      detail:
                          'Hosted by ${found.hostName} · '
                          '${found.participants}/${found.capacity} people'
                          '${found.phase == PartyPhase.watching ? ' · watching now' : ''}',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DeviceCapabilities.isDesktop) return _desktop(context);
    final found = _found;
    return SettingsScaffold(
      title: 'Join a party',
      subtitle: 'Enter the 8-digit code the host shared with you.',
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
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: GlassTheme.primary,
                foregroundColor: GlassTheme.background,
              ),
              onPressed: found == null || found.full || _joining ? null : _join,
              icon: const Icon(Symbols.login_rounded),
              label: Text(
                found?.full == true ? 'This party is full' : 'Join party',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
      ),
      children: [
        SettingsSection(
          label: 'PARTY CODE',
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(
                children: [
                  // TV: the remote's Select opens the TV keyboard (number
                  // pad); focus alone never does, so the D-pad can pass.
                  if (DeviceCapabilities.isTv)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _field,
                      builder: (context, value, _) => TvTextField(
                        value: value.text.isEmpty
                            ? ''
                            : formatPartyCode(value.text),
                        hint: 'Party code (8 digits)',
                        title: 'Enter the party code',
                        icon: Symbols.dialpad_rounded,
                        keyboardType: TextInputType.number,
                        autofocus: true,
                        onChanged: (text) {
                          final digits = text.replaceAll(RegExp(r'\D'), '');
                          final code = digits.length > 8
                              ? digits.substring(0, 8)
                              : digits;
                          _field.text = code;
                          _changed(code);
                        },
                      ),
                    )
                  else
                    // The same eight boxes as on Windows, sized to fit.
                    PartyCodeBoxes(
                      controller: _field,
                      focusNode: _focus,
                      onChanged: _changed,
                      onSubmitted: found != null && !found.full && !_joining
                          ? _join
                          : null,
                    ),
                  // A TV rarely has anything to paste.
                  if (!DeviceCapabilities.isTv) ...[
                    const SizedBox(height: AppSpace.sm),
                    TextButton.icon(
                      onPressed: _paste,
                      icon: const Icon(Symbols.content_paste_rounded),
                      label: const Text('Paste code'),
                    ),
                    const Text(
                      'The host sees it in their waiting room. Pasting a '
                      'whole invitation works too.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.label,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (_looking)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
            child: Center(
              child: CircularProgressIndicator(color: GlassTheme.primary),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: Text(
              _error!,
              style: const TextStyle(color: GlassTheme.danger),
            ),
          ),
        if (found != null)
          SettingsSection(
            label: 'PARTY',
            children: [
              PartyContentCard(
                content: found.content,
                detail:
                    'Hosted by ${found.hostName} · '
                    '${found.participants}/${found.capacity} people'
                    '${found.phase == PartyPhase.watching ? ' · watching now' : ''}',
              ),
            ],
          ),
      ],
    );
  }
}
