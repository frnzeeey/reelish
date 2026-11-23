// The parts of Together about people and moments rather than lists: the
// welcome for someone new, the friends strip, the shortcuts, Movie night and
// Shared discoveries. The lists (requests, conversations, friends, privacy)
// stay in settings sections (friends_screen.dart). Everything shown is real
// data from the social controllers; nothing here is a placeholder.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/count_badge.dart';
import '../../widgets/poster_image.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/social/social_widgets.dart';
import '../../widgets/tv/tv_focus.dart';

/// "Good evening", by the hour on this device.
String greetingFor(DateTime now) => switch (now.hour) {
  >= 5 && < 12 => 'Good morning',
  >= 12 && < 18 => 'Good afternoon',
  _ => 'Good evening',
};

/// A section's label, with an action at its end (See all).
class TogetherHeading extends StatelessWidget {
  const TogetherHeading({
    super.key,
    required this.label,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      // The label exactly where a settings section's sits, so headings
      // side by side (TV, Windows) line up; the action floats at its end
      // without making the row taller.
      SettingsSectionHeader(label: label),
      if (actionLabel case final action?)
        Positioned(
          right: 0,
          top: -12,
          child: TextButton(onPressed: onAction, child: Text(action)),
        ),
    ],
  );
}

/// The friends' faces, the ones watching something now first with what
/// they watch, then everyone else, and a way to add one more. Online status
/// is not shown: Reelish does not know it.
class FriendsStrip extends StatelessWidget {
  const FriendsStrip({
    super.key,
    required this.friends,
    required this.watching,
    required this.onOpen,
    required this.onAdd,
  });

  final List<SocialPerson> friends;
  final List<WatchingFriend> watching;
  final ValueChanged<SocialPerson> onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final now = {for (final w in watching) w.person.handle: w};
    final ordered = [
      for (final w in watching) w.person,
      for (final person in friends)
        if (!now.containsKey(person.handle)) person,
    ];
    // The avatar with its ring, then the name and what they watch, each line
    // as tall as the reader's text size makes it.
    final scaler = MediaQuery.textScalerOf(context);
    final height =
        (tv ? 64.0 : 56.0) +
        10 +
        2 * AppSpace.xxs +
        6 +
        scaler.scale(AppTextSize.label) * 1.4 +
        scaler.scale(AppTextSize.micro) * 1.4 +
        4;
    return SizedBox(
      height: height,
      // One group, so Left and Right on a TV remote move along the row
      // instead of jumping to whatever lies nearest that way on the page.
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxs),
          children: [
            for (final person in ordered)
              _PersonBubble(
                person: person,
                caption: now[person.handle]?.label,
                onTap: () => onOpen(person),
              ),
            _AddBubble(onTap: onAdd),
          ],
        ),
      ),
    );
  }
}

class _PersonBubble extends StatelessWidget {
  const _PersonBubble({
    required this.person,
    required this.onTap,
    this.caption,
  });

  final SocialPerson person;

