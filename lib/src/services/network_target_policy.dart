/// Rejects insecure and local-network destinations for provider traffic.
/// Playback URLs are validated separately because some providers still serve
/// media over HTTP and must remain playable for compatibility.
bool isSafeProviderTarget(Uri uri) {
  if (uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty) {
    return false;
  }

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) {
    // Disallow IP literals. This blocks loopback, private, link-local,
    // unspecified, and IPv6 zone-address targets without DNS ambiguity.
    return false;
  }

  if (!host.contains('.') ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.test') ||
      host.endsWith('.invalid') ||
      host.endsWith('.example')) {
    return false;
  }

  return true;
}
