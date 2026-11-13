// Recommendations: titles friends sent this account (the inbox) and sending
// one to friends. The Reelish API checks every recipient and keeps the cards
// (backend/src/social/recommendations.ts); this asks, keeps the first page
// per account for offline display, and keeps the unread count in step.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../models/media_item.dart';
import 'friends_controller.dart';
import 'social_controller.dart';

/// Opens a title's details from Friends. Home sets it while it is up, as it
/// does for watch parties, so Friends pages need no route to Home.
abstract final class SocialTitles {
  static Future<void> Function(MediaItem item)? open;
}

/// The artwork addresses the server accepts on a card.
final _artwork = RegExp(
  r'^https://image\.tmdb\.org/t/p/(w\d{2,4}|original)/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$',
);

/// A title as a card carries it; null for titles that are not TMDB's.
Map<String, Object?>? cardOf(MediaItem item) {
  if (item.type != 'movie' && item.type != 'series') return null;
  if (!RegExp(r'^[1-9]\d{0,9}$').hasMatch(item.id)) return null;
  final year = item.year;
  final poster = item.poster;
  return {
    'type': item.type,
    'id': item.id,
    'title': item.name,
    if (RegExp(r'^\d{4}$').hasMatch(year)) 'year': year,
    if (_artwork.hasMatch(poster)) 'poster': poster,
  };
}

/// One title a friend sent.
@immutable
class Recommendation {
  const Recommendation({
    required this.id,
    required this.media,
    this.from,
    this.message,
    this.createdAt,
    this.read = false,
  });

  final String id;

  /// Null when the sender has since turned Friends off.
  final SocialPerson? from;
  final MediaItem media;
  final String? message;
  final DateTime? createdAt;
  final bool read;

  Recommendation markedRead() => Recommendation(
    id: id,
    media: media,
    from: from,
    message: message,
    createdAt: createdAt,
    read: true,
  );

  static Recommendation? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final media = value['media'];
    if (id is! String || media is! Map) return null;
    final type = media['type'];
    final mediaId = media['id'];
    final title = media['title'];
    if ((type != 'movie' && type != 'series') ||
        mediaId is! String ||
        title is! String) {
      return null;
    }
    final message = value['message'];
    final at = value['createdAt'];
    final year = media['year'];
    final poster = media['poster'];
    return Recommendation(
      id: id,
      from: SocialPerson.fromJson(value['from']),
      media: MediaItem(
        id: mediaId,
        type: type as String,
        name: title,
        year: year is String ? year : '',
        poster: poster is String ? poster : '',
      ),
      message: message is String && message.isNotEmpty ? message : null,
      createdAt: at is int
          ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)
          : null,
      read: value['read'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'from': from?.toJson(),
    'media': {
      'type': media.type,
      'id': media.id,
      'title': media.name,
      'year': media.year,
      'poster': media.poster,
    },
    'message': message,
    'createdAt': createdAt?.millisecondsSinceEpoch,
    'read': read,
  };
}

/// What a send did: who got it, and who it could not go to.
typedef ShareResult = ({
  String? error,
  List<String> sent,
  List<String> notSent,
});

/// A fresh idempotency key for one send; a retry of that send reuses it.
String newClientId() {
  final random = Random.secure();
  return List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
}

class RecommendationsController extends ChangeNotifier {
  RecommendationsController({
    AccountController? account,
    AccountApi? api,
    SocialController? social,
  }) : _account = account ?? AccountController.instance,
       _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _social = social ?? SocialController.instance;

  static final instance = RecommendationsController();

  static const cachePrefix = 'reelish.recommendations.v1.';

  final AccountController _account;
  final AccountApi _api;
  final SocialController _social;

  String? _loadedFor;
  bool _loaded = false;
  List<Recommendation> _items = const [];
  String? _cursor;
  bool _loading = false;
  bool _loadingMore = false;
  bool _failed = false;

  bool get _current => _loadedFor != null && _loadedFor == _account.userId;

