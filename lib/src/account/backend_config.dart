// Where the Reelish API lives. Set at build time with
// --dart-define=REELISH_API_URL=https://...; it is an address, not a secret.

abstract final class BackendConfig {
  static const _apiUrl = String.fromEnvironment('REELISH_API_URL');

  /// The API origin, or null when this build was made without one (then
  /// sign-in and the catalog report that the service is not configured).
  static Uri? get apiUrl => parse(_apiUrl);

  /// HTTPS only. Local hosts are refused by the app's network policy
  /// anyway, so development uses a staging deployment.
  static Uri? parse(String value) {
    final uri = Uri.tryParse(value.trim().replaceFirst(RegExp(r'/+$'), ''));
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) return null;
    return uri.scheme == 'https' ? uri : null;
  }

  static const _shareUrl = String.fromEnvironment(
    'REELISH_SHARE_URL',
    defaultValue: 'https://reelishofficial.netlify.app',
  );

  /// Where shared links and QR codes point (Reelish Connect): the website,
  /// which forwards them to the Reelish API's link pages (its
  /// netlify.toml). The pages read nothing, so every build can use the one
  /// address. Null without a valid HTTPS address.
  static Uri? get shareUrl => parse(_shareUrl);

  /// Base URL of the TMDB gateway, which mirrors TMDB's v3 paths.
  static String get tmdbBaseUrl {
    final api = apiUrl;
    return api == null ? '' : '$api/api/v1/tmdb';
  }
}
