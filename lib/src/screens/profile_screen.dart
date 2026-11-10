// The signed-in person's page, in three parts: who they are (avatar, name,
// badges, and apart from those their viewing at a glance), how Reelish looks
// for them (avatar frame, app theme, app icon) and their account. It is not a menu: Library, Settings and
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
import '../account/avatar_frames.dart';
import '../theme/avatar_frames.dart';
import '../widgets/avatar_frame.dart';
import '../widgets/profile_avatar_picker.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/account_badges.dart';
import 'account_settings_screen.dart';
import 'app_icon_settings_screen.dart';
import 'avatar_frames_screen.dart';
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
    this.frames,
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

  /// The account's avatar frames; [AvatarFrames.instance] when null.
  final AvatarFrames? frames;
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
  late final AvatarFrames _frames = widget.frames ?? AvatarFrames.instance;

  /// The entitlement, for the membership tile: the appearance's when given
  /// (the same instance the app uses), else the app's.
  SupporterController get _supporters =>
      widget.appearance?.supporters ?? SupporterController.instance;

  @override
  void initState() {
    super.initState();
    // Both read GET /me, so they share one request.
    unawaited(_badges.refresh());
    unawaited(_frames.refresh());
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

  void _openFrames() => _open(
    (back) => AvatarFramesScreen(
      onBack: back,
      frames: _frames,
      supporters: _supporters,
      account: _account,
      profile: _profile,
    ),
  );

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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _account,
      _profile,
      _supporters,
      _frames,
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
      Widget identity({bool wide = false}) => _IdentityCard(
        wide: wide,
        displayName: _profile.displayName,
        username: _account.username,
        account: _account,
        profile: _profile,
        badges: _badges,
        theme: appearance?.theme,
        frame: AvatarFrameStyle.byId(_frames.equipped),
        onChangeAvatar: () => unawaited(_chooseAvatar()),
        onAddName: _openAccount,
        onOpenSupporters: _openSupporters,
        activity: _activity,
        onOpenLibrary: widget.onOpenLibrary,
      );
      final personalize = <Widget>[
        SettingsTile(
          icon: ReelishIcons.face,
          title: 'Avatar frame',
          value: AvatarFrameStyle.byId(_frames.equipped)?.name ?? 'None',
          onTap: _openFrames,
        ),
        if (appearance != null)
          SettingsTile(
            icon: ReelishIcons.palette,
            title: 'Theme',
            value: appearance.theme?.name ?? appearance.accent.label,
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
      ];
      final sections = [
        if (personalize.isNotEmpty)
          SettingsSection(label: 'PERSONALIZE', children: personalize),
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
                  children: [identity(), ...sections],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identity(wide: true),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (index, section) in sections.indexed) ...[
                        if (index > 0) const SizedBox(width: AppSpace.lg),
                        Expanded(child: section),
                      ],
                    ],
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
    shape: RoundedRectangleBorder(
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
                  color: GlassTheme.textPrimary.withValues(alpha: .24),
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

/// Who is signed in, in the card that leads the page. Identity first: a large
/// avatar with a button to change it, the name, the account it signs in with
/// and its badges. Their viewing is set apart from it: along the card's foot,
/// or beside the identity where a wide card has room. Without a display name
/// the Trakt username is the name, shown once, and a line suggests adding one
/// (friends see it in watch parties). An app theme dresses the card.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.displayName,
    required this.username,
    required this.account,
    required this.profile,
    required this.badges,
    required this.theme,
    this.frame,
    required this.onChangeAvatar,
    required this.onAddName,
    required this.onOpenSupporters,
    required this.activity,
    this.onOpenLibrary,
    this.wide = false,
  });

  final String? displayName;
  final String? username;
  final AccountController account;
  final ProfileController profile;
  final AccountBadges badges;

  /// The app theme, when one applies.
  final SupporterTheme? theme;

  /// The avatar frame the account wears, if any (AvatarFrames).
  final AvatarFrameStyle? frame;
  final VoidCallback onChangeAvatar;

  /// Opens the account page, where the display name is set.
  final VoidCallback onAddName;
  final VoidCallback onOpenSupporters;

  /// The library counts, read from this device.
  final Future<ProfileActivity> activity;

  /// Opens the library, from a count.
  final VoidCallback? onOpenLibrary;

  /// Across the page (TV and Windows): the avatar beside the name. Stacked
  /// and centred otherwise.
  final bool wide;

  /// From this width a wide Windows card puts the counts beside the
  /// identity, where the name still has room; narrower, and on TV, they run
  /// along its foot.
  static const _countsBesideWidth = 760.0;

  bool get _laurel => frame?.ornament == FrameOrnament.laurel;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final theme = this.theme;
    final tv = DeviceCapabilities.isTv;
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
            _onCard(
              FutureBuilder<ProfileActivity>(
                future: activity,
                builder: (context, snapshot) {
                  final counts = _Counts(
                    activity: snapshot.data,
                    failed: snapshot.hasError,
                    // The counts take the theme's light inside its card.
                    color: theme?.ink ?? accent,
                    onOpen: onOpenLibrary,
                  );
                  return wide ? _across(tv, counts) : _stacked(tv, counts);
                },
              ),
              tv,
            ),
          ],
        ),
      ),
    );
  }

  /// The card stays dark in every theme. On a light theme, whose page text
  /// and accent are dark, its content takes the dark colours the player
  /// uses (GlassTheme.player), so the name, captions and buttons read.
  static Widget _onCard(Widget child, bool tv) {
    if (!GlassTheme.isLight) return child;
    final dark = GlassTheme.playerSurfaces;
    return Theme(
      data: GlassTheme.player(tv: tv),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: dark.textPrimary),
        child: IconTheme.merge(
          data: IconThemeData(color: dark.textPrimary),
          child: child,
        ),
      ),
    );
  }

  Widget _avatar(double size) => _EditableAvatar(
    size: size,
    theme: theme,
    frame: frame,
    account: account,
    profile: profile,
    onChange: onChangeAvatar,
  );

  /// The name, the account it signs in with and its badges, then, without a
  /// display name, the prompt to add one.
  Widget _identity(
    bool tv, {
    required bool compact,
    required bool start,
    bool large = false,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: start
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      ListenableBuilder(
        listenable: badges,
        builder: (context, _) => _ProfileName(
          name: displayName ?? username ?? 'Reelish',
          // A username has no spaces to wrap at: one line, shortened,
          // rather than split mid-word.
          maxLines: displayName == null ? 1 : 2,
          compact: compact,
          large: large,
          alignStart: start,
          founder: badges.has(AccountBadge.founder),
          supporter: badges.has(AccountBadge.supporter),
          sovereign: theme?.collection == ThemeCollection.founder,
          onOpenSupporters: onOpenSupporters,
        ),
      ),
      if (displayName == null) ...[
        const SizedBox(height: AppSpace.xs),
        _addName(tv, start: start),
      ],
    ],
  );

  /// Without a name of their own, the prompt is also the way to set one. The
  /// action is in the theme's light and the reason quiet, so the whole line
  /// reads as an invitation, not an error.
  Widget _addName(bool tv, {required bool start}) => Builder(
    builder: (context) => TextButton(
      onPressed: onAddName,
      style: TextButton.styleFrom(
        alignment: start ? Alignment.centerLeft : Alignment.center,
        padding: start
            ? const EdgeInsets.symmetric(vertical: AppSpace.xs)
            : const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: AppSpace.xs,
              ),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'Add a display name',
              style: TextStyle(
                color: theme?.ink ?? Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: ' so friends recognise you in watch parties.',
              style: TextStyle(color: _onCardMuted),
            ),
          ],
        ),
        textAlign: start ? TextAlign.start : TextAlign.center,
        style: TextStyle(
          fontSize: tv ? AppTextSize.body : AppTextSize.label,
          fontWeight: FontWeight.w500,
          height: 1.4,
        ),
      ),
    ),
  );

  Widget _stacked(bool tv, _Counts counts) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        // Narrower sides on a phone, so a long name keeps its room.
        padding: EdgeInsets.fromLTRB(
          tv ? AppSpace.lg : AppSpace.md,
          AppSpace.xl,
          tv ? AppSpace.lg : AppSpace.md,
          AppSpace.lg,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 250;
            return Column(
              children: [
                _avatar(
                  tv
                      ? 120.0
                      : compact
                      ? 84.0
                      : 100.0,
                ),
                // The edit button sits below the Founder's frame.
                SizedBox(height: _laurel ? AppSpace.md + 14 : AppSpace.md),
                _identity(tv, compact: compact, start: false),
              ],
            );
          },
        ),
      ),
      _CountsFoot(counts: counts),
    ],
  );

  Widget _across(bool tv, _Counts counts) => LayoutBuilder(
    builder: (context, constraints) {
      final beside = !tv && constraints.maxWidth >= _countsBesideWidth;
      final note = counts.note;
      final identity = Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Row(
          children: [
            _avatar(tv ? 120 : 112),
            const SizedBox(width: AppSpace.xl),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _identity(tv, compact: false, start: true, large: true),
                  // An empty or unreadable library: its line sits with the
                  // name, not in a column of its own.
                  if (beside && note != null) ...[
                    const SizedBox(height: AppSpace.md),
                    _CountsNote(note, start: true),
                  ],
                ],
              ),
            ),
            if (beside && counts.shown) ...[
              const SizedBox(width: AppSpace.lg),
              _CountsBeside(counts: counts),
            ],
          ],
        ),
      );
      if (beside) return identity;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          identity,
          _CountsFoot(counts: counts),
        ],
      );
    },
  );
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
    this.frame,
  });

  final double size;
  final SupporterTheme? theme;
  final AccountController account;
  final ProfileController profile;
  final VoidCallback onChange;

  /// The avatar frame the account wears, in place of the theme's ring.
  final AvatarFrameStyle? frame;

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    final accent = GlassTheme.primary;
    final avatar = MyProfileAvatar(
      size: size,
      account: account,
      profile: profile,
    );
    final frame = this.frame;
    // The Sovereign frame's laurel meets at the foot, where the button sits.
    final atFoot = frame?.ornament == FrameOrnament.laurel;
    final framed = frame != null
        ? AvatarFrame(style: frame, size: size, child: avatar)
        : theme != null
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
    final visual = DeviceCapabilities.isTv ? 38.0 : 30.0;
    final fill = atFoot
        ? FounderRingColors.platinum
        : theme?.ink ?? GlassTheme.coralBright;
    // The tap target is 48 or more around the smaller disc, and the disc is
    // ringed in the card's colour so it reads as cut out of the frame.
    const target = 48.0;
    final offset = (target - visual) / 2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        framed,
        Positioned(
          // In the Founder's frame the button sits in the gap at the foot of
          // the laurel, where the branches meet; elsewhere at the lower right.
          left: atFoot ? 0 : null,
          right: atFoot ? 0 : -offset,
          bottom: atFoot ? -target / 2 : -offset,
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: SizedBox.square(
              dimension: target,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .9),
                      width: 1.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: IconButton.filled(
                    tooltip: 'Change avatar',
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      fixedSize: Size.square(visual),
                      minimumSize: Size.square(visual),
                      tapTargetSize: MaterialTapTargetSize.padded,
                      backgroundColor: fill,
                      foregroundColor: const Color(0xFF101015),
                    ),
                    onPressed: onChange,
                    icon: Icon(ReelishIcons.edit, size: visual * .48),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The name, and close under it the account it signs in with, so the two read
/// as one; then the account's identity capsules, Sovereign and Supporter,
/// each of which opens the Supporters page.
class _ProfileName extends StatelessWidget {
  const _ProfileName({
    required this.name,
    required this.maxLines,
    required this.compact,
    required this.founder,
    required this.supporter,
    required this.onOpenSupporters,
    this.alignStart = false,
    this.large = false,
    this.sovereign = false,
  });

  final String name;
  final bool alignStart;
  final int maxLines;
  final bool compact;

  /// Beside the avatar on a wide card, where the name takes the display
  /// size to hold its own against the avatar.
  final bool large;
  final bool founder;
  final bool supporter;
  final VoidCallback onOpenSupporters;

  /// Sovereign Edition is on: the Founder badge takes its champagne finish.
  final bool sovereign;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final size = tv || large
        ? AppTextSize.display
        : compact
        ? AppTextSize.titleLarge
        : AppTextSize.headline;
    final capsules = [
      if (founder)
        FounderBadge(tv: tv, sovereign: sovereign, onTap: onOpenSupporters),
      if (supporter)
        SupporterBadge(tv: tv, short: true, onTap: onOpenSupporters),
    ];
    return Column(
      crossAxisAlignment: alignStart
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          name,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: alignStart ? TextAlign.start : TextAlign.center,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w800,
            letterSpacing: size >= AppTextSize.display ? -.5 : -.3,
            height: 1.15,
          ),
        ),
        const SizedBox(height: AppSpace.xxs),
        // Trakt usernames often repeat the person's name, so the line names
        // the service, not the user.
        const _TraktBadge(),
        if (capsules.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Wrap(
            alignment: alignStart ? WrapAlignment.start : WrapAlignment.center,
            spacing: AppSpace.xs,
            runSpacing: AppSpace.xs,
            children: capsules,
          ),
        ],
      ],
    );
  }
}