  List<Recommendation> get items => _current ? _items : const [];
  bool get loaded => _current && _loaded;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get failed => _failed;
  bool get hasMore => _current && _cursor != null;

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
      final body = await _api.recommendations(await _token());
      if (_account.userId != userId) return;
      _items = _listFrom(body['items']);
      _cursor = body['cursor'] is String ? body['cursor'] as String : null;
      _loaded = true;
      if (body['unread'] case final int unread) _social.setUnread(unread);
      unawaited(_save(userId));
    } catch (_) {
      _failed = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    final userId = _account.userId;
    final cursor = _cursor;
    if (!_current || cursor == null || _loadingMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final body = await _api.recommendations(await _token(), cursor: cursor);
      if (_account.userId != userId) return;
      _items = [..._items, ..._listFrom(body['items'])];
      _cursor = body['cursor'] is String ? body['cursor'] as String : null;
    } catch (_) {
      // Show more stays; trying again is one tap.
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// Marks [only] read, or everything when null. Best effort: a failure
  /// leaves the dot for next time.
  Future<void> markRead([Recommendation? only]) async {
    final unread = [
      for (final item in _items)
        if (!item.read && (only == null || item.id == only.id)) item.id,
    ];
    if (!_current || (only != null && unread.isEmpty)) return;
    if (only == null && unread.isEmpty && _social.counts.unread == 0) return;
    _items = [
      for (final item in _items)
        unread.contains(item.id) ? item.markedRead() : item,
    ];
    if (only == null) {
      _social.setUnread(0);
    } else {
      _social.adjustCounts(unread: -1);
    }
    notifyListeners();
    try {
      await _api.markRecommendationsRead(
        await _token(),
        ids: only == null ? null : unread,
      );
      final userId = _account.userId;
      if (userId != null) unawaited(_save(userId));
    } catch (_) {
      // Shown as read here; the server catches up on the next open.
    }
  }

  /// The last titles this account sent, with [Recommendation.from] holding
  /// the friend it went to. Throws when they cannot be loaded.
  Future<List<Recommendation>> sentByMe() async {
    final body = await _api.sentRecommendations(await _token());
    final items = body['items'];
    if (items is! List) return const [];
    return [
      for (final entry in items)
        if (entry is Map)
          ?Recommendation.fromJson({
            ...entry,
            'from': entry['to'],
            'read': true,
          }),
    ];
  }

  /// Removes [item] from the inbox. Returns an error to show, or null.
  Future<String?> remove(Recommendation item) async {
    try {
      await _api.removeRecommendation(await _token(), item.id);
    } on AccountApiException catch (error) {
      if (error.status != 404) return SocialController.messageFor(error);
    } catch (_) {
      return 'Something went wrong. Try again later.';
    }
    _items = [
      for (final other in _items)
        if (other.id != item.id) other,
    ];
    if (!item.read) _social.adjustCounts(unread: -1);
    notifyListeners();
    final userId = _account.userId;
    if (userId != null) unawaited(_save(userId));
    return null;
  }

  /// Sends [item] to [recipients] (handles). [clientId] is the key for this
  /// send: pass the same one to retry it.
  Future<ShareResult> send(
    MediaItem item, {
    required List<String> recipients,
    required String clientId,
    String message = '',
  }) async {
    final card = cardOf(item);
    if (card == null) {
      return (
        error: 'This title cannot be shared.',
        sent: const <String>[],
        notSent: const <String>[],
      );
    }
    try {
      final body = await _api.sendRecommendation(
        await _token(),
        recipients: recipients,
        media: card,
        clientId: clientId,
        message: message.trim().isEmpty ? null : message.trim(),
      );
      List<String> handles(Object? value) => value is List
          ? [for (final handle in value) '$handle']
          : const <String>[];
      return (
        error: null,
        sent: handles(body['sent']),
        notSent: handles(body['notSent']),
      );
    } on AccountApiException catch (error) {
      return (
        error: SocialController.messageFor(error),
        sent: const <String>[],
        notSent: const <String>[],
      );
    } catch (_) {
      return (
        error: 'Something went wrong. Try again later.',
        sent: const <String>[],
        notSent: const <String>[],
      );
    }
  }

  /// Forgets the inbox and its saved copy: Friends was turned off.
  Future<void> forget() async {
    final userId = _account.userId;
    _items = const [];
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

  static List<Recommendation> _listFrom(Object? value) => value is List
      ? [for (final entry in value) ?Recommendation.fromJson(entry)]
      : const [];

  Future<String> _token() async {
    final token = await _account.accessToken();
    if (token == null) throw const AccountApiException('missing_token', '');
    return token;
  }

  Future<void> _save(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$cachePrefix$userId',
        jsonEncode([for (final item in _items.take(30)) item.toJson()]),
      );
    } catch (_) {
      // Only a convenience.
    }
  }

  Future<void> _restore(String userId) async {
    _loadedFor = userId;
    _loaded = false;
    _items = const [];
    _cursor = null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$cachePrefix$userId');
      if (saved == null) return;
      _items = _listFrom(jsonDecode(saved));
      _loaded = true;
    } catch (_) {
      // A damaged copy is ignored; the server's answer replaces it.
    }
  }
}
