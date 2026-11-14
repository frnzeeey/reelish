// Reactions and chat for a watch party, shared by the waiting room (in the
// page colours) and the player's party sheet (in the player's dark colours).
// Nothing here is stored: the room relays reactions and lines and keeps
// neither; this device keeps the lines it saw while in the party.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../tv/tv_focus.dart';

/// The colours the panel is drawn in, for the surface it sits on.
class PartyChatColors {
  const PartyChatColors({
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.field,
    required this.border,
  });

  /// On a page (the waiting room): the viewer's theme.
  factory PartyChatColors.page() => PartyChatColors(
    text: GlassTheme.textPrimary,
    muted: GlassTheme.muted,
    accent: GlassTheme.primary,
    onAccent: GlassTheme.background,
    field: GlassTheme.elevatedSurface,
    border: GlassTheme.border,
  );

  /// Over video: the player's chrome, dark in every theme.
  factory PartyChatColors.player() => PartyChatColors(
    text: Colors.white,
    muted: GlassTheme.playerSurfaces.textSecondary,
    accent: GlassTheme.playerPrimary,
    onAccent: GlassTheme.playerSurfaces.background,
    field: Colors.white.withValues(alpha: .08),
    border: Colors.white.withValues(alpha: .16),
  );

  final Color text;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color field;
  final Color border;
}

class PartyChatPanel extends StatefulWidget {
  const PartyChatPanel({
    super.key,
    required this.party,
    required this.colors,
    this.messagesHeight = 220,
    this.autofocus = false,
  });

  final WatchPartyController party;
  final PartyChatColors colors;

  /// The chat's height; the newest line is at its foot.
  final double messagesHeight;

  /// TV: the remote starts on the first reaction.
  final bool autofocus;

  @override
  State<PartyChatPanel> createState() => _PartyChatPanelState();
}

class _PartyChatPanelState extends State<PartyChatPanel> {
  final _text = TextEditingController();
  StreamSubscription<PartyReaction>? _reactions;
  final List<(PartyReaction, Timer)> _recent = [];

  /// A short note under the composer (such as "wait a moment").
  String? _hint;
  Timer? _hintTimer;

  WatchPartyController get _party => widget.party;
  PartyChatColors get _c => widget.colors;

