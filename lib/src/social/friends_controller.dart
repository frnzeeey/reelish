// Friends: the list, requests both ways and every action on another person
// (add, accept, decline, cancel, remove, block, unblock, report). The Reelish
// API decides and enforces all of it (backend/src/social/friends.ts); this
// asks, keeps the first page per account for offline display, and updates
// the list in place after an action so no re-read is needed.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../models/media_item.dart';
import 'social_controller.dart';

/// Another person as friends see them: never an account id.
@immutable
class SocialPerson {
  const SocialPerson({
    required this.handle,
    this.displayName,
    this.avatar,
    this.since,
  });

  final String handle;
  final String? displayName;

  /// An `AvatarPreset` id, or null.
  final String? avatar;

  /// When the friendship or request began.
  final DateTime? since;

  /// The name to show first: their chosen name, else the handle.
  String get label => displayName ?? '@$handle';

  static SocialPerson? fromJson(Object? value) {
    if (value is! Map) return null;
    final handle = value['handle'];
    if (handle is! String || handle.isEmpty) return null;
    final name = value['displayName'];
    final avatar = value['avatar'];
    final since = value['since'];
    return SocialPerson(
      handle: handle,
      displayName: name is String && name.isNotEmpty ? name : null,
      avatar: avatar is String && avatar.isNotEmpty ? avatar : null,
      since: since is int
          ? DateTime.fromMillisecondsSinceEpoch(since, isUtc: true)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'handle': handle,
    'displayName': displayName,
    'avatar': avatar,
    'since': since?.millisecondsSinceEpoch,
  };

  static List<SocialPerson> listFrom(Object? value) => value is List
      ? [for (final entry in value) ?SocialPerson.fromJson(entry)]
      : const [];
}

/// A collection a friend shares, as their page lists it.
@immutable
class SharedCollection {
  const SharedCollection({
    required this.id,
    required this.name,
    this.description,
    this.count = 0,
    this.posters = const [],
  });

  final String id;
  final String name;
  final String? description;
  final int count;

  /// Up to four TMDB posters: the chosen cover first.
  final List<String> posters;

  static SharedCollection? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    if (id is! String || name is! String || name.isEmpty) return null;
    final description = value['description'];
    final count = value['count'];
    final posters = value['posters'];
    return SharedCollection(
      id: id,
      name: name,
      description: description is String && description.isNotEmpty
          ? description
          : null,
      count: count is int ? count : 0,
      posters: posters is List
          ? [
              for (final poster in posters)
                if (poster is String && _tmdbArtwork.hasMatch(poster)) poster,
            ]
          : const [],
    );
  }
}

/// Artwork shown from another person's data: TMDB's image host only.
final _tmdbArtwork = RegExp(r'^https://image\.tmdb\.org/t/p/');

/// A title in a friend's shared collection, as a card to open.
MediaItem? sharedTitleFrom(Object? value) {
  if (value is! Map) return null;
  final type = value['type'];
  final id = value['id'];
  final title = value['title'];
  if ((type != 'movie' && type != 'series') ||
      id is! String ||
      title is! String) {
    return null;
  }
  final year = value['year'];
  final poster = value['poster'];
  return MediaItem(
    id: id,
    type: type as String,
    name: title,
    year: year is String ? year : '',
    poster: poster is String && _tmdbArtwork.hasMatch(poster) ? poster : '',
  );
}

/// A friend watching something now.
@immutable
class WatchingFriend {
  const WatchingFriend({
    required this.person,
    required this.media,
    this.season,
    this.episode,
  });

  final SocialPerson person;
  final MediaItem media;
  final int? season;
  final int? episode;

  /// What they watch, as one line: "Dark · S1 E3".
  String get label => season != null && episode != null
      ? '${media.name} · S$season E$episode'
      : media.name;

  static WatchingFriend? fromJson(Object? value) {
    if (value is! Map) return null;
    final person = SocialPerson.fromJson(value['person']);
    final media = sharedTitleFrom(value['media']);
    if (person == null || media == null) return null;
    final season = value['season'];
    final episode = value['episode'];
    return WatchingFriend(
      person: person,
      media: media,
      season: season is int ? season : null,
      episode: episode is int ? episode : null,
    );
  }
}

