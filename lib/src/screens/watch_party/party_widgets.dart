// Pieces the watch party screens share: the title card, a participant's
// avatar and row, the room code, and plain words for errors and statuses.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../account/account_api.dart';
import '../../account/profile_controller.dart';
import '../../models/tv_season.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../watch_party/party_models.dart';
import '../../widgets/profile_avatar.dart';

/// The title a party plays: poster, name, episode, and an optional line.
class PartyContentCard extends StatelessWidget {
  const PartyContentCard({super.key, required this.content, this.detail});

  final PartyContent content;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final poster = content.posterUrl;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: SizedBox(
              width: 64,
              height: 96,
              child: poster.isEmpty
                  ? const _PosterFallback()
                  : Image.network(
                      poster,
                      fit: BoxFit.cover,
                      cacheWidth: (64 * dpr).ceil(),
                      errorBuilder: (_, _, _) => const _PosterFallback(),
                    ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  content.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppTextSize.title,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  content.isSeries ? content.episodeLabel : 'Movie',
                  style: const TextStyle(color: GlassTheme.muted),
                ),
                if (detail != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: GlassTheme.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: GlassTheme.surface,
    child: Icon(Symbols.movie_rounded, color: GlassTheme.muted),
  );
}

/// Asks which episode of [season] a party watches; a dialog the D-pad,
/// mouse, keyboard and touch all work in. Null when dismissed.
Future<int?> pickPartyEpisode(
  BuildContext context, {
  required int season,
  required List<TvEpisode> episodes,
}) => showDialog<int>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text('Watch together: season $season'),
    children: [
      for (final episode in episodes)
        if ((episode.number ?? 0) > 0)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, episode.number),
            child: Text(
              'E${episode.number.toString().padLeft(2, '0')}  '
              '${episode.name ?? 'Episode ${episode.number}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
    ],
  ),
);

/// A participant's preset avatar, or their initial.
class PartyAvatar extends StatelessWidget {
  const PartyAvatar({
    super.key,
    required this.name,
    this.avatar,
    this.size = 40,
  });

  final String name;
  final String? avatar;
  final double size;

  @override
  Widget build(BuildContext context) => ProfileAvatarView(
    avatar: AvatarPreset.byId(avatar) == null
        ? const ProfileAvatar.initials()
        : ProfileAvatar.preset(avatar!),
    name: name,
    size: size,
  );
}

/// The colour of a participant's status: the accent when their player is
/// ready, the warning colour when it cannot play, quiet otherwise.
Color participantStatusColor(ParticipantStatus status) => switch (status) {
  ParticipantStatus.ready || ParticipantStatus.playing => GlassTheme.primary,
  ParticipantStatus.unavailable ||
  ParticipantStatus.error => GlassTheme.warning,
  _ => GlassTheme.muted,
};

/// Whether a participant's player is past loading (ready, watching, or
/// known not to play): what "Wait for everyone" waits for.
bool participantSettled(ParticipantStatus status) =>
    status != ParticipantStatus.joined && status != ParticipantStatus.loading;

/// A participant's status as a small dot and its words.
class PartyStatusLine extends StatelessWidget {
  const PartyStatusLine({super.key, required this.status});

  final ParticipantStatus status;

