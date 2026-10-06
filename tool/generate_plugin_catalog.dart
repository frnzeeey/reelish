// Regenerates assets/data/plugins.json from the community Nuvio Plugin
// Library (https://nuvio-plugin-library.vercel.app/).
//
//   dart run tool/generate_plugin_catalog.dart
//
// The library is a curated Notion table of provider repositories (name,
// manifest link, language). This script reads that table through the same
// endpoint the website uses, fetches every manifest for its scraper list, and
// asks GitHub/Codeberg when each manifest last changed. Nothing is invented:
// a value the source does not provide is written as null or omitted.
//
// Commit the regenerated file; the app downloads it from the repository's
// main branch on refresh and bundles it as the offline fallback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _libraryUrl = 'https://nuvio-plugin-library.vercel.app/';
const _notionPageId = '326981dcb87e80f6b9f6f23469a00fd3';
const _output = 'assets/data/plugins.json';

final _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'ReelishCatalogGenerator';

Future<void> main() async {
  final notion = await _getJson(
    Uri.parse('${_libraryUrl}api/notion/$_notionPageId'),
  );
  if (notion is! Map) throw const FormatException('Unexpected Notion payload');
  final rows = _tableRows(notion);
  if (rows.length < 2) throw const FormatException('Notion table is empty');

  final header = (rows.first['properties'] as Map?) ?? const {};
  String? repoKey, languageKey;
  for (final MapEntry(:key, :value) in header.entries) {
    final label = _text(value).toLowerCase();
    if (repoKey == null && label.contains('repo')) repoKey = '$key';
    if (languageKey == null && label.contains('language')) languageKey = '$key';
  }
  if (repoKey == null) throw const FormatException('Repo column not found');

  final usedIds = <String>{};
  final providers = <Map<String, Object?>>[];
  for (final row in rows.skip(1)) {
    final properties = (row['properties'] as Map?) ?? const {};
    final name = _text(properties[repoKey]);
    if (name.isEmpty) continue;
    final manifestUrl = _manifestUrl(_link(properties[repoKey]));
    final languages = _languages(
      languageKey == null ? '' : _text(properties[languageKey]),
    );
    var id = _slug(name);
    for (var n = 2; !usedIds.add(id); n++) {
      id = '${_slug(name)}-$n';
    }
    stdout.writeln('• $name');
    final manifest = manifestUrl.isEmpty
        ? null
        : await _tryGetJson(Uri.parse(manifestUrl));
    final repo = _repository(manifestUrl);
    providers.add({
      'id': id,
      'name': name,
      'author': repo?.owner,
      'languages': languages,
      'manifestUrl': manifestUrl.isEmpty ? null : manifestUrl,
      'repositoryUrl': repo?.webUrl,
      'repositoryName': manifest is Map ? _string(manifest['name']) : null,
      'manifestVersion': manifest is Map ? _string(manifest['version']) : null,
      'description': null,
      'iconUrl': null,
      'verified': false,
      'featured': false,
      'available': manifest is Map && manifest['scrapers'] is List,
      'lastUpdated': repo == null ? null : await _lastUpdated(repo),
      'scrapers': manifest is Map ? _scrapers(manifest['scrapers']) : [],
    });
  }

  final catalog = {
    'version': 1,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'source': {
      'name': 'Community Plugin Library',
      'url': _libraryUrl,
      'curator': 'wolf knight',
    },
    'providers': providers,
  };
  await File(
    _output,
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(catalog)}\n');
  final scraperTotal = providers.fold<int>(
    0,
    (sum, p) => sum + (p['scrapers'] as List).length,
  );
  stdout.writeln(
    'Wrote ${providers.length} providers, $scraperTotal scrapers to $_output',
  );
  _client.close();
}

/// Notion's record map nests block values one or two levels deep.
Map? _block(Object? entry) {
  if (entry is! Map) return null;
  final outer = entry['value'];
  final value = outer is Map
      ? (outer['value'] is Map ? outer['value'] : outer)
      : entry;
  return value is Map && value['type'] is String ? value : null;
}

List<Map> _tableRows(Map recordMap) {
  final blocks = <String, Map>{
    for (final MapEntry(:key, :value) in recordMap.entries)
      '$key': ?_block(value),
  };
  final table = blocks.values.where((b) => b['type'] == 'table').firstOrNull;
  final content = table?['content'];
  if (content is List) {
    return [
      for (final id in content)
        if (blocks['$id'] case final row? when row['type'] == 'table_row') row,
    ];
  }
  return blocks.values.where((b) => b['type'] == 'table_row').toList();
}

String _text(Object? value) => value is List
    ? value
          .map(
            (part) =>
                part is List && part.firstOrNull is String ? part.first : '',
          )
          .join()
          .trim()
    : '';