/// A friend's page: who they are and what they share.
typedef FriendPage = ({
  SocialPerson person,
  List<SharedCollection> collections,
});

/// One page of a shared collection; [collection] only on the first.
typedef SharedCollectionPage = ({
  SharedCollection? collection,
  List<MediaItem> titles,
  String? cursor,
});

/// The reasons a person can be reported for, by the name the API uses.
enum ReportReason {
  spam('spam', 'Spam'),
  harassment('harassment', 'Harassment'),
  impersonation('impersonation', 'Pretending to be someone'),
  inappropriate('inappropriate', 'Inappropriate name or avatar'),
  other('other', 'Something else');

  const ReportReason(this.field, this.label);
  final String field;
  final String label;
}

/// What the person typed into Add friend, as the request body: a friend
/// code (case, spaces and dashes ignored) or a handle (with or without @).
/// Null when it can be neither.
Map<String, String>? friendTarget(String input) {
  final text = input.trim();
  if (text.startsWith('@')) {
    final handle = text.substring(1);
    return handlePattern.hasMatch(handle) ? {'handle': handle} : null;
  }
  final code = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$').hasMatch(code)) {
    return {'code': code};
  }
  return handlePattern.hasMatch(text) ? {'handle': text} : null;
}

/// The answer to Add friend: a request sent, or already (now) friends.
typedef AddFriendResult = ({String? error, SocialPerson? person, bool friends});

