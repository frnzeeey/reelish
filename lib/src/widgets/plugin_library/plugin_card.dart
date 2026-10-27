import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/plugin_catalog.dart';
import '../../services/plugin_library_query.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'plugin_badges.dart';
import 'plugin_formatting.dart';
import 'plugin_logo.dart';

/// A provider in the library grid: who made it, what it covers, how fresh
/// it is, and one contextual action ([action], the install button). The
/// card itself opens the details. Layout is fixed-height so the grid can
/// lay out hundreds of entries lazily.
class PluginCard extends StatefulWidget {
  const PluginCard({
    super.key,
    required this.plugin,
    required this.onOpen,
    this.action,
    this.search = '',
    this.installed = false,
  });

  static const height = 244.0;

  /// [height] grown with the text size, so large accessibility text fits.
  static double heightFor(BuildContext context) =>
      height *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 1.6);

  final ReelishPlugin plugin;
  final VoidCallback onOpen;

  /// The card's one action, bottom right; usually [PluginInstallButton].
  final Widget? action;
  final String search;
  final bool installed;

  @override
  State<PluginCard> createState() => _PluginCardState();
}

class _PluginCardState extends State<PluginCard> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final preview = previewScrapers(plugin, search: widget.search);
    final remaining = plugin.scraperCount - preview.length;
    final sourcesLabel = plugin.available
        ? '${plugin.scraperCount} ${plugin.scraperCount == 1 ? 'source' : 'sources'}'
        : 'Sources unavailable';
    final freshness = [
      if (plugin.manifestVersion case final version?) 'v$version',
      if (plugin.lastUpdated case final updated?)
        'Updated ${relativePluginDate(updated)}',
    ].join(' · ');
    // Focus (remote, keyboard) is the strongest state, then hover, then
    // installed, so the cursor is never lost behind a status colour.
    final border = _focused
        ? BorderSide(color: GlassTheme.coralBright, width: 2.5)
        : _hovered
        ? BorderSide(color: Colors.white.withValues(alpha: .22))
        : widget.installed
        ? BorderSide(color: GlassTheme.primary.withValues(alpha: .35))
        : const BorderSide(color: GlassTheme.border);
    return Semantics(
      container: true,
      label:
          '${plugin.name}${plugin.author == null ? '' : ', by ${plugin.author}'}, '
          '${plugin.languages.join(', ')}, $sourcesLabel'
          '${widget.installed ? ', installed' : ''}',
      child: AnimatedScale(
        scale: _pressed
            ? .985
            : _focused
            ? 1.02
            : 1,
        duration: AppMotion.resolve(context, AppMotion.press),
        curve: AppMotion.enter,
        child: Material(
          color: _hovered || _focused
              ? GlassTheme.elevatedSurface
              : GlassTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            side: border,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            onHighlightChanged: (value) => setState(() => _pressed = value),
            onHover: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            // The border shows focus; no extra tint over the content.
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md,
                AppSpace.md,
                AppSpace.md,
                AppSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PluginLogo(
                        name: plugin.name,
                        url: plugin.iconUrl,
                        size: 44,
                        radius: AppRadius.md,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Tooltip(
                              message: plugin.name,
                              waitDuration: const Duration(milliseconds: 600),
                              child: Text(
                                plugin.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: AppTextSize.bodyLarge,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              plugin.author == null
                                  ? 'Author unavailable'
                                  : 'by ${plugin.author}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: GlassTheme.muted,
                                fontSize: AppTextSize.label,
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
                  const SizedBox(height: AppSpace.sm),
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
                      const SizedBox(width: AppSpace.xs),
                      PluginMetaPill(
                        icon: plugin.available
                            ? Symbols.stacks_rounded
                            : Symbols.cloud_off_rounded,
                        label: sourcesLabel,
                        accent: plugin.available,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ClipRect(
                      child: preview.isEmpty
                          ? const Text(
                              'The manifest could not be reached when the '
                              'catalog was updated.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: AppTextSize.caption,
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
                  const SizedBox(height: AppSpace.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          freshness,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: AppTextSize.caption,
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (widget.action case final action?) ...[
                        const SizedBox(width: AppSpace.sm),
                        action,
                      ],
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
      borderRadius: BorderRadius.circular(AppRadius.sm),
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
        fontSize: AppTextSize.caption,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
