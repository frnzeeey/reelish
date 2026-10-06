import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/plugin_catalog.dart';
import '../services/plugin_library_query.dart';
import '../services/provider_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/plugin_library/copy_manifest_button.dart';
import '../widgets/plugin_library/plugin_badges.dart';
import '../widgets/plugin_library/plugin_formatting.dart';
import '../widgets/plugin_library/plugin_install_button.dart';
import '../widgets/plugin_library/plugin_library_notices.dart';
import '../widgets/plugin_library/plugin_logo.dart';
import '../widgets/plugin_library/plugin_scraper_tile.dart';

class PluginDetailsScreen extends StatelessWidget {
  const PluginDetailsScreen({
    super.key,
    required this.plugin,
    required this.pluginService,
    this.catalog,
  });

  final ReelishPlugin plugin;
  final ProviderPluginService pluginService;
  final PluginCatalog? catalog;

  static const _maxContentWidth = 760.0;

  Future<void> _openRepository(BuildContext context, Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the repository.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = [
      for (final type in PluginContentType.values)
        if (plugin.contentTypes.contains(type.name)) type.label,
    ];
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: CustomScrollView(
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverToBoxAdapter(
              child: _constrained(
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 20, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back to Reelish Plugins',
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(Symbols.arrow_back_rounded),
                      ),
                      const Text(
                        'Reelish Plugins',
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _constrained(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Hero(
                      plugin: plugin,
                      pluginService: pluginService,
                      types: types,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: PluginInstallButton(
                            plugin: plugin,
                            pluginService: pluginService,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: CopyManifestButton(
                              manifestUrl: plugin.manifestUrl,
                              pluginName: plugin.name,
                              filled: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!plugin.available) ...[
                      const SizedBox(height: 12),
                      const _Note(
                        message:
                            'This manifest could not be reached when the catalog was last '
                            'updated. Installing checks it again and reports any problem.',
                      ),
                    ],
                    if (plugin.description case final description?) ...[
                      const _Heading('Description'),
                      Text(
                        description,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.5,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const _Heading('Information'),
                    _InfoTable(
                      rows: [
                        ('Author', plugin.author ?? 'Unavailable'),
                        (
                          'Languages',
                          plugin.languages.isEmpty
                              ? 'Unknown'
                              : plugin.languages.join(', '),
                        ),
                        (
                          'Sources',
                          plugin.available
                              ? '${plugin.scraperCount}'
                              : 'Unavailable',
                        ),
                        if (plugin.repositoryName case final name?)
                          ('Repository', name),
                        if (plugin.manifestVersion case final version?)
                          ('Version', version),
                        (
                          'Last updated',
                          plugin.lastUpdated == null
                              ? 'Unavailable'
                              : '${formatPluginDate(plugin.lastUpdated!)} (${relativePluginDate(plugin.lastUpdated!)})',
                        ),
                        (
                          'Verification',
                          plugin.verified
                              ? 'Verified'
                              : 'Not verified, community provider',
                        ),
                        if (catalog?.sourceName case final source?)
                          ('Listed in', source),
                      ],
                    ),
                    if (plugin.repositoryUrl case final repositoryUrl?) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () =>
                              _openRepository(context, repositoryUrl),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                          icon: const Icon(
                            Symbols.open_in_new_rounded,
                            size: 18,
                          ),
                          label: const Text('View repository'),
                        ),
                      ),
                    ],
                    const _Heading('Manifest'),
                    _ManifestBox(plugin: plugin),
                    const SizedBox(height: 14),
                    const PluginSafetyNotice(),
                    _Heading(
                      'Sources',
                      detail: plugin.available
                          ? '${plugin.scraperCount}'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (plugin.scrapers.isEmpty)
            SliverToBoxAdapter(
              child: _constrained(
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'The source list is unavailable for this provider.',
                    style: TextStyle(color: GlassTheme.muted, fontSize: 13),
                  ),
                ),
              ),
            )
          else
            // Built lazily, so source logos load only as they scroll in.
            SliverList.builder(
              itemCount: plugin.scrapers.length,
              itemBuilder: (context, index) => _constrained(
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: PluginScraperTile(scraper: plugin.scrapers[index]),
                ),
              ),
            ),
          const SliverToBoxAdapter(
            child: SafeArea(top: false, child: SizedBox(height: 32)),
          ),
        ],
      ),
    );
  }

  static Widget _constrained(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxContentWidth),
      child: child,
    ),
  );
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.plugin,
    required this.pluginService,
    required this.types,
  });

  final ReelishPlugin plugin;
  final ProviderPluginService pluginService;
  final List<String> types;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          GlassTheme.primary.withValues(alpha: .22),
          const Color(0xFF191923),
          const Color(0xFF121219),
        ],
      ),
      border: Border.all(color: GlassTheme.primary.withValues(alpha: .2)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PluginLogo(
              name: plugin.name,
              url: plugin.iconUrl,
              size: 68,
              radius: 21,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      plugin.name,
                      style: const TextStyle(
                        fontSize: 26,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plugin.author == null
                        ? 'Author unavailable'
                        : 'by ${plugin.author}',
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: pluginService,
              builder: (context, _) => PluginStatusBadges(
                plugin: plugin,
                installed: PluginInstallButton.isInstalled(
                  pluginService,
                  plugin.manifestUrl,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            PluginMetaPill(
              icon: Symbols.translate_rounded,
              label: plugin.languages.isEmpty
                  ? 'Unknown'
                  : plugin.languages.join(' · '),
            ),
            PluginMetaPill(
              icon: plugin.available
                  ? Symbols.stacks_rounded
                  : Symbols.cloud_off_rounded,
              label: plugin.available
                  ? '${plugin.scraperCount} ${plugin.scraperCount == 1 ? 'source' : 'sources'}'
                  : 'Sources unavailable',
              accent: plugin.available,
            ),
            if (types.isNotEmpty)
              PluginMetaPill(
                icon: Symbols.movie_rounded,
                label: types.join(' · '),
              ),
          ],
        ),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 10),
    child: Semantics(
      header: true,
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Text(
              detail!,
              style: TextStyle(
                color: GlassTheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _InfoTable extends StatelessWidget {
  const _InfoTable({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Column(
      children: [
        for (final (index, (label, value)) in rows.indexed) ...[
          if (index > 0) const Divider(height: 1, color: GlassTheme.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

class _ManifestBox extends StatelessWidget {
  const _ManifestBox({required this.plugin});

  final ReelishPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final url = plugin.manifestUrl;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GlassTheme.border),
      ),
      child: Row(
        children: [
          const Icon(Symbols.link_rounded, size: 18, color: GlassTheme.muted),
          const SizedBox(width: 10),
          Expanded(
            child: url == null
                ? const Text(
                    'No manifest URL is available.',
                    style: TextStyle(color: GlassTheme.muted, fontSize: 12),
                  )
                : SelectableText(
                    url.toString(),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Colors.white70,
                    ),
                  ),
          ),
          if (url != null)
            IconButton(
              tooltip: 'Copy manifest URL',
              onPressed: () => CopyManifestButton.copy(context, url),
              icon: const Icon(Symbols.content_copy_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

/// An inline warning note.
class _Note extends StatelessWidget {
  const _Note({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB547).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFFFB547).withValues(alpha: .2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Symbols.info_rounded, size: 18, color: Color(0xFFFFB547)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    ),
  );
}
