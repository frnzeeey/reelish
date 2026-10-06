/// The community plugin catalog shown in the Plugin Library.
///
/// The catalog only *describes* provider repositories. Nothing here is
/// executed: installing a listed repository goes through
/// [ProviderPluginService.install], which applies the app's own manifest
/// validation, network policy and sandboxed runtime.
///
/// All values come from untrusted JSON, so parsing never throws for a bad
/// entry; malformed providers and scrapers are skipped instead.
class PluginCatalog {
  const PluginCatalog({
    required this.version,
    required this.providers,
    this.updatedAt,
    this.sourceName,
    this.sourceUrl,
    this.curator,
  });

  static const supportedVersion = 1;
  static const _maxProviders = 2000;

  final int version;
  final DateTime? updatedAt;
  final String? sourceName;
  final Uri? sourceUrl;
  final String? curator;
  final List<ReelishPlugin> providers;

  /// Parses a catalog document, or throws [FormatException] when the
  /// document as a whole is unusable.
  factory PluginCatalog.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Catalog is not an object.');
    final version = json['version'];
    if (version is! int || version < 1 || version > supportedVersion) {
      throw FormatException('Unsupported catalog version: $version');
    }
    final rawProviders = json['providers'];
    if (rawProviders is! List) {
      throw const FormatException('Catalog has no provider list.');
    }
    final source = json['source'];
    final providers = <ReelishPlugin>[];
    final ids = <String>{};
    for (final (index, entry) in rawProviders.take(_maxProviders).indexed) {
      final plugin = ReelishPlugin.tryParse(entry, catalogIndex: index);
      if (plugin != null && ids.add(plugin.id)) providers.add(plugin);
    }
    return PluginCatalog(
      version: version,
      updatedAt: _date(json['updatedAt']),
      sourceName: source is Map ? _text(source['name']) : null,
      sourceUrl: source is Map ? _httpsUri(source['url']) : null,
      curator: source is Map ? _text(source['curator']) : null,
      providers: List.unmodifiable(providers),
    );
  }
}

/// One community provider repository (a provider manifest).
class ReelishPlugin {
  ReelishPlugin({
    required this.id,
    required this.name,
    required this.languages,
    required this.scrapers,
    this.author,
    this.manifestUrl,
    this.repositoryUrl,
    this.repositoryName,
    this.manifestVersion,
    this.description,
    this.iconUrl,
    this.verified = false,
    this.featured = false,
    this.available = true,
    this.lastUpdated,
    this.catalogIndex = 0,
  });

  static const _maxScrapers = 500;

  final String id;
  final String name;

  /// Null when the source does not identify an author.
  final String? author;

  /// Catalog language labels, e.g. "Multi Language" or "Turkish".
  final List<String> languages;
  final List<PluginScraper> scrapers;

  /// Null when the catalog has no usable HTTPS manifest link.
  final Uri? manifestUrl;
  final Uri? repositoryUrl;
  final String? repositoryName;
  final String? manifestVersion;
  final String? description;
  final Uri? iconUrl;
  final bool verified;
  final bool featured;

  /// False when the manifest could not be read when the catalog was built.
  final bool available;
  final DateTime? lastUpdated;

  /// Position in the curated source list, used as a stable tie-breaker.
  final int catalogIndex;

  int get scraperCount => scrapers.length;

  /// The first language label, used where only one fits.
  String get language => languages.isEmpty ? 'Unknown' : languages.first;

  bool get isMultiLanguage =>
      languages.any((label) => label.toLowerCase() == 'multi language');

  /// Content types any scraper declares (`movie`, `tv`, `anime`).
  late final Set<String> contentTypes = {
    for (final scraper in scrapers) ...scraper.contentTypes,
  };

  /// Lower-cased text the library search matches against.
  late final String searchText = [
    name,
    author ?? '',
    repositoryName ?? '',
    ...languages,
    for (final scraper in scrapers) scraper.name,
  ].join('\n').toLowerCase();

  static ReelishPlugin? tryParse(Object? json, {int catalogIndex = 0}) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final name = _text(json['name']);
    if (id == null || name == null) return null;
    final rawScrapers = json['scrapers'];
    return ReelishPlugin(
      id: id,
      name: name,
      author: _text(json['author']),
      languages: List.unmodifiable(_texts(json['languages'])),
      scrapers: List.unmodifiable([
        if (rawScrapers is List)
          for (final entry in rawScrapers.take(_maxScrapers))
            ?PluginScraper.tryParse(entry),
      ]),
      manifestUrl: _httpsUri(json['manifestUrl']),
      repositoryUrl: _httpsUri(json['repositoryUrl']),
      repositoryName: _text(json['repositoryName']),
      manifestVersion: _text(json['manifestVersion']),
      description: _text(json['description']),
      iconUrl: _httpsUri(json['iconUrl']),
      verified: json['verified'] == true,
      featured: json['featured'] == true,
      available: json['available'] != false,
      lastUpdated: _date(json['lastUpdated']),
      catalogIndex: catalogIndex,
    );
  }
}

/// One scraper (source) inside a provider manifest.
class PluginScraper {
  const PluginScraper({
    required this.id,
    required this.name,
    this.description,
    this.logoUrl,
    this.supportedTypes = const [],
    this.contentLanguages = const [],
    this.formats = const [],
  });

  final String id;
  final String name;
  final String? description;
  final Uri? logoUrl;
  final List<String> supportedTypes;
  final List<String> contentLanguages;
  final List<String> formats;

  /// [supportedTypes] normalized to `movie`, `tv` and `anime`.
  Set<String> get contentTypes => {
    for (final type in supportedTypes)
      switch (type.toLowerCase()) {
        'tv' || 'series' || 'show' || 'shows' => 'tv',
        'movie' || 'movies' || 'film' => 'movie',
        final other => other,
      },
  };

  static PluginScraper? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final name = _text(json['name']);
    if (id == null || name == null) return null;
    return PluginScraper(
      id: id,
      name: name,
      description: _text(json['description']),
      logoUrl: _httpsUri(json['logo']),
      supportedTypes: List.unmodifiable(_texts(json['supportedTypes'])),
      contentLanguages: List.unmodifiable(_texts(json['contentLanguage'])),
      formats: List.unmodifiable(_texts(json['formats'])),
    );
  }
}

const _maxTextLength = 600;

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > _maxTextLength
      ? trimmed.substring(0, _maxTextLength)
      : trimmed;
}

List<String> _texts(Object? value) => [
  if (value is List)
    for (final item in value.take(50)) ?_text(item),
];

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// Only absolute HTTPS links with a hostname are kept; anything else in the
/// untrusted catalog is treated as missing.
Uri? _httpsUri(Object? value) {
  final text = _text(value);
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
