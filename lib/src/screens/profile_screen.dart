// The signed-in person's page: who they are, their viewing at a glance, and
// the way into their library, watch parties and account. It changes nothing
// itself: editing goes to the existing Profile and account page, the library
// to its own tab, and settings to Settings.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_controller.dart';
import '../account/profile_controller.dart';
import '../models/media_item.dart';
import '../navigation/app_transitions.dart';
import '../services/storage_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/settings/settings_components.dart';
import 'account_settings_screen.dart';
import 'legal_information_screen.dart';
import 'watch_party/join_party_screen.dart';

/// What the library holds, counted from this device's history and My list.
@immutable
class ProfileActivity {
  const ProfileActivity({
    required this.myList,
    required this.watched,
    required this.inProgress,
  });

  /// Counts [history] and [favorites]: a title is in progress when it has a
  /// saved position short of its end.
  factory ProfileActivity.from({
    required List<MediaItem> history,
    required List<MediaItem> favorites,
  }) => ProfileActivity(
    myList: favorites.length,
    watched: history.length,
    inProgress: history
        .where(
          (item) =>
              item.resumeMs > 0 &&
              (item.durationMs <= 0 || item.resumeMs < item.durationMs * .95),
        )
        .length,
  );

  final int myList;
  final int watched;
  final int inProgress;

  bool get isEmpty => myList == 0 && watched == 0;
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.storage,
    this.onBack,
    this.onOpenLibrary,
    this.onOpenSettings,
    this.refreshToken = 0,
    this.account,
    this.profile,
  });

  final StorageService storage;

  /// Shown as Back when the page was opened over another (phone).
  final VoidCallback? onBack;

  /// Opens the library where the interface keeps it.
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenSettings;

  /// A change re-reads the activity (the page stays built in TV and
  /// Windows navigation).
  final int refreshToken;
  final AccountController? account;
  final ProfileController? profile;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<ProfileActivity> _activity = _load();

  AccountController get _account =>
      widget.account ?? AccountController.instance;
  ProfileController get _profile =>
      widget.profile ?? ProfileController.instance;

  /// Local reads only: no network request.
  Future<ProfileActivity> _load() async {
    final results = await Future.wait([
      widget.storage.history(),
      widget.storage.favorites(),
    ]);
    return ProfileActivity.from(history: results[0], favorites: results[1]);
  }

  @override
  void didUpdateWidget(ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A build always follows, so no setState.
    if (oldWidget.refreshToken != widget.refreshToken) _activity = _load();
  }

  void _open(WidgetBuilder builder) => Navigator.of(
    context,
  ).push(AppPageRoute<void>(context: context, builder: builder));

  void _openAccount() => _open(
    // A Scaffold, as Settings opens it: the page needs a Material above it.
    (context) => Scaffold(
      backgroundColor: GlassTheme.background,
      body: AccountSettingsScreen(
        account: _account,
        onBack: () => Navigator.of(context).pop(),
      ),
    ),
  );

  Future<void> _signOut() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Sign out?'),
            content: const Text(
              'Your library and settings stay on this device. Sign in again '
              'with Trakt to come back.',
            ),
            actions: [
              TextButton(
                // The safe choice is focused, so Select never signs out by
                // accident on a TV.
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    // The sign-in screen replaces the app once the session has ended.
    await _account.signOut();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_account, _profile]),
    builder: (context, _) {
      final signedIn = _account.status == AccountStatus.signedIn;
      return SettingsPage(
        title: 'Profile',
        subtitle: 'Your account, library and preferences.',
        onBack: widget.onBack,
        footer: null,
        children: !signedIn
            ? const [_SignedOut()]
            : [
                _ProfileHero(
                  displayName: _profile.displayName,
                  username: _account.username,
                  account: _account,
                  profile: _profile,
                  onEdit: _openAccount,
                  activity: FutureBuilder<ProfileActivity>(
                    future: _activity,
                    builder: (context, snapshot) => _ActivityRow(
                      activity: snapshot.data,
                      failed: snapshot.hasError,
                      onOpen: widget.onOpenLibrary,
                    ),
                  ),
                ),
                if (widget.onOpenLibrary != null)
                  SettingsSection(
                    label: 'LIBRARY',
                    children: [
                      SettingsTile(
                        icon: Symbols.bookmark_rounded,
                        title: 'Open my library',
                        description: 'Continue watching, My list and history',
                        onTap: widget.onOpenLibrary,
                      ),
                    ],
                  ),
                SettingsSection(
                  label: 'WATCH TOGETHER',
                  children: [
                    SettingsTile(
                      icon: Symbols.groups_rounded,
                      title: 'Join a watch party',
                      description: 'Enter a code to watch in sync with friends',
                      onTap: () => _open((_) => const JoinPartyScreen()),
                    ),
                  ],
                ),
                SettingsSection(
                  label: 'ACCOUNT',
                  children: [
                    SettingsTile(
                      icon: Symbols.manage_accounts_rounded,
                      title: 'Profile and account',
                      description:
                          'Name, avatar, Trakt sync, devices and account '
                          'deletion',
                      onTap: _openAccount,
                    ),
                    if (widget.onOpenSettings != null)
                      SettingsTile(
                        icon: Symbols.settings_rounded,
                        title: 'Settings',
                        description: 'Appearance, notifications and playback',
                        onTap: widget.onOpenSettings,
                      ),
                    SettingsTile(
                      icon: Symbols.shield_rounded,
                      title: 'Privacy policy',
                      description:
                          'What stays on your device and what is sent to '
                          'services',
                      onTap: () => _open(
                        (_) => const LegalInformationScreen(
                          document: LegalDocument.privacy,
                        ),
                      ),
                    ),
                    _SignOutTile(onTap: _signOut),
                  ],
                ),
              ],
      );
    },
  );
}

