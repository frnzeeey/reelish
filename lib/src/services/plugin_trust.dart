// Where an installed provider repository comes from and how much Reelish
// knows about it. Trust is never inferred from a repository being reachable
// or popular: only the Reelish catalog (fetched from the app's own GitHub
// repository) can mark a publisher verified, and only per manifest URL.
import '../models/plugin_catalog.dart';

enum PluginSourceTrust {
  /// Listed in the Reelish catalog with `verified: true`: the catalog
  /// maintainer confirmed who publishes this manifest. Says nothing about
  /// whether its code is safe.
  verified(
    'Verified publisher',
    'The Reelish catalog confirms who publishes this repository. That is a '
        'statement about the publisher, not a review of the code: its '
        'providers still run as third-party code.',
  ),

  /// In the Reelish catalog, publisher not verified.
  listed(
    'Listed in the catalog',
    'This repository is in the community catalog Reelish shows. Being listed '
        'means someone added it to the catalog. Nobody has verified its '
        'publisher or reviewed its code.',
  ),

  /// Installed by link; not in the catalog.
  unlisted(
    'Added by link',
    'You added this repository by its link and it is not in the Reelish '
        'catalog, so Reelish knows nothing about who runs it. Keep it only if '
        'you trust where the link came from.',
  ),

  /// The catalog has not loaded yet, so listed and unlisted cannot be told
  /// apart.
  unknown(
    'Source not checked',
    'Reelish could not read its plugin catalog yet, so it cannot tell '
        'whether this repository is listed there.',
  );

  const PluginSourceTrust(this.label, this.explanation);
  final String label;
  final String explanation;

  static PluginSourceTrust of(String manifestUrl, PluginCatalog? catalog) {
    if (catalog == null) return PluginSourceTrust.unknown;
    final entry = catalogEntry(manifestUrl, catalog);
    if (entry == null) return PluginSourceTrust.unlisted;
    return entry.verified
        ? PluginSourceTrust.verified
        : PluginSourceTrust.listed;
  }

  /// The catalog provider whose manifest is exactly [manifestUrl]. Exact
  /// match on purpose: a look-alike URL on another account is not listed.
  static ReelishPlugin? catalogEntry(
    String manifestUrl,
    PluginCatalog catalog,
  ) {
    for (final plugin in catalog.providers) {
      if (plugin.manifestUrl?.toString() == manifestUrl) return plugin;
    }
    return null;
  }
}

/// Who hosts a manifest, read from its address alone. The account name is
/// what the host shows, not a verified identity.
class PluginHost {
  const PluginHost({required this.service, this.account, this.project});

  /// "GitHub", "Codeberg" or the host name.
  final String service;
  final String? account;
  final String? project;

  /// "GitHub · yoruix/nuvio-providers" or just the host.
  String get label => [
    service,
    if (account != null) [account, ?project].join('/'),
  ].join(' · ');

  static PluginHost of(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return const PluginHost(service: '—');
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    switch (host) {
      case 'raw.githubusercontent.com' || 'github.com' || 'www.github.com':
        return PluginHost(
          service: 'GitHub',
          account: segments.elementAtOrNull(0),
          project: segments.elementAtOrNull(1),
        );
      case 'gist.githubusercontent.com':
        return PluginHost(
          service: 'GitHub Gist',
          account: segments.elementAtOrNull(0),
        );
      case 'codeberg.org':
        // /api/v1/repos/<owner>/<repo>/raw/… or /<owner>/<repo>/raw/…
        final offset = segments.length > 3 && segments[0] == 'api' ? 3 : 0;
        return PluginHost(
          service: 'Codeberg',
          account: segments.elementAtOrNull(offset),
          project: segments.elementAtOrNull(offset + 1),
        );
      default:
        return PluginHost(service: host);
    }
  }
}
