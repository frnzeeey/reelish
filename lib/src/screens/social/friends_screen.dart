// Friends, the body of Together: your people as faces and a list, requests
// waiting both ways, messages, what friends sent, a friend's page and the
// people blocked (docs/features/together.md). Together and Friends opened from
// Profile are this one page on phone, TV and Windows; TV and Windows put
// movie night and what friends share beside the people. Every action is
// decided by the server (backend/src/social/friends.ts).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../account/account_api.dart';
import '../../account/account_controller.dart';
import '../../account/profile_controller.dart';
import '../../navigation/app_transitions.dart';
import '../../platform/device_capabilities.dart';
import '../../social/friends_controller.dart';
import '../../social/recommendations_controller.dart';
import '../../social/social_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/settings/settings_components.dart';
import '../../widgets/social/social_widgets.dart';
import '../../messaging/message_models.dart';
import '../../messaging/messages_controller.dart';
import 'conversation_options_screen.dart';
import 'friend_collection_screen.dart';
import 'friends_privacy_screen.dart';
import '../../connect/connect_screen.dart';
import 'messages_screen.dart';
import 'messages_split_view.dart';
import 'together_sections.dart';

/// Opens a page over the current one in a Scaffold, as Profile opens its
/// pages; [page] gets a Back callback.
void openSocialPage(
  BuildContext context,
  Widget Function(VoidCallback back) page,
) => unawaited(
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

/// Opens a conversation; its info button opens the friend's page, and its
/// options button the conversation's options.
void openChat(
  BuildContext context,
  Conversation conversation, {
  MessagesController? messages,
  FriendsController? friends,
}) => openSocialPage(
  context,
  (back) => ChatScreen(
    conversation: conversation,
    messages: messages,
    onBack: back,
    onOpenFriend: () => openSocialPage(
      context,
      (back) => FriendScreen(
        person: conversation.peer,
        friends: friends,
        messages: messages,
        fromChat: true,
        onBack: back,
      ),
    ),
    // Deleting the conversation leaves the chat too.
    onOpenOptions: () => openConversationOptions(
      context,
      conversation,
      messages: messages,
      afterDelete: back,
    ),
  ),
);

/// A conversation's options (nickname, mute, delete). From a list it also
/// links to the friend's page.
void openConversationOptions(
  BuildContext context,
  Conversation conversation, {
  MessagesController? messages,
  FriendsController? friends,
  bool withFriendPage = false,
  VoidCallback? afterDelete,
}) => openSocialPage(
  context,
  (back) => ConversationOptionsScreen(
    conversation: conversation,
    messages: messages,
    onBack: back,
    onOpenFriend: withFriendPage
        ? () => openSocialPage(
            context,
            (back) => FriendScreen(
              person: conversation.peer,
              friends: friends,
              messages: messages,
              onBack: back,
            ),
          )
        : null,
    onDeleted: () {
      back();
      afterDelete?.call();
    },
  ),
);

/// The conversation list. On Windows, with room for both, the chosen
/// conversation opens beside it ([MessagesSplitView]) rather than over it.
void openMessages(
  BuildContext context, {
  MessagesController? messages,
  FriendsController? friends,
}) => openSocialPage(context, (back) {
  Widget list() => MessagesScreen(
    messages: messages,
    onBack: back,
    openChat: (conversation) =>
        openChat(context, conversation, messages: messages, friends: friends),
    openOptions: (conversation) => openConversationOptions(
      context,
      conversation,
      messages: messages,
      friends: friends,
      withFriendPage: true,
    ),
  );
  if (!DeviceCapabilities.isDesktop) return list();
  return LayoutBuilder(
    builder: (_, constraints) =>
        constraints.maxWidth < MessagesSplitView.minWidth
        ? list()
        : MessagesSplitView(
            messages: messages,
            onBack: back,
            chat: (conversation, close) => ChatScreen(
              conversation: conversation,
              messages: messages,
              onOpenFriend: () => openSocialPage(
                context,
                (back) => FriendScreen(
                  person: conversation.peer,
                  friends: friends,
                  messages: messages,
                  fromChat: true,
                  onBack: back,
                ),
              ),
              onOpenOptions: () => openConversationOptions(
                context,
                conversation,
                messages: messages,
                afterDelete: close,
              ),
            ),
            openOptions: (conversation, close) => openConversationOptions(
              context,
              conversation,
              messages: messages,
              friends: friends,
              withFriendPage: true,
              afterDelete: close,
            ),
          ),
  );
});

String _date(DateTime at) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = at.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// The newest message replaces any still showing.
void _show(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({
    super.key,
    this.social,
    this.friends,
    this.recommendations,
    this.messages,
    this.onBack,
    this.title = 'Friends',
    this.movieNight,
    this.greet = false,
    this.bottomClearance = 20,
  });

  /// The page's title: Friends, or Together where the page is a place in
  /// the navigation.
  final String title;

  /// Together's Movie night, shown whether Friends is on or off.
  final Widget? movieNight;

  /// Together greets the viewer by name under the title; Friends shows the
  /// handle there.
  final bool greet;

  /// Space below the page, for the phone dock.
  final double bottomClearance;

  /// [SocialController.instance] when null.
  final SocialController? social;

  /// [FriendsController.instance] when null.
  final FriendsController? friends;

  /// [RecommendationsController.instance] when null.
  final RecommendationsController? recommendations;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;
  final VoidCallback? onBack;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  late final SocialController _social =
      widget.social ?? SocialController.instance;
  late final FriendsController _friends =
      widget.friends ?? FriendsController.instance;
  late final RecommendationsController _recommendations =
      widget.recommendations ?? RecommendationsController.instance;
  late final MessagesController _messages =
      widget.messages ?? MessagesController.instance;

  /// Reads again on return to the app after a while away.
  late final AppLifecycleListener _lifecycle;
  DateTime _loadedAt = DateTime.now();

  /// What friends are watching changes while the page is open; it is read
  /// again this often while the page shows and the app is in front (friends'
  /// apps send it at most once a minute).
  static const watchingEvery = Duration(minutes: 1);
  Timer? _watchingTimer;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (DateTime.now().difference(_loadedAt) <
            SocialController.staleAfter) {
          return;
        }
        unawaited(_reload());
      },
    );
    unawaited(_reload());
    _watchingTimer = Timer.periodic(watchingEvery, (_) => _refreshWatching());
  }

  /// Only while this page is what the viewer sees: not under another page,
  /// not a hidden tab (TickerMode), not with the app in the background.
  void _refreshWatching() {
    if (!mounted || !_social.enabled) return;
    // Null before the platform has reported a state: in front.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    unawaited(_friends.loadWatching());
  }

  @override
  void dispose() {
    _watchingTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _loadedAt = DateTime.now();
    unawaited(_messages.ensureLoaded());
    await _social.refreshIfStale();
    if (_social.enabled) {
      await Future.wait([_friends.load(), _recommendations.load()]);
      await _friends.loadWatching();
    }
  }

  void _openPrivacy() => openSocialPage(
    context,
    (back) => FriendsPrivacyScreen(
      controller: _social,
      friends: _friends,
      recommendations: _recommendations,
      messages: _messages,
      onBack: back,
    ),
  );

  void _openRecommendations() => openSocialPage(
    context,
    (back) =>
        RecommendationsScreen(recommendations: _recommendations, onBack: back),
  );

  void _openFriend(SocialPerson person) => openSocialPage(
    context,
    (back) => FriendScreen(
      person: person,
      friends: _friends,
      messages: _messages,
      onBack: back,
    ),
  );

  void _openMessages() =>
      openMessages(context, messages: _messages, friends: _friends);

  void _openBlocked() => openSocialPage(
    context,
    (back) => BlockedPeopleScreen(friends: _friends, onBack: back),
  );

  void _openConnect() => openSocialPage(
    context,
    (back) => ConnectScreen(onBack: back, social: _social),
  );

  /// Reelish Connect: invitations and QR codes, with Friends on or off.
  SettingsTile _connectTile() => SettingsTile(
    icon: ReelishIcons.share,
    title: 'Reelish Connect',
    description: 'Invite people with a QR code or a link',
    onTap: _openConnect,
  );

  Future<void> _add() async {
    final result = await showAddFriend(context, _friends);
    if (result == null || !mounted) return;
    final person = result.person!;
    _show(
      context,
      result.friends
          ? 'You and @${person.handle} are now friends'
          : 'Request sent to @${person.handle}',
    );
  }

  Future<void> _run(Future<String?> action, String done) async {
    final error = await action;
    if (mounted) _show(context, error ?? done);
  }

  Future<void> _decline(SocialPerson person) async {
    final confirmed = await confirmSocial(
      context,
      title: 'Decline @${person.handle}?',
      message: 'They are not told. They can ask again later.',
      action: 'Decline',
    );
    if (confirmed) {
      await _run(_friends.decline(person), 'Request declined');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _social,
      _friends,
      _recommendations,
      _messages,
    ]),
    builder: (context, _) {
      final profile = _social.profile;
      final movieNight = widget.movieNight;
      final List<Widget> body;
      if (profile != null) {
        body = [_on(profile)];
      } else {
        body = [
          _beforeFriends(
            movieNight,
            _social.known
                ? _off()
                : _social.failed
                ? _retry()
                : const _Spinner(),
          ),
        ];
      }
      // The viewer's own name, never the app's: with neither a chosen name
      // nor a Trakt username, the greeting stands alone.
      final name =
          ProfileController.instance.displayName ??
          AccountController.instance.username;
      final page = SettingsPage(
        // Two columns on TV and Windows: the width Home gives Together
        // there, not a settings page's single readable column.
        readableWidth: 1100,
        title: widget.title,
        subtitle: widget.greet
            ? [greetingFor(DateTime.now()), ?name].join(', ')
            : profile == null
            ? null
            : '@${profile.handle}',
        icon: ReelishIcons.people,
        onBack: widget.onBack,
        footer: null,
        bottomClearance: widget.bottomClearance,
        children: body,
      );
      // Pull to refresh where there is touch; a remote or mouse reloads
      // when the page opens or the app comes back.
      if (DeviceCapabilities.usesTvLayout) return page;
      return RefreshIndicator(onRefresh: _refreshNow, child: page);
    },
  );

  /// Everything again, now: pull to refresh.
  Future<void> _refreshNow() async {
    await _social.refresh();
    if (_social.enabled) {
      await Future.wait([_friends.load(), _recommendations.load()]);
      await _friends.loadWatching();
    }
  }

  /// Before Friends is on: Movie night, then [friends] (turning it on, or
  /// loading it). Side by side where the page is wide (TV, Windows), as
  /// with Friends on, so neither half leaves the other's side empty; one
  /// column on a phone, with the sections' usual gap between them.
  Widget _beforeFriends(Widget? movieNight, Widget friends) {
    if (movieNight == null) return friends;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            DeviceCapabilities.usesTvLayout && constraints.maxWidth >= 720;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  bottom: SettingsMetrics.sectionGap,
                ),
                child: movieNight,
              ),
              friends,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: movieNight),
            const SizedBox(width: AppSpace.lg),
            Expanded(child: friends),
          ],
        );
      },
    );
  }

  Widget _off() => SettingsSection(
    label: 'FRIENDS',
    description:
        'Add friends with a code, send them titles to watch and share the '
        'collections you choose. Nothing is shared until you turn it on, and '
        'friends never see your Trakt username.',
    children: [
      SettingsTile(
        icon: ReelishIcons.personAdd,
        title: 'Turn on Friends',
        description: 'Choose a handle that friends will see',
        onTap: _openPrivacy,
      ),
      _connectTile(),
    ],
  );

  Widget _retry() => SettingsSection(
    description:
        'Friends could not be loaded. Check your connection and try again.',
    children: [
      SettingsTile(
        icon: ReelishIcons.refresh,
        title: 'Try again',
        onTap: () => unawaited(_social.refresh().then((_) => _reload())),
      ),
    ],
  );

  Widget _on(SocialProfile profile) {
    final incoming = _friends.incoming;
    final outgoing = _friends.outgoing;
    final friends = _friends.friends;
    final watching = _friends.watching;
    final recommended = _recommendations.items;
    final unread = _social.counts.unread;
    final conversations = _messages.conversations;
    final unreadMessages = _messages.unread;
    final waitingMessages = _social.counts.messages;
    // Nobody here yet: say what Together is for before anything empty.
    final newcomer =
        _friends.loaded &&
        friends.isEmpty &&
        incoming.isEmpty &&
        conversations.isEmpty &&
        waitingMessages == 0;
    Widget gap(Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: SettingsMetrics.sectionGap),
      child: child,
    );

    // People first: the faces, then the two things you do with them most.
    final top = <Widget>[
      if (_friends.failed && _friends.loaded)
        const _Note(
          'Reelish could not be reached: this is the list from your last '
          'visit.',
        ),
      if (newcomer)
        gap(
          WelcomeCard(
            friendCode: profile.formattedCode,
            onAdd: () => unawaited(_add()),
            onCopyCode: () => unawaited(_copyCode(profile)),
          ),
        )
      else ...[
        if (friends.isNotEmpty || watching.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: FriendsStrip(
              friends: friends,
              watching: watching,
              onOpen: _openFromStrip,
              onAdd: () => unawaited(_add()),
            ),
          ),
        gap(
          TogetherShortcuts(
            newMessages: unreadMessages + waitingMessages,
            onMessages: _openMessages,
          ),
        ),
      ],
    ];

    final movieNight = widget.movieNight == null
        ? null
        : gap(widget.movieNight!);
    // Someone waiting on an answer comes first.
    final requests = incoming.isEmpty
        ? null
        : SettingsSection(
            label: 'REQUESTS · ${incoming.length}',
            children: [
              for (final person in incoming)
                PersonTile(
                  person: person,
                  subtitle: 'Wants to be friends',
                  enabled: !_friends.isWorking(person.handle),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Decline',
                        onPressed: _friends.isWorking(person.handle)
                            ? null
                            : () => unawaited(_decline(person)),
                        icon: Icon(ReelishIcons.close, color: GlassTheme.muted),
                      ),
                      IconButton.filled(
                        tooltip: 'Accept',
                        onPressed: _friends.isWorking(person.handle)
                            ? null
                            : () => unawaited(
                                _run(
                                  _friends.accept(person),
                                  'You and @${person.handle} are now friends',
                                ),
                              ),
                        icon: const Icon(ReelishIcons.check),
                      ),
                    ],
                  ),
                ),
            ],
          );

    // Messages need a friend: shown once there is something to read. Until
    // then the shortcut at the top is the way in.
    final messages = conversations.isEmpty && waitingMessages == 0
        ? null
        : SettingsSection(
            label: unreadMessages > 0
                ? 'MESSAGES · $unreadMessages NEW'
                : 'MESSAGES',
            children: [
              for (final conversation in conversations.take(3))
                ConversationTile(
                  conversation: conversation,
                  messages: _messages,
                  onTap: () => openChat(
                    context,
                    conversation,
                    messages: _messages,
                    friends: _friends,
                  ),
                  onOptions: () => openConversationOptions(
                    context,
                    conversation,
                    messages: _messages,
                    friends: _friends,
                    withFriendPage: true,
                  ),
                ),
              SettingsTile(
                icon: ReelishIcons.chat,
                title: 'All messages',
                description: waitingMessages > 0
                    ? (waitingMessages == 1
                          ? '1 new message is waiting'
                          : '$waitingMessages new messages are waiting')
                    : null,
                onTap: _openMessages,
              ),
            ],
          );

    // What friends sent, as posters to pick from.
    final discoveries = gap(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TogetherHeading(
            label: unread > 0
                ? 'SHARED DISCOVERIES · $unread NEW'
                : 'SHARED DISCOVERIES',
            actionLabel: 'See all',
            onAction: _openRecommendations,
          ),
          if (recommended.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                "When a friend sends you a title, it lands here. Send one "
                "from any title's page with Recommend.",
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.label,
                  height: 1.4,
                ),
              ),
            )
          else
            DiscoveriesRow(
              items: recommended.take(12).toList(),
              onOpen: (item) => openRecommendation(_recommendations, item),
            ),
        ],
      ),
    );

    // Your people: adding someone, your code to give out, and everyone.
    final Widget? people;
    if (newcomer) {
      people = null;
    } else if (!_friends.loaded && _friends.loading) {
      people = const _Spinner();
    } else if (!_friends.loaded && _friends.failed) {
      people = _retry();
    } else {
      final count = _social.counts.friends > friends.length
          ? _social.counts.friends
          : friends.length;
      people = SettingsSection(
        label: friends.isEmpty ? 'YOUR PEOPLE' : 'YOUR PEOPLE · $count',
        children: [
          SettingsTile(
            icon: ReelishIcons.personAdd,
            title: 'Add by code or @handle',
            onTap: () => unawaited(_add()),
          ),
          SettingsTile(
            icon: ReelishIcons.hash,
            title: 'Your friend code',
            value: profile.formattedCode,
            description: 'Tap to copy, and send it so friends can add you',
            onTap: () => unawaited(_copyCode(profile)),
            trailing: DeviceCapabilities.isTv
                ? null
                : Icon(ReelishIcons.copy, color: GlassTheme.muted, size: 20),
          ),
          for (final person in friends)
            PersonTile(
              person: person,
              subtitle: person.since == null
                  ? null
                  : 'Friends since ${_date(person.since!)}',
              onTap: () => _openFriend(person),
            ),
          if (_friends.hasMore)
            SettingsTile(
              icon: ReelishIcons.arrowDown,
              title: _friends.loadingMore ? 'Loading…' : 'Show more',
              enabled: !_friends.loadingMore,
              onTap: () => unawaited(_friends.loadMore()),
            ),
        ],
      );
    }
    final sent = outgoing.isEmpty
        ? null
        : SettingsSection(
            label: 'SENT',
            children: [
              for (final person in outgoing)
                PersonTile(
                  person: person,
                  subtitle: 'Waiting for an answer',
                  enabled: !_friends.isWorking(person.handle),
                  trailing: TextButton(
                    onPressed: _friends.isWorking(person.handle)
                        ? null
                        : () => unawaited(
                            _run(_friends.cancel(person), 'Request cancelled'),
                          ),
                    child: const Text('Cancel'),
                  ),
                ),
            ],
          );
    // Settings for the people side, last and quieter.
    final privacy = SettingsSection(
      label: 'PRIVACY AND PEOPLE',
      children: [
        _connectTile(),
        SettingsTile(
          icon: ReelishIcons.shield,
          title: 'Friends & privacy',
          description: 'Your handle, what friends see, who can find you',
          onTap: _openPrivacy,
        ),
        SettingsTile(
          icon: ReelishIcons.blocked,
          title: 'Blocked people',
          onTap: _openBlocked,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // TV and Windows with room: movie night and what friends share
        // beside the people themselves.
        final wide =
            DeviceCapabilities.usesTvLayout && constraints.maxWidth >= 720;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...top,
              ?movieNight,
              ?requests,
              ?messages,
              discoveries,
              ?people,
              ?sent,
              privacy,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...top,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [?movieNight, ?messages, discoveries],
                  ),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [?requests, ?people, ?sent, privacy],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// A friend in the strip: what they are watching now, when they share it
  /// (as the Watching now row did), else their page.
  void _openFromStrip(SocialPerson person) {
    final open = SocialTitles.open;
    for (final now in _friends.watching) {
      if (now.person.handle == person.handle && open != null) {
        unawaited(open(now.media));
        return;
      }
    }
    _openFriend(person);
  }

  Future<void> _copyCode(SocialProfile profile) async {
    await Clipboard.setData(ClipboardData(text: profile.formattedCode));
    if (mounted) _show(context, 'Friend code copied');
  }
}

/// Opens a recommended title's details and marks it read.
void openRecommendation(
  RecommendationsController recommendations,
  Recommendation item,
) {
  unawaited(recommendations.markRead(item));
  final open = SocialTitles.open;
  if (open != null) unawaited(open(item.media));
}

/// Every title friends sent, newest first. Opening it marks everything read.
class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({super.key, this.recommendations, this.onBack});

  /// [RecommendationsController.instance] when null.
  final RecommendationsController? recommendations;
  final VoidCallback? onBack;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  late final RecommendationsController _recommendations =
      widget.recommendations ?? RecommendationsController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  /// What this account sent; null while loading or when it failed.
  List<Recommendation>? _sent;

  Future<void> _open() async {
    unawaited(_loadSent());
    await _recommendations.load();
    await _recommendations.markRead();
  }

  Future<void> _loadSent() async {
    try {
      final sent = await _recommendations.sentByMe();
      if (mounted) setState(() => _sent = sent);
    } catch (_) {
      // The section stays hidden; the inbox matters more.
    }
  }

  Future<void> _remove(Recommendation item) async {
    final error = await _recommendations.remove(item);
    if (mounted) _show(context, error ?? 'Removed “${item.media.name}”');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _recommendations,
    builder: (context, _) {
      final items = _recommendations.items;
      return SettingsPage(
        title: 'Recommendations',
        subtitle: 'Titles friends sent you',
        icon: ReelishIcons.send,
        onBack: widget.onBack,
        footer: null,
        children: [
          if (_recommendations.failed && _recommendations.loaded)
            const _Note(
              'Reelish could not be reached: this is the list from your last '
              'visit.',
            ),
          if (!_recommendations.loaded && _recommendations.loading)
            const _Spinner()
          else if (!_recommendations.loaded && _recommendations.failed)
            SettingsSection(
              description: 'Recommendations could not be loaded.',
              children: [
                SettingsTile(
                  icon: ReelishIcons.refresh,
                  title: 'Try again',
                  onTap: () => unawaited(_open()),
                ),
              ],
            )
          else if (items.isEmpty)
            const _Note(
              'Nothing yet. When a friend shares a title with you, it shows '
              'here. Share one with them from any title’s page.',
            )
          else
            SettingsSection(
              label: 'SENT TO YOU',
              children: [
                for (final item in items)
                  RecommendationTile(
                    item: item,
                    onOpen: () => openRecommendation(_recommendations, item),
                    onRemove: () => unawaited(_remove(item)),
                  ),
                if (_recommendations.hasMore)
                  SettingsTile(
                    icon: ReelishIcons.arrowDown,
                    title: _recommendations.loadingMore
                        ? 'Loading…'
                        : 'Show more',
                    enabled: !_recommendations.loadingMore,
                    onTap: () => unawaited(_recommendations.loadMore()),
                  ),
              ],
            ),
          if (_sent case final sent? when sent.isNotEmpty)
            SettingsSection(
              label: 'YOU SENT',
              children: [
                for (final item in sent)
                  RecommendationTile(
                    item: item,
                    sentByMe: true,
                    onOpen: () {
                      final open = SocialTitles.open;
                      if (open != null) unawaited(open(item.media));
                    },
                  ),
              ],
            ),
        ],
      );
    },
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, AppSpace.md),
    child: Text(
      text,
      style: TextStyle(color: GlassTheme.muted, fontSize: AppTextSize.label),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpace.xl),
    child: Center(child: CircularProgressIndicator()),
  );
}

