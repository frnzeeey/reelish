// The signed-in person's page, in three parts: who they are (avatar, name,
// badges, their viewing at a glance), how Reelish looks for them (avatar, app
// theme, app icon) and their account. It is not a menu: Library, Settings and
// Watch Party are one step away in the main navigation, so they are not listed
// here again; the counts open the library, since that is where those titles
// are. Phones stack the parts; TV and Windows put the identity beside the rest.

import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/reelish_icons.dart';

import '../account/account_controller.dart';
import '../account/profile_controller.dart';
import '../account/account_badges.dart';
import '../account/supporter_controller.dart';
import '../models/media_item.dart';
import '../navigation/app_transitions.dart';
import '../platform/app_icon.dart';
import '../platform/device_capabilities.dart';
import '../services/accent_settings_controller.dart';
import '../services/storage_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/supporter_themes.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/profile_avatar_picker.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/account_badges.dart';
import 'account_settings_screen.dart';
import 'app_icon_settings_screen.dart';
import 'playback_settings_screen.dart';
import 'supporters_screen.dart';

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
    this.refreshToken = 0,
    this.account,
    this.profile,
    this.badges,
    this.appearance,
  });

  final StorageService storage;

  /// Shown as Back when the page was opened over another (phone).
  final VoidCallback? onBack;

  /// Opens the library where the interface keeps it, from the counts.
  final VoidCallback? onOpenLibrary;

  /// A change re-reads the activity (the page stays built in TV and
  /// Windows navigation).
  final int refreshToken;
  final AccountController? account;

  /// [AccountBadges.instance] when null.
  final AccountBadges? badges;
  final ProfileController? profile;

  /// The app's look: its theme, when one applies, dresses the identity card,
  /// and Personalize opens its settings. Without it those are left out.
  final AccentSettingsController? appearance;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<ProfileActivity> _activity = _load();

  AccountController get _account =>
      widget.account ?? AccountController.instance;
  ProfileController get _profile =>
      widget.profile ?? ProfileController.instance;
  late final AccountBadges _badges = widget.badges ?? AccountBadges.instance;

  /// The entitlement, for the membership tile: the appearance's when given
  /// (the same instance the app uses), else the app's.
  SupporterController get _supporters =>
      widget.appearance?.supporters ?? SupporterController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_badges.refresh());
  }

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

  /// Opens a page over this one, in a Scaffold as Settings opens them: the
  /// page needs a Material above it.
  void _open(Widget Function(VoidCallback back) page) => unawaited(
    Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (context) => Scaffold(
          backgroundColor: GlassTheme.background,
          body: page(() => Navigator.of(context).pop()),
        ),
      ),
    ),
  );

  void _openAccount() =>
      _open((back) => AccountSettingsScreen(account: _account, onBack: back));

  void _openAppearance(AccentSettingsController appearance) => _open(
    (back) => AppearanceSettingsScreen(controller: appearance, onBack: back),
  );

  void _openAppIcon() => _open((back) => AppIconSettingsScreen(onBack: back));

  void _openSupporters() => unawaited(
    Navigator.of(context).push(
      AppPageRoute<void>(
        context: context,
        builder: (_) => SupportersScreen(controller: _supporters),
      ),
    ),
  );

  /// The avatar choices in place: a sheet on phones, a dialog where there is
  /// a remote or a mouse. A choice saves at once.
  Future<void> _chooseAvatar() async {
    Widget picker(BuildContext context, {bool heading = true}) =>
        ListenableBuilder(
          listenable: Listenable.merge([_profile, _account]),
          builder: (context, _) => ProfileAvatarPicker(
            profile: _profile,
            name: _profile.nameOr(_account.username),
            enabled: true,
            traktUrl: _account.traktAvatarUrl,
            showHeading: heading,
          ),
        );
    final more = DeviceCapabilities.isTv
        ? 'Name and more'
        : 'Name, photo and more';
    final openAccount = DeviceCapabilities.usesTvLayout
        ? await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Avatar'),
              contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              content: SizedBox(
                width: 520,
                child: picker(context, heading: false),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(more),
                ),
                FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Done'),
                ),
              ],
            ),
          )
        : await showModalBottomSheet<bool>(
            context: context,
            backgroundColor: Colors.transparent,
            useSafeArea: true,
            isScrollControlled: true,
            builder: (context) => _Sheet(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  picker(context),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                    ),
                    child: TextButton.icon(
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(ReelishIcons.manageAccounts, size: 18),
                      label: Text(more),
                    ),
                  ),
                ],
              ),
            ),
          );
    if (openAccount == true && mounted) _openAccount();
  }

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

  String _avatarLabel() {
    final avatar = _profile.avatar;
    return switch (avatar.kind) {
      AvatarKind.trakt when _account.traktAvatarUrl != null => 'Trakt picture',
      AvatarKind.photo => 'Your photo',
      AvatarKind.preset =>
        AvatarPreset.byId(avatar.presetId)?.label ?? 'Initial',
      _ => 'Initial',
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _account,
      _profile,
      _supporters,
      ?widget.appearance,
    ]),
    builder: (context, _) {
      final signedIn = _account.status == AccountStatus.signedIn;
      if (!signedIn) {
        return SettingsPage(
          title: 'Profile',
          onBack: widget.onBack,
          footer: null,
          children: const [_SignedOut()],
        );
      }
      final appearance = widget.appearance;
      final identity = _IdentityCard(
        displayName: _profile.displayName,
        username: _account.username,
        account: _account,
        profile: _profile,
        badges: _badges,
        theme: appearance?.theme,
        onChangeAvatar: () => unawaited(_chooseAvatar()),
        activity: FutureBuilder<ProfileActivity>(
          future: _activity,
          builder: (context, snapshot) => _ActivityRow(
            // The counts take the theme's light inside its card.
            color: appearance?.theme?.ink,
            activity: snapshot.data,
            failed: snapshot.hasError,
            onOpen: widget.onOpenLibrary,
          ),
        ),
      );
      final sections = [
        SettingsSection(
          label: 'PERSONALIZE',
          children: [
            SettingsTile(
              icon: ReelishIcons.face,
              title: 'Avatar',
              value: _avatarLabel(),
              onTap: () => unawaited(_chooseAvatar()),
            ),
            if (appearance != null)
              SettingsTile(
                icon: ReelishIcons.palette,
                title: 'Theme',
                value: appearance.theme?.name ?? appearance.accent.label,
                description: appearance.theme == null
                    ? (_supporters.has(SupporterPerk.appThemes)
                          ? 'Your accent; a theme sets one for you'
                          : 'Your accent color')
                    : 'Sets the accent and this card',
                onTap: () => _openAppearance(appearance),
              ),
            // Android phones and tablets only (see AppIconService).
            if (AppIconService.supported)
              SettingsTile(
                icon: ReelishIcons.grid,
                title: 'App icon',
                description: 'The icon on your home screen',
                onTap: _openAppIcon,
              ),
          ],
        ),
        SettingsSection(
          label: 'MEMBERSHIP',
          children: [
            _MembershipTile(
              entitlement: _supporters.entitlement,
              onTap: _openSupporters,
            ),
          ],
        ),
        SettingsSection(
          label: 'ACCOUNT',
          children: [
            SettingsTile(
              icon: ReelishIcons.manageAccounts,
              title: 'Manage account',
              description: 'Display name, photo, Trakt sync and devices',
              onTap: _openAccount,
            ),
            _SignOutTile(onTap: _signOut),
          ],
        ),
      ];
      return SettingsPage(
        title: 'Profile',
        subtitle: 'Who you are, how Reelish looks, and your account.',
        onBack: widget.onBack,
        footer: null,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // TV and Windows: the identity beside the rest, not a phone
              // layout stretched across the screen.
              final wide =
                  DeviceCapabilities.usesTvLayout &&
                  constraints.maxWidth >= 720;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [identity, ...sections],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: constraints.maxWidth * .42, child: identity),
                  const SizedBox(width: AppSpace.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: sections,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      );
    },
  );
}

