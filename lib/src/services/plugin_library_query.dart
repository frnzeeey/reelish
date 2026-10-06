import '../models/plugin_catalog.dart';

enum PluginSort {
  recommended('Recommended'),
  name('Name'),
  author('Author'),
  scraperCount('Source count'),
  recentlyUpdated('Recently updated');

  const PluginSort(this.label);
  final String label;
}

/// Content types scrapers declare in their manifests.
enum PluginContentType {
  movie('Movies'),
  tv('TV Shows'),
  anime('Anime');

  const PluginContentType(this.label);
  final String label;
}

/// The search, filters and sort chosen in the Plugin Library.
class PluginLibraryQuery {
  const PluginLibraryQuery({
    this.search = '',
    this.language,
    this.contentType,
    this.sort = PluginSort.recommended,
  });

  final String search;

  /// A catalog language label; null means every language.
  final String? language;

  /// Null means every content type.
  final PluginContentType? contentType;
  final PluginSort sort;

  bool get hasFilters =>
      search.trim().isNotEmpty || language != null || contentType != null;

  PluginLibraryQuery copyWith({
    String? search,
    String? Function()? language,
    PluginContentType? Function()? contentType,
    PluginSort? sort,
  }) => PluginLibraryQuery(
    search: search ?? this.search,
    language: language == null ? this.language : language(),
    contentType: contentType == null ? this.contentType : contentType(),
    sort: sort ?? this.sort,
  );

  PluginLibraryQuery cleared() => PluginLibraryQuery(sort: sort);

  /// Filters and sorts [plugins]. The input list is never modified.
  List<ReelishPlugin> apply(List<ReelishPlugin> plugins) {
    final terms = search
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final selectedLanguage = language?.toLowerCase();
    final selectedType = contentType?.name;
    final results = [
      for (final plugin in plugins)
        if ((selectedLanguage == null ||
                plugin.languages.any(
                  (label) => label.toLowerCase() == selectedLanguage,
                )) &&
            (selectedType == null ||
                plugin.contentTypes.contains(selectedType)) &&
            terms.every(plugin.searchText.contains))
          plugin,
    ];
    results.sort(_comparator(sort));
    return results;
  }

  static int Function(ReelishPlugin, ReelishPlugin) _comparator(
    PluginSort sort,
  ) {
    int byCatalog(ReelishPlugin a, ReelishPlugin b) =>
        a.catalogIndex.compareTo(b.catalogIndex);
    int byText(String? a, String? b) {
      // Missing values sort last instead of first.
      if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    }

    int byDate(ReelishPlugin a, ReelishPlugin b) {
      final left = a.lastUpdated, right = b.lastUpdated;
      if (left == null || right == null) {
        return left == null ? (right == null ? 0 : 1) : -1;
      }
      return right.compareTo(left);
    }

    int then(int first, int Function() next) => first != 0 ? first : next();
    int flag(bool a, bool b) => a == b ? 0 : (a ? -1 : 1);

    return switch (sort) {
      PluginSort.recommended => (a, b) => then(
        flag(a.featured, b.featured),
        () => then(
          flag(a.verified, b.verified),
          () => then(
            // A manifest that answered beats one that did not.
            flag(a.available, b.available),
            () => then(
              b.scraperCount.compareTo(a.scraperCount),
              () => then(byDate(a, b), () => byCatalog(a, b)),
            ),
          ),
        ),
      ),
      PluginSort.name => (a, b) => then(
        byText(a.name, b.name),
        () => byCatalog(a, b),
      ),
      PluginSort.author => (a, b) => then(
        byText(a.author, b.author),
        () => byCatalog(a, b),
      ),
      PluginSort.scraperCount => (a, b) => then(
        b.scraperCount.compareTo(a.scraperCount),
        () => byCatalog(a, b),
      ),
      PluginSort.recentlyUpdated => (a, b) => then(
        byDate(a, b),
        () => byCatalog(a, b),
      ),
    };
  }
}