  /// What they are watching now, when they share it.
  final String? caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final size = tv ? 64.0 : 56.0;
    final watching = caption != null;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpace.sm),
      child: TvFocusable(
        onSelect: onTap,
        borderRadius: AppRadius.lg,
        semanticLabel: watching
            ? '${person.label}, watching $caption'
            : person.label,
        child: SizedBox(
          width: tv ? 96 : 80,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
            child: Column(
              children: [
                // Watching now: ringed in the accent, the room is lit.
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: watching ? GlassTheme.primary : GlassTheme.border,
                      width: 2,
                    ),
                  ),
                  child: PersonAvatar(person: person, size: size),
                ),
                const SizedBox(height: 6),
                Text(
                  person.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.label,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  caption ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GlassTheme.primary,
                    fontSize: AppTextSize.micro,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddBubble extends StatelessWidget {
  const _AddBubble({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final size = (tv ? 64.0 : 56.0) + 10;
    return TvFocusable(
      onSelect: onTap,
      borderRadius: AppRadius.lg,
      semanticLabel: 'Add a friend',
      child: SizedBox(
        width: tv ? 96 : 80,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
          child: Column(
            children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GlassTheme.primary.withValues(alpha: .12),
                ),
                child: Icon(
                  ReelishIcons.personAdd,
                  color: GlassTheme.primary,
                  size: AppIcon.md,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Add',
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Messages, one tap from the top of the page, with what is new in it.
/// (Adding a friend is the strip's last face and Your people's first row.)
class TogetherShortcuts extends StatelessWidget {
  const TogetherShortcuts({
    super.key,
    required this.newMessages,
    required this.onMessages,
  });

  /// Unread and waiting messages, on the Messages button.
  final int newMessages;
  final VoidCallback onMessages;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: FilledButton.tonalIcon(
      onPressed: onMessages,
      icon: CountBadge(
        count: newMessages,
        child: const Icon(ReelishIcons.chat),
      ),
      label: Text(newMessages > 0 ? 'Messages · $newMessages new' : 'Messages'),
    ),
  );
}

/// A section's opening: an accent badge, its title and one line on what it
/// is for. Sits on the page itself, so only the actions under it are
/// surfaces (no card around the whole section).
class _SectionIntro extends StatelessWidget {
  const _SectionIntro({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: GlassTheme.primary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(icon, color: GlassTheme.primary, size: AppIcon.md),
      ),
      const SizedBox(width: AppSpace.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppType.title.copyWith(color: GlassTheme.textPrimary),
            ),
            const SizedBox(height: AppSpace.xxs),
            Text(
              text,
              style: AppType.bodySmall.copyWith(
                color: GlassTheme.muted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Movie night: join a party with a code, or pick a title to host one.
/// Anyone can do either. Two equal tiles side by side, Join lit with the
/// accent; stacked on TV (so Down goes from Join to Host) and where the
/// page is too narrow for two.
class MovieNightCard extends StatelessWidget {
  const MovieNightCard({super.key, required this.onJoin, this.onPickTitle});

  final VoidCallback onJoin;

  /// Opens search, where a title's page starts a party. Null where the page
  /// has no way to search (a test).
  final VoidCallback? onPickTitle;

  @override
  Widget build(BuildContext context) {
    final join = _MovieNightTile(
      icon: ReelishIcons.dialpad,
      label: 'Join with a code',
      hint: 'Got a party code?',
      lit: true,
      onSelect: onJoin,
    );
    final host = switch (onPickTitle) {
      final pick? => _MovieNightTile(
        icon: ReelishIcons.movieFilter,
        label: 'Pick a title to host',
        hint: 'Choose what to watch',
        onSelect: pick,
      ),
      null => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionIntro(
          icon: ReelishIcons.watchParty,
          title: 'Movie night',
          text:
              'Watch in sync with friends, wherever they are: play, pause '
              'and seeking stay together.',
        ),
        const SizedBox(height: AppSpace.md),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                DeviceCapabilities.isTv || constraints.maxWidth < 300;
            if (host == null) return join;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  join,
                  const SizedBox(height: AppSpace.sm),
                  host,
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: join),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: host),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A surface that does something when pressed. On TV, the remote's focus
/// (TvFocusable: the lit ring, the slight lift). Elsewhere, a ripple drawn
/// over the surface and the keyboard's focus ring (Windows), with no ring
/// left behind after a tap.
class _Pressable extends StatelessWidget {
  const _Pressable({
    required this.onSelect,
    required this.borderRadius,
    required this.semanticLabel,
    required this.child,
    this.focusScale = 1.03,
  });

  final VoidCallback onSelect;
  final double borderRadius;
  final String semanticLabel;
  final double focusScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (DeviceCapabilities.isTv) {
      return TvFocusable(
        onSelect: onSelect,
        borderRadius: borderRadius,
        focusScale: focusScale,
        semanticLabel: semanticLabel,
        child: child,
      );
    }
    final radius = BorderRadius.circular(borderRadius);
    return Semantics(
      button: true,
      label: semanticLabel,
      // Passthrough: the surface keeps the width and height it is given
      // (two equal tiles), the ink fills it.
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: onSelect,
                focusColor: GlassTheme.primary.withValues(alpha: .12),
                splashColor: GlassTheme.primary.withValues(alpha: .12),
                highlightColor: GlassTheme.textPrimary.withValues(alpha: .04),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One Movie night action: an icon, its name and a line on when to use it.
/// [lit] gives it the accent, for the action most people come for.
class _MovieNightTile extends StatelessWidget {
  const _MovieNightTile({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onSelect,
    this.lit = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onSelect;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    return _Pressable(
      onSelect: onSelect,
      borderRadius: AppRadius.lg,
      focusScale: 1.03,
      semanticLabel: label,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: lit
              ? accent.withValues(alpha: .14)
              : GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: lit ? accent.withValues(alpha: .4) : GlassTheme.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppIcon.md,
              color: lit ? accent : GlassTheme.textPrimary,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              label,
              style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: AppTextSize.body,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hint,
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// For someone with nobody here yet: what Together is for, Add a friend
/// first and strongest, and their own code to give out, shown as the
/// identifier it is and copied with a tap.
class WelcomeCard extends StatelessWidget {
  const WelcomeCard({
    super.key,
    required this.friendCode,
    required this.onAdd,
    required this.onCopyCode,
  });

  final String friendCode;
  final VoidCallback onAdd;
  final VoidCallback onCopyCode;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionIntro(
        icon: ReelishIcons.people,
        title: 'Bring your people in',
        text:
            'Add friends by their code or @handle. Then message them, send '
            'them titles and watch together.',
      ),
      const SizedBox(height: AppSpace.md),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: onAdd,
        icon: const Icon(ReelishIcons.personAdd),
        label: const Text('Add a friend'),
      ),
      const SizedBox(height: AppSpace.sm),
      _CodePanel(code: friendCode, onCopy: onCopyCode),
    ],
  );
}

/// Your friend code as a shareable identifier: labelled, large and spaced,
/// copied with a tap, and saying so in place for a moment.
class _CodePanel extends StatefulWidget {
  const _CodePanel({required this.code, required this.onCopy});

  final String code;
  final VoidCallback onCopy;

  @override
  State<_CodePanel> createState() => _CodePanelState();
}

class _CodePanelState extends State<_CodePanel> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _copy() {
    widget.onCopy();
    _reset?.cancel();
    setState(() => _copied = true);
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    return _Pressable(
      onSelect: _copy,
      borderRadius: AppRadius.lg,
      focusScale: 1.02,
      semanticLabel: 'Copy your code ${widget.code}',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: GlassTheme.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'YOUR FRIEND CODE',
                    style: TextStyle(
                      color: GlassTheme.muted,
                      fontSize: AppTextSize.caption,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.code,
                    style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: AppTextSize.titleLarge,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: AppMotion.resolve(context, AppMotion.hover),
              child: Row(
                key: ValueKey(_copied),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _copied ? ReelishIcons.check : ReelishIcons.copy,
                    size: 20,
                    color: _copied ? accent : GlassTheme.muted,
                  ),
                  const SizedBox(width: AppSpace.xxs + 2),
                  Text(
                    _copied ? 'Copied' : 'Copy',
                    style: TextStyle(
                      color: _copied ? accent : GlassTheme.muted,
                      fontSize: AppTextSize.label,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Titles friends sent, as posters: the newest first, new ones marked.
class DiscoveriesRow extends StatelessWidget {
  const DiscoveriesRow({super.key, required this.items, required this.onOpen});

  final List<Recommendation> items;
  final ValueChanged<Recommendation> onOpen;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final width = tv ? 128.0 : 108.0;
    // The poster, then its title and who sent it at the reader's text size.
    final scaler = MediaQuery.textScalerOf(context);
    final height =
        width * 1.5 +
        6 +
        scaler.scale(AppTextSize.label) * 1.4 +
        2 * scaler.scale(AppTextSize.caption) * 1.4 +
        4;
    return SizedBox(
      height: height,
      // One group, as in the friends strip: Left and Right stay in the row.
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: _DiscoveryPoster(
                  item: item,
                  width: width,
                  onTap: () => onOpen(item),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryPoster extends StatelessWidget {
  const _DiscoveryPoster({
    required this.item,
    required this.width,
    required this.onTap,
  });

  final Recommendation item;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final media = item.media;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final from = item.from;
    return TvFocusable(
      onSelect: onTap,
      borderRadius: AppRadius.md,
      semanticLabel: [
        media.name,
        if (from != null) 'from ${from.label}',
        if (!item.read) 'new',
      ].join(', '),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: SizedBox(
                    width: width,
                    height: width * 1.5,
                    child: media.poster.isEmpty
                        ? const PosterPlaceholder(iconSize: 28)
                        : ArtworkImage.network(
                            media.poster,
                            fit: BoxFit.cover,
                            cacheWidth: (width * ratio).round(),
                            frameBuilder: posterFadeIn(context),
                            errorBuilder: (_, _, _) =>
                                const PosterPlaceholder(iconSize: 28),
                          ),
                  ),
                ),
                if (!item.read)
                  Positioned(
                    top: AppSpace.xs,
                    left: AppSpace.xs,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: GlassTheme.primary,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        'NEW',
                        style: TextStyle(
                          color: GlassTheme.background,
                          fontSize: AppTextSize.micro,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              media.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: AppTextSize.label,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (from != null)
              Text(
                'from ${from.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.caption,
                ),
              ),
            // The note they sent with it, the friend's own words.
            if (item.message case final note? when note.trim().isNotEmpty)
              Text(
                '“${note.trim()}”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: AppTextSize.caption,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