/// A bottom sheet's surface, as the app's other sheets draw it.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      side: BorderSide(color: GlassTheme.border),
    ),
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: AppSpace.sm, bottom: AppSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    ),
  );
}

/// Who is signed in, centred in one card: a large avatar with a button to
/// change it, the name, the Founder's title, the account's badges, and their
/// viewing along the foot. Without a display name the Trakt username is the
/// name, shown once, and a line suggests adding one (friends see it in watch
/// parties). An app theme dresses the card.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.displayName,
    required this.username,
    required this.account,
    required this.profile,
    required this.badges,
    required this.theme,
    required this.onChangeAvatar,
    required this.activity,
  });

  final String? displayName;
  final String? username;
  final AccountController account;
  final ProfileController profile;
  final AccountBadges badges;

  /// The app theme, when one applies.
  final SupporterTheme? theme;
  final VoidCallback onChangeAvatar;
  final Widget activity;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final theme = this.theme;
    final tv = DeviceCapabilities.isTv;
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
          color: const Color(0xFF121218),
          borderRadius: BorderRadius.circular(SettingsMetrics.sectionRadius),
          border: Border.all(
            color: theme == null
                ? Colors.white.withValues(alpha: .08)
                : theme.glow.withValues(alpha: .32),
          ),
        ),
        child: Stack(
          children: [
            // One backdrop fades into the next when the theme changes.
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.emphasized),
                child: theme == null
                    ? DecoratedBox(
                        key: const ValueKey('classic'),
                        // The accent glows from behind the avatar.
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0, -.75),
                            radius: 1.1,
                            colors: [
                              accent.withValues(alpha: .26),
                              const Color(0xFF17171E),
                              const Color(0xFF121218),
                            ],
                            stops: const [0, .5, 1],
                          ),
                        ),
                      )
                    : SupporterThemeBackdrop(
                        key: ValueKey(theme.id),
                        theme: theme,
                      ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.xl,
                    AppSpace.lg,
                    AppSpace.lg,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 300;
                      final size = tv
                          ? 120.0
                          : compact
                          ? 88.0
                          : 108.0;
                      return Column(
                        children: [
                          _EditableAvatar(
                            size: size,
                            theme: theme,
                            account: account,
                            profile: profile,
                            onChange: onChangeAvatar,
                          ),
                          const SizedBox(height: AppSpace.md),
                          ListenableBuilder(
                            listenable: badges,
                            builder: (context, _) => _ProfileName(
                              name: name,
                              // A username has no spaces to wrap at: one
                              // line, shortened, rather than split mid-word.
                              maxLines: displayName == null ? 1 : 2,
                              compact: compact,
                              founder: badges.has(AccountBadge.founder),
                            ),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          // Trakt usernames often repeat the person's name,
                          // so the badge names the service, not the user.
                          // Badges arrive from the server after the first
                          // frame; the pills follow them.
                          ListenableBuilder(
                            listenable: badges,
                            builder: (context, _) => Wrap(
                              alignment: WrapAlignment.center,
                              spacing: AppSpace.xs,
                              runSpacing: AppSpace.xs,
                              children: [
                                const _TraktBadge(),
                                ..._badgePills(context, tv),
                              ],
                            ),
                          ),
                          if (displayName == null) ...[
                            const SizedBox(height: AppSpace.md),
                            Text(
                              'Add a display name so friends recognise you in '
                              'watch parties.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: tv
                                    ? AppTextSize.body
                                    : AppTextSize.label,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: .07)),
                activity,
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The account's badges, and nothing for an account with none. A
  /// supporter's opens the Supporters page.
  List<Widget> _badgePills(BuildContext context, bool tv) => [
    if (badges.has(AccountBadge.founder)) FounderBadge(tv: tv),
    if (badges.has(AccountBadge.supporter))
      SupporterBadge(
        tv: tv,
        onTap: () => unawaited(
          Navigator.push(
            context,
            AppPageRoute<void>(
              context: context,
              builder: (_) => const SupportersScreen(),
            ),
          ),
        ),
      ),
  ];
}

/// The avatar, large, in the theme's frame or an accent ring, with a small
/// button on it to change it.
class _EditableAvatar extends StatelessWidget {
  const _EditableAvatar({
    required this.size,
    required this.theme,
    required this.account,
    required this.profile,
    required this.onChange,
  });

  final double size;
  final SupporterTheme? theme;
  final AccountController account;
  final ProfileController profile;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    final accent = GlassTheme.primary;
    final avatar = MyProfileAvatar(
      size: size,
      account: account,
      profile: profile,
    );
    final framed = theme != null
        ? SupporterAvatarRing(theme: theme, child: avatar)
        : Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: accent.withValues(alpha: .7), width: 2),
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: .28), blurRadius: 28),
              ],
            ),
            child: avatar,
          );
    final button = DeviceCapabilities.isTv ? 44.0 : 36.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        framed,
        Positioned(
          right: -2,
          bottom: -2,
          child: SizedBox.square(
            dimension: button,
            child: IconButton.filled(
              tooltip: 'Change avatar',
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: GlassTheme.elevatedSurface,
                foregroundColor: theme?.ink ?? GlassTheme.coralBright,
                side: const BorderSide(color: GlassTheme.border),
              ),
              onPressed: onChange,
              icon: Icon(ReelishIcons.edit, size: button * .46),
            ),
          ),
        ),
      ],
    );
  }
}