  /// Whether this panel counts as the chat being read: only while its page
  /// is on top (the waiting room stays underneath the player).
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    _reactions = _party.reactions.listen(_onReaction);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.of(context)?.isCurrent ?? true;
    if (visible != _counted) {
      _counted = visible;
      _party.chatViewChanged(open: visible);
    }
  }

  @override
  void dispose() {
    if (_counted) _party.chatViewChanged(open: false);
    unawaited(_reactions?.cancel());
    for (final (_, timer) in _recent) {
      timer.cancel();
    }
    _hintTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _onReaction(PartyReaction reaction) {
    if (!mounted) return;
    late final (PartyReaction, Timer) entry;
    entry = (
      reaction,
      Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _recent.remove(entry));
      }),
    );
    setState(() {
      _recent.add(entry);
      if (_recent.length > 4) _recent.removeAt(0).$2.cancel();
    });
  }

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  void _send([String? value]) {
    final text = value ?? _text.text;
    if (text.trim().isEmpty) return;
    if (_party.sendChat(text)) {
      _text.clear();
      setState(() => _hint = null);
    } else if (_party.connection == PartyConnection.connected) {
      _showHint('Wait a moment before sending again.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _party,
    builder: (context, _) {
      if (!_party.supportsReactions && !_party.supportsChat) {
        return Text(
          'Reactions and chat aren’t available in this party.',
          style: TextStyle(color: _c.muted, fontSize: AppTextSize.label),
        );
      }
      final connected = _party.connection == PartyConnection.connected;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_party.supportsReactions) ...[
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                for (final (index, entry) in partyReactions.entries.indexed)
                  _ReactionButton(
                    glyph: entry.value,
                    label: 'React ${entry.key}',
                    colors: _c,
                    autofocus: widget.autofocus && index == 0,
                    onPressed: connected ? () => _party.react(entry.key) : null,
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            SizedBox(
              height: 26,
              child: _recent.isEmpty
                  ? null
                  : Text(
                      _recent
                          .map(
                            (r) =>
                                '${r.$1.pid == _party.you ? 'You' : r.$1.name ?? 'Someone'} ${r.$1.glyph}',
                          )
                          .join('   '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _c.muted,
                        fontSize: AppTextSize.label,
                      ),
                    ),
            ),
          ],
          if (_party.supportsChat) ...[
            _Messages(
              messages: _party.messages,
              height: widget.messagesHeight,
              colors: _c,
            ),
            const SizedBox(height: AppSpace.sm),
            _composer(connected),
            if (_hint != null || !connected)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  connected
                      ? _hint!
                      : 'Reconnecting… messages wait until then.',
                  style: TextStyle(
                    color: _c.muted,
                    fontSize: AppTextSize.label,
                  ),
                ),
              ),
          ],
        ],
      );
    },
  );

  Widget _composer(bool connected) {
    if (DeviceCapabilities.isTv) {
      // The remote types in the TV's own entry dialog.
      return TvTextField(
        value: '',
        hint: 'Send a message',
        title: 'Message the party',
        icon: ReelishIcons.chat,
        textInputAction: TextInputAction.send,
        onChanged: (_) {},
        onSubmitted: connected ? _send : null,
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            enabled: connected,
            maxLength: WatchPartyController.maxChatChars,
            maxLines: 1,
            textInputAction: TextInputAction.send,
            onSubmitted: _send,
            style: TextStyle(color: _c.text, fontSize: AppTextSize.body),
            cursorColor: _c.accent,
            decoration: InputDecoration(
              hintText: 'Send a message',
              hintStyle: TextStyle(color: _c.muted),
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: _c.field,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                borderSide: BorderSide(color: _c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                borderSide: BorderSide(color: _c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                borderSide: BorderSide(color: _c.accent),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: connected ? _send : null,
          style: IconButton.styleFrom(
            backgroundColor: _c.accent,
            foregroundColor: _c.onAccent,
          ),
          icon: const Icon(ReelishIcons.send),
        ),
      ],
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({
    required this.messages,
    required this.height,
    required this.colors,
  });

  final List<PartyChatMessage> messages;
  final double height;
  final PartyChatColors colors;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: colors.field,
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: colors.border),
    ),
    child: messages.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(
                'No messages yet. Lines aren’t saved: anyone who joins later '
                'sees only what comes after.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.muted,
                  fontSize: AppTextSize.label,
                ),
              ),
            ),
          )
        : ListView.builder(
            // Newest at the foot, and kept in view as lines arrive.
            reverse: true,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.xs,
            ),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final line = messages[messages.length - 1 - index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: line.mine ? 'You  ' : '${line.name}  ',
                        style: TextStyle(
                          color: line.mine ? colors.accent : colors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: line.text,
                        style: TextStyle(color: colors.text),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: AppTextSize.body),
                ),
              );
            },
          ),
  );
}

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({
    required this.glyph,
    required this.label,
    required this.colors,
    required this.onPressed,
    this.autofocus = false,
  });

  final String glyph;
  final String label;
  final PartyChatColors colors;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: colors.field,
        shape: StadiumBorder(side: BorderSide(color: colors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: autofocus,
          onTap: onPressed,
          focusColor: colors.accent.withValues(alpha: .35),
          hoverColor: colors.accent.withValues(alpha: .14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Opacity(
              opacity: onPressed == null ? .4 : 1,
              child: Text(glyph, style: const TextStyle(fontSize: 22)),
            ),
          ),
        ),
      ),
    ),
  );
}