/// Quiet text on the identity card, which stays dark in every theme: the
/// page's caption colour on a dark theme, the dark card's on a light one.
Color get _onCardMuted => GlassTheme.isLight
    ? GlassTheme.playerSurfaces.textSecondary
    : GlassTheme.muted;

/// The account behind the profile, as a quiet line: signed in with Trakt.
/// The username itself is on the account page.
class _TraktBadge extends StatelessWidget {
  const _TraktBadge();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        ReelishIcons.verifiedFilled,
        size: DeviceCapabilities.isTv ? 18 : 14,
        color: _onCardMuted,
      ),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          'Signed in with Trakt',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _onCardMuted,
            fontSize: DeviceCapabilities.isTv
                ? AppTextSize.body
                : AppTextSize.label,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );
}

/// My list, watched and in progress, counted from this device, as the card
/// shows them: the counts, a line in their place (an empty library, or one
/// that could not be read), or nothing yet while they load.
@immutable
class _Counts {
  const _Counts({
    required this.activity,
    required this.failed,
    required this.color,
    this.onOpen,
  });

  final ProfileActivity? activity;
  final bool failed;

  /// The numbers' colour: the theme's light, or the accent.
  final Color color;
  final VoidCallback? onOpen;

  /// The counts themselves are shown: read, and not all zero.
  bool get shown => !failed && activity != null && !activity!.isEmpty;