/// One friend: who they are, and remove, block and report.
class FriendScreen extends StatefulWidget {
  const FriendScreen({
    super.key,
    required this.person,
    this.friends,
    this.messages,
    this.fromChat = false,
    this.onBack,
  });

  final SocialPerson person;

  /// [FriendsController.instance] when null.
  final FriendsController? friends;

  /// [MessagesController.instance] when null.
  final MessagesController? messages;

  /// Opened from their conversation: Message goes back to it.
  final bool fromChat;
  final VoidCallback? onBack;

  @override
  State<FriendScreen> createState() => _FriendScreenState();
}

class _FriendScreenState extends State<FriendScreen> {
  late final FriendsController _friends =
      widget.friends ?? FriendsController.instance;
  late final MessagesController _messages =
      widget.messages ?? MessagesController.instance;
  late SocialPerson _person = widget.person;

  void _message() {
    if (widget.fromChat) return widget.onBack?.call();
    if (_person.conversation == null) return;
    unawaited(_messages.ensureLoaded());
    openChat(
      context,
      _messages.open(_person),
      messages: _messages,
      friends: _friends,
    );
  }

  /// Null while checking; false once the server says they are no longer a
  /// friend (removed or blocked elsewhere).
  bool? _stillFriends;

  /// What they share; null until the server answered.
  List<SharedCollection>? _collections;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  void _openCollection(SharedCollection collection) => openSocialPage(
    context,
    (back) => FriendCollectionScreen(
      owner: _person,
      collection: collection,
      friends: _friends,
      onBack: back,
    ),
  );

