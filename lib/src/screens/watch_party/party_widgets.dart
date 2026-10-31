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