  /// What the card says instead of the counts, or null.
  String? get note => failed
      ? 'Your library could not be read on this device.'
      : activity?.isEmpty ?? false
      ? 'Titles you watch and add to My list show up here.'
      : null;

  /// One per count, each opening the library; zeros while they load.
  List<Widget> stats({required double size}) {
    final activity =
        this.activity ??
        const ProfileActivity(myList: 0, watched: 0, inProgress: 0);
    return [
      _Stat(
        count: activity.watched,
        label: 'Watched',
        color: color,
        size: size,
        onTap: onOpen,
      ),
      _Stat(
        count: activity.inProgress,
        label: 'In progress',
        color: color,
        size: size,
        onTap: onOpen,
      ),
      _Stat(
        count: activity.myList,
        // "My list", as the library names it; read out in full.
        label: 'My list',
        spoken: 'On My list',
        color: color,
        size: size,
        onTap: onOpen,
      ),
    ];
  }
}

/// A quiet line on the card in place of the counts.
class _CountsNote extends StatelessWidget {
  const _CountsNote(this.text, {required this.start});

  final String text;
  final bool start;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: start ? TextAlign.start : TextAlign.center,
    style: TextStyle(
      color: _onCardMuted,
      fontSize: DeviceCapabilities.isTv ? AppTextSize.body : AppTextSize.label,
      height: 1.4,
    ),
  );
}

