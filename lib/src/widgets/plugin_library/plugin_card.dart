import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/plugin_catalog.dart';
import '../../services/plugin_library_query.dart';
import '../../theme/glass_theme.dart';
import 'copy_manifest_button.dart';
import 'plugin_badges.dart';
import 'plugin_logo.dart';

/// A provider in the library grid. Layout is fixed-height so the grid can
/// lay out hundreds of entries lazily.
class PluginCard extends StatefulWidget {
  const PluginCard({
    super.key,
    required this.plugin,
    required this.onOpen,
    this.search = '',
    this.installed = false,
  });

  static const height = 254.0;

  /// [height] grown with the text size, so large accessibility text fits.
  static double heightFor(BuildContext context) =>
      height *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 1.6);

  final ReelishPlugin plugin;
  final VoidCallback onOpen;
  final String search;
  final bool installed;

  @override
  State<PluginCard> createState() => _PluginCardState();
}

class _PluginCardState extends State<PluginCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final preview = previewScrapers(plugin, search: widget.search);
    final remaining = plugin.scraperCount - preview.length;
    final sourcesLabel = plugin.available
        ? '${plugin.scraperCount} ${plugin.scraperCount == 1 ? 'source' : 'sources'}'
        : 'Sources unavailable';
    return Semantics(
      container: true,
      label:
          '${plugin.name}${plugin.author == null ? '' : ', by ${plugin.author}'}, '
          '${plugin.languages.join(', ')}, $sourcesLabel'
          '${widget.installed ? ', installed' : ''}',
      child: AnimatedScale(
        scale: _pressed ? .985 : 1,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: GlassTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: widget.installed
                  ? GlassTheme.primary.withValues(alpha: .3)
                  : GlassTheme.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            onHighlightChanged: (value) => setState(() => _pressed = value),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PluginLogo(name: plugin.name, url: plugin.iconUrl),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              plugin.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              plugin.author == null
                                  ? 'Author unavailable'
                                  : 'by ${plugin.author}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PluginStatusBadges(
                        plugin: plugin,
                        installed: widget.installed,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Flexible(
                        child: PluginMetaPill(
                          icon: Symbols.translate_rounded,
                          label: plugin.languages.isEmpty
                              ? 'Unknown'
                              : plugin.languages.join(' · '),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PluginMetaPill(
                        icon: plugin.available
                            ? Symbols.stacks_rounded
                            : Symbols.cloud_off_rounded,
                        label: sourcesLabel,
                        accent: plugin.available,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRect(
                      child: preview.isEmpty
                          ? const Text(
                              'The manifest could not be reached when the catalog was updated.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 11,
                                height: 1.35,
                              ),
                            )
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final scraper in preview)
                                  _SourceChip(label: scraper.name),
                                if (remaining > 0)
                                  _SourceChip(
                                    label: '+$remaining more',
                                    subtle: true,
                                  ),
                              ],
                            ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: widget.onOpen,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            foregroundColor: GlassTheme.primary,
                            backgroundColor: GlassTheme.primary.withValues(
                              alpha: .12,
                            ),
                          ),
                          child: Semantics(
                            label: 'View details for ${plugin.name}',
                            excludeSemantics: true,
                            child: const Text('View details'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CopyManifestButton(
                          manifestUrl: plugin.manifestUrl,
                          pluginName: plugin.name,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.label, this.subtle = false});

  final String label;
  final bool subtle;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 132),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: subtle ? Colors.transparent : Colors.white.withValues(alpha: .05),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(
        color: Colors.white.withValues(alpha: subtle ? .1 : .06),
      ),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: subtle ? GlassTheme.muted : Colors.white70,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