  Future<void> _check() async {
    try {
      final page = await _friends.friend(_person.handle);
      if (mounted) {
        setState(() {
          _person = page.person;
          _collections = page.collections;
          _stillFriends = true;
        });
      }
    } on AccountApiException catch (error) {
      // Offline: keep what the list showed. Not found: removed or blocked.
      if (mounted) setState(() => _stillFriends = error.status != 404);
    } catch (_) {
      if (mounted) setState(() => _stillFriends = true);
    }
  }

  void _close() {
    if (!mounted) return;
    widget.onBack?.call();
  }

  Future<void> _remove() async {
    final confirmed = await confirmSocial(
      context,
      title: 'Remove @${_person.handle}?',
      message:
          'You stop being friends on both sides. They are not told, and '
          'recommendations already sent stay.',
      action: 'Remove',
      destructive: true,
    );
    if (!confirmed) return;
    final error = await _friends.remove(_person);
    if (!mounted) return;
    _show(context, error ?? 'Removed @${_person.handle}');
    if (error == null) _close();
  }

  Future<void> _block() async {
    final confirmed = await confirmSocial(
      context,
      title: 'Block @${_person.handle}?',
      message:
          'You stop being friends, and recommendations and undelivered '
          'messages between you are deleted. They cannot find you, message '
          'you, send you requests or see anything you share. They are not '
          'told.',
      action: 'Block',
      destructive: true,
    );
    if (!confirmed) return;
    final error = await _friends.block(_person);
    if (!mounted) return;
    _show(context, error ?? 'Blocked @${_person.handle}');
    if (error == null) _close();
  }