  @override
  Widget build(BuildContext context) {
    final color = participantStatusColor(status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            participantStatusLabel(status),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color == GlassTheme.muted ? GlassTheme.muted : color,
              fontSize: AppTextSize.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// What a participant's player is doing, in a few words.
String participantStatusLabel(ParticipantStatus status) => switch (status) {
  ParticipantStatus.joined => 'In the room',
  ParticipantStatus.loading => 'Finding a source',
  ParticipantStatus.ready => 'Ready',
  ParticipantStatus.playing => 'Watching',
  ParticipantStatus.paused => 'Paused',
  ParticipantStatus.buffering => 'Buffering',
  ParticipantStatus.unavailable => 'Can’t play this title',
  ParticipantStatus.error => 'Player problem',
};

/// A sentence for a failed watch party request.
String partyErrorMessage(Object error) {
  if (error is! AccountApiException) {
    return 'Something went wrong. Try again.';
  }
  return switch (error.code) {
    'party_not_found' => 'No party has that code. Check it and try again.',
    'party_full' => 'This party is full.',
    'party_removed' => 'The host removed you from this party.',
    'party_unavailable' =>
      'Watch Party is unavailable right now. Try again later.',
    'rate_limited' => 'Too many tries. Wait a minute and try again.',
    'invalid_content' => 'This title can’t be watched together.',
    'network' => 'No connection. Check your network and try again.',
    'not_configured' => 'This build has no Reelish service configured.',
    _ when error.isUnauthorized => 'Sign in again to continue.',
    _ => 'Something went wrong. Try again.',
  };
}

/// The room code, large and spaced, with copy actions under it.
class PartyCodeBlock extends StatelessWidget {
  const PartyCodeBlock({super.key, required this.code, required this.title});

  final String code;

  /// The title, for the invitation text.
  final String title;

  Future<void> _copy(BuildContext context, String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.lg,
      AppSpace.md,
      AppSpace.md,
    ),
    child: Column(
      children: [
        const Text(
          'PARTY CODE',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: AppTextSize.caption,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Semantics(
          label: 'Party code ${code.split('').join(' ')}',
          excludeSemantics: true,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatPartyCode(code),
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            OutlinedButton.icon(
              onPressed: () => _copy(context, code, 'Code copied.'),
              icon: const Icon(Symbols.content_copy_rounded),
              label: const Text('Copy code'),
            ),
            OutlinedButton.icon(
              onPressed: () => _copy(
                context,
                'Watch $title with me on Reelish. Open Join a party and '
                    'enter ${formatPartyCode(code)}.',
                'Invitation copied. Paste it in a message.',
              ),
              icon: const Icon(Symbols.forward_to_inbox_rounded),
              label: const Text('Copy invitation'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Three short steps: what a watch party does. Side by side on a desktop
/// window; [vertical] stacks them, for a phone.
class PartyHowItWorks extends StatelessWidget {
  const PartyHowItWorks({super.key, this.vertical = false});

  final bool vertical;

  static const _steps = [
    (Symbols.ios_share_rounded, 'Share the code', 'Friends join with it'),
    (
      Symbols.extension_rounded,
      'Everyone finds a source',
      'From their own plugins',
    ),
    (Symbols.sync_rounded, 'Watch in sync', 'Play, pause and seek together'),
  ];

  @override
  Widget build(BuildContext context) {
    if (vertical) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          children: [
            for (final (index, (icon, title, detail)) in _steps.indexed) ...[
              if (index > 0) const SizedBox(height: AppSpace.md),
              _step(icon, title, detail),
            ],
          ],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, (icon, title, detail)) in _steps.indexed) ...[
          if (index > 0) const SizedBox(width: AppSpace.md),
          Expanded(child: _step(icon, title, detail)),
        ],
      ],
    );
  }

  static Widget _step(IconData icon, String title, String detail) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: GlassTheme.primary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(icon, size: 18, color: GlassTheme.primary),
      ),
      const SizedBox(width: AppSpace.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: AppTextSize.bodySmall,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              style: const TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The room code as eight boxes in two groups of four, over one hidden text
/// field: typing, Backspace and Ctrl+V (digits are kept from any pasted
/// text) all work as in a field, and the next box to fill is highlighted.
class PartyCodeBoxes extends StatefulWidget {
  const PartyCodeBoxes({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<PartyCodeBoxes> createState() => _PartyCodeBoxesState();
}

class _PartyCodeBoxesState extends State<PartyCodeBoxes> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refresh);
  }

  @override
  void dispose() {
    _focus.removeListener(_refresh);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Party code',
    textField: true,
    value: widget.controller.text.split('').join(' '),
    child: GestureDetector(
      onTap: _focus.requestFocus,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // The field that takes the keys, out of sight under the boxes.
            Opacity(
              opacity: 0,
              child: ExcludeSemantics(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  keyboardType: TextInputType.number,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  onChanged: widget.onChanged,
                  onSubmitted: (_) => widget.onSubmitted?.call(),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final digits = value.text;
                final focused = _focus.hasFocus;
                Widget box(int index) {
                  final filled = index < digits.length;
                  final current =
                      focused &&
                      (index == digits.length ||
                          (digits.length == 8 && index == 7));
                  return AnimatedContainer(
                    duration: AppMotion.resolve(context, AppMotion.hover),
                    curve: AppMotion.enter,
                    width: 52,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: filled
                          ? GlassTheme.primary.withValues(alpha: .08)
                          : Colors.white.withValues(alpha: .04),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        width: current ? 2 : 1,
                        color: current
                            ? GlassTheme.primary
                            : filled
                            ? GlassTheme.primary.withValues(alpha: .4)
                            : Colors.white.withValues(alpha: .12),
                      ),
                    ),
                    child: Text(
                      filled ? digits[index] : '',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  );
                }

                // Full size on a desktop window; scaled down to fit a phone.
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 8; i++) ...[
                        if (i == 4)
                          // The two halves, as the code is written.
                          const SizedBox(
                            width: 28,
                            child: Center(
                              child: Text(
                                '–',
                                style: TextStyle(
                                  color: GlassTheme.muted,
                                  fontSize: 22,
                                ),
                              ),
                            ),
                          )
                        else if (i > 0)
                          const SizedBox(width: AppSpace.xs),
                        box(i),
                      ],
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