/// The counts along the card's foot, a band of their own under a hairline so
/// the viewing reads apart from the identity: three equal columns, a number
/// over its name. While they load the row keeps its place unseen, so nothing
/// moves when they arrive.
class _CountsFoot extends StatelessWidget {
  const _CountsFoot({required this.counts});

  final _Counts counts;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final note = counts.note;
    final Widget content;
    if (note != null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.md,
        ),
        child: _CountsNote(note, start: false),
      );
    } else {
      final stats = counts.stats(
        size: tv ? AppTextSize.headline : AppTextSize.titleLarge,
      );
      final row = Padding(
        padding: const EdgeInsets.all(AppSpace.xs),
        child: Row(
          children: [
            for (final (index, stat) in stats.indexed) ...[
              if (index > 0)
                Container(
                  width: 1,
                  height: tv ? 36 : 28,
                  color: Colors.white.withValues(alpha: .08),
                ),
              Expanded(child: stat),
            ],
          ],
        ),
      );
      content = counts.shown
          ? row
          : Visibility(
              visible: false,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: row,
            );
    }
    // The card stays dark in every theme, so the band is a deeper shade of
    // it rather than a page colour.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .18),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: .07)),
        ),
      ),
      // Above the band, so the counts' highlights show on it.
      child: Material(type: MaterialType.transparency, child: content),
    );
  }
}