/// Totals shown in the library header, derived from the catalog.
class PluginLibraryStats {
  const PluginLibraryStats({
    required this.providerCount,
    required this.sourceCount,
    required this.languageCount,
  });

  factory PluginLibraryStats.of(List<ReelishPlugin> plugins) {
    final languages = <String>{};
    for (final plugin in plugins) {
      for (final scraper in plugin.scrapers) {
        for (final code in scraper.contentLanguages) {
          if (PluginLanguages.nameFor(code) case final name?) {
            languages.add(name);
          }
        }
      }
    }
    return PluginLibraryStats(
      providerCount: plugins.length,
      sourceCount: plugins.fold(0, (sum, plugin) => sum + plugin.scraperCount),
      languageCount: languages.length,
    );
  }

  final int providerCount;
  final int sourceCount;

  /// Distinct, recognized content languages declared by scrapers.
  final int languageCount;
}

/// Filter options present in the catalog, so no empty filter is offered.
class PluginLibraryFacets {
  const PluginLibraryFacets({
    required this.languages,
    required this.contentTypes,
  });

  factory PluginLibraryFacets.of(List<ReelishPlugin> plugins) {
    final counts = <String, int>{};
    final labels = <String, String>{};
    for (final plugin in plugins) {
      for (final label in plugin.languages) {
        final key = label.toLowerCase();
        labels.putIfAbsent(key, () => label);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    // Multi Language first, then the most common, then alphabetical.
    final languages = labels.keys.toList()
      ..sort((a, b) {
        if (a == 'multi language' || b == 'multi language') {
          return a == 'multi language' ? -1 : 1;
        }
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    final types = {for (final plugin in plugins) ...plugin.contentTypes};
    return PluginLibraryFacets(
      languages: [for (final key in languages) labels[key]!],
      contentTypes: [
        for (final type in PluginContentType.values)
          if (types.contains(type.name)) type,
      ],
    );
  }

  final List<String> languages;
  final List<PluginContentType> contentTypes;
}

/// Display names for the language codes scrapers declare.
///
/// Manifests use a mix of ISO 639-1, ISO 639-2 and informal codes, so a few
/// aliases are normalized. Unrecognized codes are shown as written and are
/// not counted as languages.
abstract final class PluginLanguages {
  static const _names = {
    'ar': 'Arabic',
    'bn': 'Bengali',
    'cs': 'Czech',
    'de': 'German',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'hi': 'Hindi',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'kn': 'Kannada',
    'ko': 'Korean',
    'ml': 'Malayalam',
    'pa': 'Punjabi',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ta': 'Tamil',
    'te': 'Telugu',
    'th': 'Thai',
    'tr': 'Turkish',
    'zh': 'Chinese',
  };
  static const _aliases = {
    'hin': 'hi',
    'tam': 'ta',
    'tel': 'te',
    'mal': 'ml',
    'ita': 'it',
    'jp': 'ja',
    'ben': 'bn',
    'kan': 'kn',
    'spa': 'es',
    'fra': 'fr',
    'fre': 'fr',
    'ger': 'de',
    'deu': 'de',
    'por': 'pt',
    'tur': 'tr',
    'ara': 'ar',
    'eng': 'en',
  };

  static String? nameFor(String code) {
    final key = code.trim().toLowerCase();
    return _names[_aliases[key] ?? key];
  }

  static String label(String code) => nameFor(code) ?? code.toUpperCase();
}

/// The first [count] scrapers to preview for [plugin], with those matching
/// [search] first so a search result shows why it matched.
List<PluginScraper> previewScrapers(
  ReelishPlugin plugin, {
  String search = '',
  int count = 3,
}) {
  final terms = search
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList();
  if (terms.isEmpty) return plugin.scrapers.take(count).toList();
  bool matches(PluginScraper scraper) {
    final name = scraper.name.toLowerCase();
    return terms.any(name.contains);
  }

  return [
    ...plugin.scrapers.where(matches),
    ...plugin.scrapers.where((scraper) => !matches(scraper)),
  ].take(count).toList();
}