  Future<void> _report() async {
    final choice = await showReportPerson(context, _person);
    if (choice == null) return;
    final error = await _friends.report(
      _person,
      reason: choice.reason,
      note: choice.note,
      alsoBlock: choice.block,
    );
    if (!mounted) return;
    _show(context, error ?? 'Thanks. Reelish will look into it.');
    if (error == null && choice.block) _close();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _friends,
    builder: (context, _) {
      final working = _friends.isWorking(_person.handle);
      final since = _person.since;
      return SettingsPage(
        title: _person.label,
        subtitle: '@${_person.handle}',
        onBack: widget.onBack,
        footer: null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
            child: Column(
              children: [
                PersonAvatar(person: _person, size: 96),
                const SizedBox(height: AppSpace.md),
                Text(
                  _person.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: AppTextSize.title,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (_person.displayName != null) '@${_person.handle}',
                    if (_stillFriends == false)
                      'No longer friends'
                    else if (since != null)
                      'Friends since ${_date(since)}',
                  ].join(' · '),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GlassTheme.muted),
                ),
              ],
            ),
          ),
          if (_collections case final shared? when _stillFriends != false)
            SettingsSection(
              label: 'SHARED COLLECTIONS',
              description: shared.isEmpty
                  ? '${_person.label} has not shared a collection yet.'
                  : null,
              children: [
                for (final collection in shared)
                  SharedCollectionTile(
                    collection: collection,
                    onOpen: () => _openCollection(collection),
                  ),
                if (shared.isEmpty)
                  SettingsTile(
                    icon: ReelishIcons.send,
                    title: 'Share a title with ${_person.label}',
                    description: 'From any title’s page, press Share',
                    showChevron: false,
                  ),
              ],
            ),
          if (_stillFriends != false)
            SettingsSection(
              children: [
                SettingsTile(
                  icon: ReelishIcons.chat,
                  title: 'Message',
                  description: _person.conversation == null
                      ? 'Connect to Reelish to start a conversation'
                      : 'A private conversation with ${_person.label}',
                  enabled: _person.conversation != null || widget.fromChat,
                  onTap: _message,
                ),
              ],
            ),
          SettingsSection(
            children: [
              if (_stillFriends != false)
                SettingsTile(
                  icon: ReelishIcons.person,
                  title: 'Remove friend',
                  enabled: !working,
                  onTap: () => unawaited(_remove()),
                ),
              SettingsTile(
                icon: ReelishIcons.blocked,
                title: 'Block',
                description: 'They can no longer find or contact you',
                enabled: !working,
                onTap: () => unawaited(_block()),
              ),
              SettingsTile(
                icon: ReelishIcons.warning,
                title: 'Report',
                description: 'Tell Reelish about a problem with this person',
                enabled: !working,
                onTap: () => unawaited(_report()),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// The people this account blocked, each with Unblock.
class BlockedPeopleScreen extends StatefulWidget {
  const BlockedPeopleScreen({super.key, this.friends, this.onBack});

  /// [FriendsController.instance] when null.
  final FriendsController? friends;
  final VoidCallback? onBack;

  @override
  State<BlockedPeopleScreen> createState() => _BlockedPeopleScreenState();
}

class _BlockedPeopleScreenState extends State<BlockedPeopleScreen> {
  late final FriendsController _friends =
      widget.friends ?? FriendsController.instance;
  List<SocialPerson>? _people;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final people = await _friends.blocked();
      if (mounted) setState(() => _people = people);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _unblock(SocialPerson person) async {
    final confirmed = await confirmSocial(
      context,
      title: 'Unblock @${person.handle}?',
      message:
          'They can find you and send you a request again. Nothing from '
          'before comes back.',
      action: 'Unblock',
    );
    if (!confirmed) return;
    final error = await _friends.unblock(person);
    if (!mounted) return;
    _show(context, error ?? 'Unblocked @${person.handle}');
    if (error == null) {
      setState(
        () => _people = [
          for (final p in _people ?? const <SocialPerson>[])
            if (p.handle != person.handle) p,
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _friends,
    builder: (context, _) {
      final people = _people;
      return SettingsPage(
        title: 'Blocked people',
        icon: ReelishIcons.blocked,
        onBack: widget.onBack,
        footer: null,
        children: [
          if (people == null && _failed)
            SettingsSection(
              description: 'The list could not be loaded.',
              children: [
                SettingsTile(
                  icon: ReelishIcons.refresh,
                  title: 'Try again',
                  onTap: () => unawaited(_load()),
                ),
              ],
            )
          else if (people == null)
            const _Spinner()
          else
            SettingsSection(
              description: people.isEmpty
                  ? 'You have not blocked anyone.'
                  : 'Blocked people cannot find you, send you requests or '
                        'see anything you share.',
              children: [
                for (final person in people)
                  PersonTile(
                    person: person,
                    enabled: !_friends.isWorking(person.handle),
                    trailing: TextButton(
                      onPressed: _friends.isWorking(person.handle)
                          ? null
                          : () => unawaited(_unblock(person)),
                      child: const Text('Unblock'),
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}