class FriendsController extends ChangeNotifier {
  FriendsController({
    AccountController? account,
    AccountApi? api,
    SocialController? social,
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _social = social ?? SocialController.instance;

  static final instance = FriendsController();

  static const cachePrefix = 'reelish.friends.v1.';

  final AccountController _account;
  final AccountApi _api;
  final SocialController _social;

  String? _loadedFor;
  bool _loaded = false;
  List<SocialPerson> _friends = const [];
  List<SocialPerson> _incoming = const [];
  List<SocialPerson> _outgoing = const [];
  List<WatchingFriend> _watching = const [];
  String? _cursor;
  bool _loading = false;
  bool _loadingMore = false;
  bool _failed = false;
  final _working = <String>{};

  bool get _current => _loadedFor != null && _loadedFor == _account.userId;

  List<SocialPerson> get friends => _current ? _friends : const [];
  List<SocialPerson> get incoming => _current ? _incoming : const [];
  List<SocialPerson> get outgoing => _current ? _outgoing : const [];

  /// Friends watching something now, as last asked; never saved, since it
  /// is out of date within the hour.
  List<WatchingFriend> get watching => _current ? _watching : const [];

  /// Whether a list (saved or from the server) is showing for this account.
  bool get loaded => _current && _loaded;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;

  /// The last load failed: the list may be the saved, older one.
  bool get failed => _failed;
  bool get hasMore => _current && _cursor != null;

  /// An action on [handle] is on its way.
  bool isWorking(String handle) => _working.contains(handle.toLowerCase());

  Future<void>? _loadingFuture;

  /// The saved first page, then the server's.
  Future<void> load() =>
      _loadingFuture ??= _load().whenComplete(() => _loadingFuture = null);

  Future<void> _load() async {
    await Future<void>.value();
    final userId = _account.userId;
    if (userId == null) return;
    if (_loadedFor != userId) await _restore(userId);
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final token = await _token();
      final body = await _api.friends(token);
      if (_account.userId != userId) return;
      _friends = SocialPerson.listFrom(body['friends']);
      _incoming = SocialPerson.listFrom(body['incoming']);
      _outgoing = SocialPerson.listFrom(body['outgoing']);
      _cursor = body['cursor'] is String ? body['cursor'] as String : null;
      _loaded = true;
      unawaited(_save(userId));
    } catch (_) {
      _failed = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Asks which friends are watching something now. Best effort: a failure
  /// keeps the last answer.
  Future<void> loadWatching() async {
    final userId = _account.userId;
    if (userId == null || !_current) return;
    try {
      final body = await _api.friendsWatching(await _token());
      if (_account.userId != userId) return;
      final list = body['watching'];
      _watching = list is List
          ? [for (final entry in list) ?WatchingFriend.fromJson(entry)]
          : const [];
      notifyListeners();
    } catch (_) {
      // The section simply stays as it was.
    }
  }

  /// The next page of friends.
  Future<void> loadMore() async {
    final userId = _account.userId;
    final cursor = _cursor;
    if (!_current || cursor == null || _loadingMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final body = await _api.friends(await _token(), cursor: cursor);
      if (_account.userId != userId) return;
      _friends = [..._friends, ...SocialPerson.listFrom(body['friends'])];
      _cursor = body['cursor'] is String ? body['cursor'] as String : null;
    } catch (_) {
      // The Load more row stays; trying again is one tap.
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// Sends a request to the person [input] names (a code or a handle).
  Future<AddFriendResult> add(String input) async {
    final target = friendTarget(input);
    if (target == null) {
      return (
        error: 'Enter a friend code like ABCD-2345, or a @handle.',
        person: null,
        friends: false,
      );
    }
    try {
      final body = await _api.sendFriendRequest(await _token(), target);
      final person = SocialPerson.fromJson(body['person']);
      if (person == null) {
        throw const AccountApiException('unavailable', 'Unexpected response.');
      }
      final friends = body['status'] == 'friends';
      // Adding someone who had asked me accepts their request.
      final wasAsking = _has(_incoming, person.handle);
      _withoutRequests(person.handle);
      if (friends) {
        if (!_has(_friends, person.handle)) {
          _friends = _sorted([..._friends, person]);
          _social.adjustCounts(friends: 1, incoming: wasAsking ? -1 : 0);
        }
      } else if (!_has(_outgoing, person.handle)) {
        _outgoing = [person, ..._outgoing];
      }
      notifyListeners();
      return (error: null, person: person, friends: friends);
    } on AccountApiException catch (error) {
      return (
        error: SocialController.messageFor(error),
        person: null,
        friends: false,
      );
    } catch (_) {
      return (
        error: 'Something went wrong. Try again later.',
        person: null,
        friends: false,
      );
    }
  }

  Future<String?> accept(SocialPerson person) => _act(person, (token) async {
    final body = await _api.acceptFriendRequest(token, person.handle);
    final now = SocialPerson.fromJson(body['person']) ?? person;
    _incoming = _without(_incoming, person.handle);
    _friends = _sorted([..._without(_friends, person.handle), now]);
    _social.adjustCounts(friends: 1, incoming: -1);
  });

  Future<String?> decline(SocialPerson person) => _act(person, (token) async {
    await _api.declineFriendRequest(token, person.handle);
    _incoming = _without(_incoming, person.handle);
    _social.adjustCounts(incoming: -1);
  });

  Future<String?> cancel(SocialPerson person) => _act(person, (token) async {
    await _api.cancelFriendRequest(token, person.handle);
    _outgoing = _without(_outgoing, person.handle);
  });

  Future<String?> remove(SocialPerson person) => _act(person, (token) async {
    await _api.removeFriend(token, person.handle);
    _friends = _without(_friends, person.handle);
    _social.adjustCounts(friends: -1);
  });

  /// Blocks [person]: they leave every list here, and the server ends any
  /// friendship, request and recommendation between the two.
  Future<String?> block(SocialPerson person) => _act(person, (token) async {
    await _api.blockPerson(token, person.handle);
    final wasFriend = _has(_friends, person.handle);
    final wasAsking = _has(_incoming, person.handle);
    _friends = _without(_friends, person.handle);
    _withoutRequests(person.handle);
    _social.adjustCounts(
      friends: wasFriend ? -1 : 0,
      incoming: wasAsking ? -1 : 0,
    );
  });

  Future<String?> unblock(SocialPerson person) =>
      _act(person, (token) => _api.unblockPerson(token, person.handle));

  /// Reports [person] to Reelish; blocks them too when [alsoBlock].
  Future<String?> report(
    SocialPerson person, {
    required ReportReason reason,
    String note = '',
    bool alsoBlock = false,
  }) async {
    final error = await _act(
      person,
      (token) => _api.reportPerson(
        token,
        handle: person.handle,
        reason: reason.field,
        note: note.trim(),
      ),
    );
    if (error != null || !alsoBlock) return error;
    return block(person);
  }

  /// The people this account blocked; throws when they cannot be loaded.
  Future<List<SocialPerson>> blocked() async => SocialPerson.listFrom(
    (await _api.blockedPeople(await _token()))['blocked'],
  );

  /// A friend's profile and the collections they share, as the server has
  /// them now; throws when they are no longer a friend (or cannot be
  /// reached).
  Future<FriendPage> friend(String handle) async {
    final body = await _api.friend(await _token(), handle);
    final person = SocialPerson.fromJson(body['friend']);
    if (person == null) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    final collections = body['collections'];
    return (
      person: person,
      collections: collections is List
          ? [for (final entry in collections) ?SharedCollection.fromJson(entry)]
          : const <SharedCollection>[],
    );
  }

  /// One page of a friend's shared collection; [cursor] from the last page.
  /// Throws when it is no longer shared with this account.
  Future<SharedCollectionPage> sharedCollection(
    String handle,
    String id, {
    String? cursor,
  }) async {
    final body = await _api.friendCollection(
      await _token(),
      handle,
      id,
      cursor: cursor,
    );
    final items = body['items'];
    return (
      collection: SharedCollection.fromJson(body['collection']),
      titles: items is List
          ? [for (final entry in items) ?sharedTitleFrom(entry)]
          : const <MediaItem>[],
      cursor: body['cursor'] is String ? body['cursor'] as String : null,
    );
  }

  /// Forgets the list and its saved copy: Friends was turned off.
  Future<void> forget() async {
    final userId = _account.userId;
    _friends = _incoming = _outgoing = const [];
    _watching = const [];
    _cursor = null;
    _loaded = false;
    notifyListeners();
    if (userId == null) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove('$cachePrefix$userId');
    } catch (_) {
      // Nothing saved.
    }
  }

  Future<String?> _act(
    SocialPerson person,
    Future<void> Function(String token) call,
  ) async {
    final key = person.handle.toLowerCase();
    if (!_working.add(key)) return 'Try again in a moment.';
    notifyListeners();
    final userId = _account.userId;
    try {
      await call(await _token());
      if (userId != null && _current) unawaited(_save(userId));
      return null;
    } on AccountApiException catch (error) {
      // Gone already (answered elsewhere, unfriended): drop it here too.
      if (error.status == 404) {
        _friends = _without(_friends, person.handle);
        _withoutRequests(person.handle);
      }
      return SocialController.messageFor(error);
    } catch (_) {
      return 'Something went wrong. Try again later.';
    } finally {
      _working.remove(key);
      notifyListeners();
    }
  }

  Future<String> _token() async {
    final token = await _account.accessToken();
    if (token == null) throw const AccountApiException('missing_token', '');
    return token;
  }

  void _withoutRequests(String handle) {
    _incoming = _without(_incoming, handle);
    _outgoing = _without(_outgoing, handle);
  }

  static bool _has(List<SocialPerson> people, String handle) =>
      people.any((p) => p.handle.toLowerCase() == handle.toLowerCase());

  static List<SocialPerson> _without(List<SocialPerson> people, String h) => [
    for (final person in people)
      if (person.handle.toLowerCase() != h.toLowerCase()) person,
  ];

  static List<SocialPerson> _sorted(List<SocialPerson> people) => [...people]
    ..sort((a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()));

  Future<void> _save(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$cachePrefix$userId',
        jsonEncode({
          'friends': [for (final p in _friends.take(200)) p.toJson()],
          'incoming': [for (final p in _incoming) p.toJson()],
          'outgoing': [for (final p in _outgoing) p.toJson()],
        }),
      );
    } catch (_) {
      // Only a convenience.
    }
  }

  Future<void> _restore(String userId) async {
    _loadedFor = userId;
    _loaded = false;
    _friends = _incoming = _outgoing = const [];
    _watching = const [];
    _cursor = null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$cachePrefix$userId');
      if (saved == null) return;
      final decoded = jsonDecode(saved);
      if (decoded is! Map) return;
      _friends = SocialPerson.listFrom(decoded['friends']);
      _incoming = SocialPerson.listFrom(decoded['incoming']);
      _outgoing = SocialPerson.listFrom(decoded['outgoing']);
      _loaded = true;
    } catch (_) {
      // A damaged copy is ignored; the server's answer replaces it.
    }
  }
}
