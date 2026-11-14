// The watch party's social side in the player: a top-bar button that opens
// reactions and chat in a player sheet, and a layer over the video where
// others' reactions rise and fade and new lines show for a moment. Only
// built while the player is in a party; it never takes taps over the video.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../watch_party/party_models.dart';
import '../../watch_party/watch_party_controller.dart';
import '../watch_party/party_chat_panel.dart';
import 'player_controls.dart';
import 'player_sheet.dart';

/// Opens reactions and chat over the player.
abstract final class PartySocialSheet {
  static Future<void> show(BuildContext context, WatchPartyController party) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => Padding(
          // Above the keyboard on a phone.
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: PlayerSheetFrame(
            icon: ReelishIcons.chat,
            title: 'Watch party',
            subtitle: 'Reactions and chat · nothing is saved',
            children: [
              PartyChatPanel(
                party: party,
                colors: PartyChatColors.player(),
                messagesHeight: 200,
                autofocus: DeviceCapabilities.isTv,
              ),
            ],
          ),
        ),
      );
}

/// The top-bar button, with a dot while there are lines not yet seen.
class PartyChatButton extends StatelessWidget {
  const PartyChatButton({
    super.key,
    required this.party,
    required this.onPressed,
  });

  final WatchPartyController party;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: party,
    builder: (context, _) {
      if (!party.supportsChat && !party.supportsReactions) {
        return const SizedBox.shrink();
      }
      final unread = party.unreadChat;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          PlayerIconButton(
            icon: ReelishIcons.chat,
            label: unread == 0
                ? 'Reactions and chat'
                : 'Reactions and chat, $unread new',
            onPressed: onPressed,
          ),
          if (unread > 0)
            Positioned(
              top: 10,
              right: 10,
              child: IgnorePointer(
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: GlassTheme.playerPrimary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Others' reactions and new lines, over the video. Fills its parent.
class PartyActivityLayer extends StatefulWidget {
  const PartyActivityLayer({
    super.key,
    required this.party,
    required this.topInset,
  });

  final WatchPartyController party;

  /// Where the line toast sits: under the party badge.
  final double topInset;

  @override
  State<PartyActivityLayer> createState() => _PartyActivityLayerState();
}

class _PartyActivityLayerState extends State<PartyActivityLayer> {
  static const _maxFloating = 8;
  StreamSubscription<PartyReaction>? _reactions;
  final List<_Floating> _floating = [];
  int _ids = 0;
  PartyChatMessage? _lastSeen;
  PartyChatMessage? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _reactions = widget.party.reactions.listen(_onReaction);
    _lastSeen = widget.party.messages.lastOrNull;
    widget.party.addListener(_onParty);
  }

  @override
  void dispose() {
    widget.party.removeListener(_onParty);
    unawaited(_reactions?.cancel());
    _toastTimer?.cancel();
    super.dispose();
  }

  void _onReaction(PartyReaction reaction) {
    if (!mounted) return;
    setState(() {
      _floating.add(_Floating(_ids++, reaction));
      if (_floating.length > _maxFloating) _floating.removeAt(0);
    });
  }

  /// A new line from someone else, while the chat is not on screen.
  void _onParty() {
    final lines = widget.party.messages;
    if (lines.isEmpty || identical(lines.last, _lastSeen)) return;
    // The list is capped, so look for the last line seen, not a count.
    final from = _lastSeen == null ? -1 : lines.indexOf(_lastSeen!);
    _lastSeen = lines.last;
    final latest = lines.skip(from + 1).where((line) => !line.mine).lastOrNull;
    if (latest == null || widget.party.chatOpen || !mounted) return;
    _toastTimer?.cancel();
    setState(() => _toast = latest);
    _toastTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final toast = _toast;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final item in _floating)
            _FloatingReaction(
              key: ValueKey(item.id),
              reaction: item.reaction,
              lane: item.id % 4,
              onDone: () {
                if (mounted) setState(() => _floating.remove(item));
              },
            ),
          Positioned(
            top: widget.topInset,
            left: 16,
            right: 16,
            child: Center(
              child: AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.standard),
                child: toast == null
                    ? const SizedBox.shrink()
                    : _LineToast(key: ValueKey(toast), line: toast),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Floating {
  _Floating(this.id, this.reaction);
  final int id;
  final PartyReaction reaction;
}

/// One reaction rising from the lower right and fading; held still and
/// fading only, when the system asks for reduced motion.
class _FloatingReaction extends StatefulWidget {
  const _FloatingReaction({
    super.key,
    required this.reaction,
    required this.lane,
    required this.onDone,
  });

  final PartyReaction reaction;
  final int lane;
  final VoidCallback onDone;

  @override
  State<_FloatingReaction> createState() => _FloatingReactionState();
}

class _FloatingReactionState extends State<_FloatingReaction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final name = widget.reaction.name;
    return AnimatedBuilder(
      animation: _motion,
      builder: (context, child) {
        final t = _motion.value;
        final rise = still ? 0.0 : Curves.easeOutCubic.transform(t) * 180;
        final opacity = t < .75 ? 1.0 : (1 - (t - .75) / .25);
        return Positioned(
          right: 24.0 + widget.lane * 42,
          bottom: 120 + rise,
          child: Opacity(opacity: opacity.clamp(0, 1), child: child),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.reaction.glyph,
            style: const TextStyle(
              fontSize: 34,
              shadows: [Shadow(color: Colors.black54, blurRadius: 12)],
            ),
          ),
          if (name != null)
            Text(
              name,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
              ),
            ),
        ],
      ),
    );
  }
}

class _LineToast extends StatelessWidget {
  const _LineToast({super.key, required this.line});

  final PartyChatMessage line;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: '${line.name} says ${line.text}',
    excludeSemantics: true,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withValues(alpha: .14)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${line.name}  ',
              style: TextStyle(
                color: GlassTheme.playerPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: line.text),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppTextSize.label,
        ),
      ),
    ),
  );
}