/// The counts beside the identity on a wide Windows card, set off from it by
/// a hairline, where the card would otherwise stand empty.
class _CountsBeside extends StatelessWidget {
  const _CountsBeside({required this.counts});

  final _Counts counts;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 1,
        height: 72,
        color: Colors.white.withValues(alpha: .1),
      ),
      const SizedBox(width: AppSpace.sm),
      for (final stat in counts.stats(size: AppTextSize.headline))
        SizedBox(width: 96, child: stat),
    ],
  );
}

/// One count: the number in the card's light over its name. It opens the
/// library, and the remote or keyboard on it draws a ring.
class _Stat extends StatefulWidget {
  const _Stat({
    required this.count,
    required this.label,
    required this.color,
    required this.size,
    this.spoken,
    this.onTap,
  });

  final int count;
  final String label;

  /// What a screen reader says after the count; [label] when null.
  final String? spoken;
  final Color color;

  /// The number's font size.
  final double size;
  final VoidCallback? onTap;

  @override
  State<_Stat> createState() => _StatState();
}

class _StatState extends State<_Stat> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final radius = BorderRadius.circular(AppRadius.md);
    // A node of its own, with its own tap: excluding the InkWell's
    // semantics would otherwise drop the action and fold the count into
    // the rest of the page for a screen reader.
    return Semantics(
      container: true,
      button: widget.onTap != null,
      onTap: widget.onTap,
      label: '${widget.count} ${widget.spoken ?? widget.label}',
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (focused) => setState(() => _focused = focused),
        borderRadius: radius,
        focusColor: widget.color.withValues(alpha: .12),
        hoverColor: Colors.white.withValues(alpha: .05),
        child: AnimatedContainer(
          duration: AppMotion.resolve(context, AppMotion.hover),
          padding: EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: tv ? AppSpace.sm : AppSpace.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: widget.color.withValues(alpha: _focused ? .8 : 0),
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A long count shrinks rather than spill out of its column.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${widget.count}',
                  maxLines: 1,
                  style: TextStyle(
                    color: widget.color,
                    fontSize: widget.size,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3,
                    height: 1.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              // Whole on a narrow phone: it shrinks rather than cut short.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  style: TextStyle(
                    color: _onCardMuted,
                    fontSize: tv ? AppTextSize.body : AppTextSize.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sign out, in the danger colour; it asks first. One button for a screen
/// reader, as the settings tiles beside it are.
class _SignOutTile extends StatelessWidget {
  const _SignOutTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      MergeSemantics(child: Semantics(button: true, child: _tile()));

  Widget _tile() => InkWell(
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
  Widget build(BuildContext context) => Padding(
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