/// The name, centred, with the Founder's crown beside it and title below.
/// The title reads as part of who they are, so it sits with the name rather
/// than among the badges.
class _ProfileName extends StatelessWidget {
  const _ProfileName({
    required this.name,
    required this.maxLines,
    required this.compact,
    required this.founder,
  });

  final String name;
  final int maxLines;
  final bool compact;
  final bool founder;

  @override
  Widget build(BuildContext context) {
    final size = DeviceCapabilities.isTv
        ? AppTextSize.display
        : compact
        ? AppTextSize.titleLarge
        : AppTextSize.headline;
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.3,
                  height: 1.15,
                ),
              ),
            ),
            if (founder) ...[
              const SizedBox(width: AppSpace.xs),
              Tooltip(
                message: FounderBadge.description,
                child: FounderEmblem(size: size * .9),
              ),
            ],
          ],
        ),
        if (founder) ...[
          const SizedBox(height: AppSpace.xxs),
          Text(
            FounderBadge.title,
            style: TextStyle(
              color: FounderBadge.ink,
              fontSize: DeviceCapabilities.isTv
                  ? AppTextSize.body
                  : AppTextSize.bodySmall,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

/// The account's place among Reelish's supporters: what it has, and the way
/// to the Supporters page. One quiet tile, never a banner.
class _MembershipTile extends StatelessWidget {
  const _MembershipTile({required this.entitlement, required this.onTap});

  final Entitlement entitlement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => switch (entitlement) {
    Entitlement.founder => SettingsTile(
      icon: ReelishIcons.founder,
      title: 'Founder',
      description: 'Every Supporter perk is yours, now and as new ones arrive',
      onTap: onTap,
    ),
    Entitlement.supporter => SettingsTile(
      icon: ReelishIcons.supporter,
      title: 'Supporter perks',
      description:
          'App themes, every app icon and hosting Watch Parties. '
          'Thank you.',
      onTap: onTap,
    ),
    Entitlement.free => SettingsTile(
      icon: ReelishIcons.heart,
      title: 'Reelish Supporters',
      description:
          'Support Reelish for app themes, every app icon and '
          'hosting Watch Parties',
      onTap: onTap,
    ),
  };
}

/// The account behind the profile: signed in with Trakt. The username
/// itself is on the account page.
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
        Icon(
          ReelishIcons.verifiedFilled,
          size: DeviceCapabilities.isTv ? 18 : 14,
          color: GlassTheme.muted,
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            'Signed in with Trakt',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: DeviceCapabilities.isTv
                  ? AppTextSize.body
                  : AppTextSize.label,
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
    this.color,
  });

  /// The counts' colour; the accent when null.
  final Color? color;
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
              color: color ?? GlassTheme.primary,
            ),
          ),
        ),
      );
    }
    final stats = [
      (activity.myList, 'On My list', ReelishIcons.heart),
      (activity.watched, 'Watched', ReelishIcons.history),
      (activity.inProgress, 'In progress', ReelishIcons.playCircle),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcons = constraints.maxWidth / 3 >= 100;
        return Padding(
          padding: const EdgeInsets.all(AppSpace.xs),
          child: Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  children: [
                    for (final (index, (count, label, icon))
                        in stats.indexed) ...[
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
                          showIcon: showIcons,
                          color: color ?? GlassTheme.primary,
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
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    this.showIcon = true,
    required this.color,
    required this.count,
    required this.label,
    required this.icon,
    this.onTap,
  });

  final bool showIcon;
  final Color color;
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
                color: color,
                fontSize: AppTextSize.headline,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // On a narrow phone the label keeps its room; the icon goes.
                if (showIcon) ...[
                  Icon(icon, size: 14, color: GlassTheme.muted),
                  const SizedBox(width: 5),
                ],
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
              ReelishIcons.logout,
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