String _link(Object? value) {
  if (value is List) {
    for (final part in value) {
      if (part is List && part.length > 1 && part[1] is List) {
        for (final format in part[1] as List) {
          if (format is List &&
              format.firstOrNull == 'a' &&
              format[1] is String) {
            return format[1] as String;
          }
        }
      }
    }
  }
  final text = _text(value);
  return RegExp(r'^https?://', caseSensitive: false).hasMatch(text) ? text : '';
}

/// Same rule the library website applies: a directory link points at its
/// manifest.json.
String _manifestUrl(String raw) {
  final url = raw.trim();
  if (url.isEmpty || url.endsWith('/manifest.json')) return url;
  return url.endsWith('/') ? '${url}manifest.json' : url;
}

/// Normalizes spelling differences in the table's free-text language column
/// ("Multi language", "Portuguese (BR)", "Brazilian portuguese").
List<String> _languages(String raw) {
  const aliases = {
    'multi language': 'Multi Language',
    'multi-language': 'Multi Language',
    'multilanguage': 'Multi Language',
    'portuguese (br)': 'Brazilian Portuguese',
    'brazilian portuguese': 'Brazilian Portuguese',
    'pt-br': 'Brazilian Portuguese',
  };
  final parts = raw
      .split(RegExp(r'[|,/;+]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .map((part) {
        final alias = aliases[part.toLowerCase()];
        if (alias != null) return alias;
        return part
            .split(RegExp(r'\s+'))
            .map(
              (w) => w.isEmpty
                  ? w
                  : w[0].toUpperCase() + w.substring(1).toLowerCase(),
            )
            .join(' ');
      });
  return {...parts}.toList();
}

typedef _Repo = ({String host, String owner, String name, String? branch});

extension on _Repo {
  String get webUrl => 'https://$host/$owner/$name';
}

/// Owner and repository of a raw GitHub or Codeberg manifest link.
_Repo? _repository(String manifestUrl) {
  final uri = Uri.tryParse(manifestUrl);
  if (uri == null) return null;
  final s = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (uri.host == 'raw.githubusercontent.com' && s.length >= 3) {
    final branch = s[2] == 'refs' && s.length >= 5 ? s[4] : s[2];
    return (host: 'github.com', owner: s[0], name: s[1], branch: branch);
  }
  if (uri.host == 'codeberg.org') {
    if (s.length >= 5 && s[0] == 'api' && s[2] == 'repos') {
      return (host: 'codeberg.org', owner: s[3], name: s[4], branch: null);
    }
    if (s.length >= 2) {
      final branchIndex = s.indexOf('branch');
      return (
        host: 'codeberg.org',
        owner: s[0],
        name: s[1],
        branch: branchIndex >= 0 && branchIndex + 1 < s.length
            ? s[branchIndex + 1]
            : null,
      );
    }
  }
  return null;
}

/// Date of the latest commit that touched the repository's manifest.json.
Future<String?> _lastUpdated(_Repo repo) async {
  final Uri uri;
  if (repo.host == 'github.com') {
    uri = Uri.https(
      'api.github.com',
      '/repos/${repo.owner}/${repo.name}/commits',
      {
        'path': 'manifest.json',
        'per_page': '1',
        if (repo.branch != null) 'sha': repo.branch!,
      },
    );
  } else {
    uri = Uri.https(
      'codeberg.org',
      '/api/v1/repos/${repo.owner}/${repo.name}/commits',
      {
        'path': 'manifest.json',
        'limit': '1',
        if (repo.branch != null) 'sha': repo.branch!,
      },
    );
  }
  final commits = await _tryGetJson(uri);
  if (commits is! List || commits.isEmpty || commits.first is! Map) return null;
  final commit = (commits.first as Map)['commit'];
  final date = commit is Map
      ? ((commit['committer'] as Map?)?['date'] ??
            (commit['author'] as Map?)?['date'])
      : null;
  final parsed = DateTime.tryParse('${date ?? ''}');
  return parsed?.toUtc().toIso8601String();
}

List<Map<String, Object?>> _scrapers(Object? raw) => [
  if (raw is List)
    for (final (index, entry) in raw.indexed)
      if (entry is Map)
        {
          'id': _string(entry['id']) ?? 'scraper-$index',
          'name': _string(entry['name']) ?? 'Unnamed scraper',
          'description': ?_string(entry['description']),
          'logo': ?_string(entry['logo']),
          'supportedTypes': _strings(entry['supportedTypes']),
          'contentLanguage': _strings(entry['contentLanguage']),
          'formats': _strings(entry['formats']),
        },
];

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _strings(Object? value) =>
    value is List ? [for (final item in value) ?_string(item)] : const [];

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

Future<Object?> _tryGetJson(Uri uri) async {
  try {
    return await _getJson(uri);
  } catch (error) {
    stderr.writeln('  ! $uri: $error');
    return null;
  }
}

Future<Object?> _getJson(Uri uri) async {
  final request = await _client.getUrl(uri);
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close().timeout(const Duration(seconds: 30));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  return jsonDecode(body);
}
