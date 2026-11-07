// Trakt's avatar URL, checked on the device the way the Reelish API checks it
// (backend/src/trakt.ts, cleanAvatarUrl): HTTPS on Trakt's image hosts or
// Gravatar, with no credentials or unusual port, and never Trakt's stand-in
// picture. A remote value, so it is checked before anything loads it.

final _avatarHost = RegExp(
  r'^(?:[a-z0-9-]+\.)*trakt\.tv$|^(?:secure\.)?gravatar\.com$',
);

/// [value] when it is a Trakt avatar URL, else null. A Gravatar link gets
/// `d=404`, so a missing Gravatar fails (the initial shows) rather than
/// showing Trakt's stand-in.
String? cleanTraktAvatarUrl(Object? value) {
  if (value is! String || value.isEmpty || value.length > 500) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      !_avatarHost.hasMatch(uri.host) ||
      uri.path.contains('/placeholders/')) {
    return null;
  }
  if (uri.host.endsWith('gravatar.com')) {
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'd': '404'})
        .toString();
  }
  return value;
}
