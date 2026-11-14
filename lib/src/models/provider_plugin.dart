/// One provider (scraper) listed in an installed repository's manifest.
///
/// Everything here comes from the repository's untrusted manifest. The
/// optional fields describe what the provider *declares* (its version,
/// author, formats, platforms); nothing in them is verified, and parsing
/// drops values of the wrong type instead of throwing.
class ProviderPlugin {
  const ProviderPlugin({
    required this.id,
    required this.name,
    required this.filename,
    this.description = '',
    this.supportedTypes = const ['movie', 'tv'],
    this.priority = 0,
    this.enabled = true,
    this.defaultEnabled = true,
    this.version,
    this.author,
    this.logoUrl,
    this.formats = const [],
    this.contentLanguages = const [],
    this.disabledPlatforms = const [],
    this.hasSettings = false,
  });

  final String id, name, filename, description;
  final List<String> supportedTypes;
  final int priority;

  /// Whether Reelish searches this provider: the viewer's choice when they
  /// made one, otherwise the default the service derives.
  final bool enabled;

  /// The manifest's own `enabled` value, before any choice or platform rule.
  final bool defaultEnabled;

  final String? version;

  /// The author the manifest names. Not verified.
  final String? author;

  /// An HTTPS logo link from the manifest, or null.
  final Uri? logoUrl;

  /// Stream formats the provider declares (`m3u8`, `mp4`, `mkv`, …).
  final List<String> formats;

  /// Language codes of the content it finds (`en`, `hi`, …).
  final List<String> contentLanguages;

  /// Platforms the author says it does not work on (`tv`, `ios`, …).
  final List<String> disabledPlatforms;

  /// The provider has settings in other apps. Reelish has no provider
  /// settings, so it runs with an empty `SCRAPER_SETTINGS`.
  final bool hasSettings;

  ProviderPlugin copyWith({bool? enabled}) => ProviderPlugin(
    id: id,
    name: name,
    filename: filename,
    description: description,
    supportedTypes: supportedTypes,
    priority: priority,
    enabled: enabled ?? this.enabled,
    defaultEnabled: defaultEnabled,
    version: version,
    author: author,
    logoUrl: logoUrl,
    formats: formats,
    contentLanguages: contentLanguages,
    disabledPlatforms: disabledPlatforms,
    hasSettings: hasSettings,
  );

  factory ProviderPlugin.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'] != false;
    return ProviderPlugin(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? 'Provider'}',
      filename: '${json['filename'] ?? json['file'] ?? json['script'] ?? ''}',
      description: '${json['description'] ?? ''}',
      supportedTypes: (json['supportedTypes'] as List? ?? const ['movie', 'tv'])
          .map((type) => '$type')
          .toList(),
      priority: int.tryParse('${json['priority'] ?? 0}') ?? 0,
      enabled: enabled,
      defaultEnabled: enabled,
      version: _text(json['version'], 40),
      author: _text(json['author'], 120),
      logoUrl: _httpsUri(json['logo']),
      formats: _texts(json['formats']),
      contentLanguages: _texts(json['contentLanguage']),
      disabledPlatforms: _texts(json['disabledPlatforms']),
      hasSettings: json['hasSettings'] == true,
    );
  }
}

class ProviderRepository {
  const ProviderRepository({
    required this.url,
    required this.name,
    this.plugins = const [],
    this.version,
  });

  final String url, name;
  final List<ProviderPlugin> plugins;

  /// The manifest's top-level `version`, when it has one.
  final String? version;

  /// The same repository with [plugins] replaced.
  ProviderRepository withPlugins(List<ProviderPlugin> plugins) =>
      ProviderRepository(
        url: url,
        name: name,
        plugins: plugins,
        version: version,
      );

  factory ProviderRepository.fromJson(
    String url,
    String name,
    List<dynamic> json, {
    Object? version,
  }) => ProviderRepository(
    url: url,
    name: name,
    version: _text(version, 40),
    plugins: json
        .whereType<Map>()
        .map(
          (entry) => ProviderPlugin.fromJson(Map<String, dynamic>.from(entry)),
        )
        .where((plugin) => plugin.id.isNotEmpty && plugin.filename.isNotEmpty)
        .toList(),
  );
}

String? _text(Object? value, int maxLength) {
  if (value is! String && value is! num) return null;
  final trimmed = '$value'.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > maxLength ? trimmed.substring(0, maxLength) : trimmed;
}

List<String> _texts(Object? value) => [
  if (value is List)
    for (final item in value.take(20)) ?_text(item, 40),
];

/// Only absolute HTTPS links with a host and no credentials.
Uri? _httpsUri(Object? value) {
  final text = _text(value, 600);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}