/// Who is signed in, in one card: the avatar with an accent ring, the name,
/// the Trakt account and Edit profile, with their activity along the foot.
/// Without a display name the Trakt username is the name, shown once, and
/// a line suggests adding one (friends see it in watch parties).
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.displayName,
    required this.username,
    required this.account,
    required this.profile,
    required this.onEdit,
    required this.activity,
  });

  final String? displayName;
  final String? username;
  final AccountController account;
  final ProfileController profile;
  final VoidCallback onEdit;
  final Widget activity;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final name = displayName ?? username ?? 'Reelish';
    // In line with the sections below (the page gives the side margins).
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpace.xs,
        bottom: SettingsMetrics.sectionGap,
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SettingsMetrics.sectionRadius),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
          // The accent glows from behind the avatar into the card's surface.
          gradient: RadialGradient(
            center: const Alignment(-.8, -.85),
            radius: 1.1,
            colors: [
              accent.withValues(alpha: .24),
              const Color(0xFF17171E),
              const Color(0xFF121218),
            ],
            stops: const [0, .5, 1],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 360;
                  final size = compact ? 68.0 : 88.0;
                  return Row(
                    children: [
                      // The ring sets the avatar off the glow behind it.
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: accent.withValues(alpha: .7),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: .28),
                              blurRadius: 24,
                            ),
                          ],
                        ),
                        child: MyProfileAvatar(
                          size: size,
                          account: account,
                          profile: profile,
                        ),
                      ),
                      SizedBox(width: compact ? AppSpace.md : AppSpace.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              // A username has no spaces to wrap at: one
                              // line, shortened, rather than split mid-word.
                              maxLines: displayName == null ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact
                                    ? AppTextSize.titleLarge
                                    : AppTextSize.headline,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.3,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: AppSpace.xs),
                            // Trakt usernames often repeat the person's name,
                            // so the badge names the service, not the user.
                            const _TraktBadge(),
                            const SizedBox(height: AppSpace.sm),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: accent.withValues(alpha: .16),
                                foregroundColor: GlassTheme.coralBright,
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: onEdit,
                              icon: const Icon(Symbols.edit_rounded, size: 18),
                              label: const Text(
                                'Edit profile',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (displayName == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Row(
                  children: [
                    Icon(Symbols.badge_rounded, size: 18, color: accent),
                    const SizedBox(width: AppSpace.sm),
                    const Expanded(
                      child: Text(
                        'Add a display name so friends recognise you in '
                        'watch parties.',
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontSize: AppTextSize.label,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, color: Colors.white.withValues(alpha: .07)),
            activity,
          ],
        ),
      ),
    );
  }
}

/// The account behind the profile: signed in with Trakt. The username
/// itself is on the Profile and account page.
class _TraktBadge extends StatelessWidget {
  const _TraktBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      border: Border.all(color: Colors.white.withValues(alpha: .1)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Symbols.verified_rounded,
          size: 14,
          fill: 1,
          color: GlassTheme.muted,
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            'Signed in with Trakt',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// My list, watched and in progress, counted from this device; each opens
/// the library.
class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.activity,
    required this.failed,
    required this.onOpen,
  });

  final ProfileActivity? activity;
  final bool failed;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.md),
        child: Text(
          'Your library could not be read on this device.',
          style: TextStyle(color: GlassTheme.muted),
        ),
      );
    }
    final activity = this.activity;
    if (activity == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: GlassTheme.primary,
            ),
          ),
        ),
      );
    }
    final stats = [
      (activity.myList, 'On My list', Symbols.favorite_rounded),
      (activity.watched, 'Watched', Symbols.history_rounded),
      (activity.inProgress, 'In progress', Symbols.play_circle_rounded),
    ];
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xs),
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              children: [
                for (final (index, (count, label, icon)) in stats.indexed) ...[
                  // Thin rules between the three, as on a scoreboard.
                  if (index > 0)
                    VerticalDivider(
                      width: 1,
                      indent: AppSpace.md,
                      endIndent: AppSpace.md,
                      color: Colors.white.withValues(alpha: .07),
                    ),
                  Expanded(
                    child: _Stat(
                      count: count,
                      label: label,
                      icon: icon,
                      onTap: onOpen,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (activity.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpace.md,
                0,
                AppSpace.md,
                AppSpace.md,
              ),
              child: Text(
                'Titles you watch and add to My list show up here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.count,
    required this.label,
    required this.icon,
    this.onTap,
  });

  final int count;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$count $label',
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: AppTextSize.headline,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: GlassTheme.muted),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      fontSize: AppTextSize.label,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Sign out, in the danger colour; it asks first.
class _SignOutTile extends StatelessWidget {
  const _SignOutTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: GlassTheme.danger.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(
              Symbols.logout_rounded,
              color: GlassTheme.danger,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          const Expanded(
            child: Text(
              'Sign out',
              style: TextStyle(
                color: GlassTheme.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Only seen for a moment: the sign-in screen replaces the app when no one
/// is signed in.
class _SignedOut extends StatelessWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpace.xl),
    child: Column(
      children: [
        ProfileAvatarView(avatar: ProfileAvatar.initials(), name: '', size: 72),
        SizedBox(height: AppSpace.md),
        Text(
          'Sign in with Trakt to see your profile, sync My list and join '
          'watch parties.',
          textAlign: TextAlign.center,
          style: TextStyle(color: GlassTheme.muted),
        ),
      ],
    ),
  );
}
