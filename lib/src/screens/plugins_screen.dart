import 'package:flutter/material.dart';

import '../models/nuvio_plugin.dart';
import '../services/nuvio_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/nuvio_plugin_installer_modal.dart';

class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key, required this.pluginService});

  final NuvioPluginService pluginService;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pluginService,
    builder: (context, _) {
      final plugins = pluginService.repositories
          .expand((repo) => repo.plugins)
          .toList();
      final enabledCount = plugins.where((plugin) => plugin.enabled).length;
      final install = () => NuvioPluginInstallerModal.show(context, pluginService);
      return Scaffold(
        floatingActionButton: Padding(
          // Keep the action above the app-wide glass navigation dock.
          padding: const EdgeInsets.only(bottom: 84),
          child: FloatingActionButton.extended(
            onPressed: install,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add provider'),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 126),
          children: [
            _PluginsHeader(onRefresh: () => pluginService.load()),
            const SizedBox(height: 18),
            _PluginsHero(
              repositoryCount: pluginService.repositories.length,
              providerCount: plugins.length,
              enabledCount: enabledCount,
            ),
            const SizedBox(height: 24),
            _SectionHeading(
              title: 'Your repositories',
              detail: pluginService.repositories.isEmpty
                  ? 'Add a Nuvio manifest to get started'
                  : '${pluginService.repositories.length} installed',
            ),
            const SizedBox(height: 12),
            if (pluginService.repositories.isEmpty)
              _EmptyPlugins(onInstall: install)
            else ...[
              if (enabledCount == 0) ...[
                const SizedBox(height: 12),
                const _NoticeCard(
                  title: 'All providers are switched off',
                  message:
                      'Enable at least one provider below before searching for a stream.',
                ),
                const SizedBox(height: 12),
              ],
              for (final repository in pluginService.repositories)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _RepositoryCard(
                    key: ValueKey(repository.url),
                    repository: repository,
                    service: pluginService,
                  ),
                ),
            ],
            if (pluginService.errors.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionHeading(
                title: 'Needs attention',
                detail: '${pluginService.errors.length} load errors',
              ),
              const SizedBox(height: 12),
              for (final error in pluginService.errors.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: _RepositoryError(
                    name: error.key,
                    message: error.value,
                    onDismiss: () => pluginService.removeFailed(error.key),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class _PluginsHeader extends StatelessWidget {
  const _PluginsHeader({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PERSONALIZE PLAYBACK',
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.7,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Plugins',
              style: TextStyle(
                fontSize: 30,
                height: 1.05,
                fontWeight: FontWeight.w800,
                letterSpacing: -.8,
              ),
            ),
          ],
        ),
      ),
      IconButton.filledTonal(
        tooltip: 'Refresh repositories',
        onPressed: onRefresh,
        style: IconButton.styleFrom(
          foregroundColor: GlassTheme.primary,
          backgroundColor: GlassTheme.primary.withValues(alpha: .1),
        ),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
  );
}

class _PluginsHero extends StatelessWidget {
  const _PluginsHero({
    required this.repositoryCount,
    required this.providerCount,
    required this.enabledCount,
  });

  final int repositoryCount;
  final int providerCount;
  final int enabledCount;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(25),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          GlassTheme.primary.withValues(alpha: .24),
          const Color(0xFF191923),
          const Color(0xFF121219),
        ],
      ),
      border: Border.all(color: GlassTheme.primary.withValues(alpha: .2)),
    ),
    child: Stack(
      children: [
        Positioned(
          right: -26,
          top: -34,
          child: Container(
            width: 142,
            height: 142,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GlassTheme.primary.withValues(alpha: .08),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: GlassTheme.primary.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.hub_rounded, color: GlassTheme.primary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                      'SOURCE OVERVIEW',
                        style: TextStyle(
                          color: GlassTheme.muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Your sources',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.bolt_rounded, color: GlassTheme.primary, size: 22),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Choose which trusted providers Reelish can search when you press play.',
              style: TextStyle(color: Colors.white70, height: 1.4, fontSize: 12),
            ),
            const SizedBox(height: 17),
            Row(
              children: [
                _MetricPill(value: '$enabledCount', label: 'active'),
                const SizedBox(width: 8),
                _MetricPill(value: '$providerCount', label: 'providers'),
                const SizedBox(width: 8),
                _MetricPill(value: '$repositoryCount', label: 'repos'),
              ],
            ),
          ],
        ),
      ],
    ),
  );
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: .07)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: GlassTheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ],
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      Text(detail, style: const TextStyle(color: GlassTheme.muted, fontSize: 11)),
    ],
  );
}

class _EmptyPlugins extends StatelessWidget {
  const _EmptyPlugins({required this.onInstall});

  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Column(
      children: [
        Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.travel_explore_rounded, color: GlassTheme.primary),
        ),
        const SizedBox(height: 14),
        const Text(
          'Start with a provider',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        const Text(
          'Install a Nuvio manifest to add streaming sources. You can turn each provider on or off at any time.',
          textAlign: TextAlign.center,
          style: TextStyle(color: GlassTheme.muted, height: 1.45, fontSize: 12),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onInstall,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Install a provider'),
        ),
      ],
    ),
  );
}

class _RepositoryCard extends StatefulWidget {
  const _RepositoryCard({
    super.key,
    required this.repository,
    required this.service,
  });

  final NuvioPluginRepository repository;
  final NuvioPluginService service;

  @override
  State<_RepositoryCard> createState() => _RepositoryCardState();
}

class _RepositoryCardState extends State<_RepositoryCard> {
  bool _expanded = false;

  Future<void> _confirmRemove() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove repository?'),
        content: Text(
          'Providers from ${widget.repository.name} will no longer be available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) await widget.service.remove(widget.repository);
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    final enabledCount = repository.plugins
        .where((plugin) => plugin.enabled)
        .length;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _expanded
              ? GlassTheme.primary.withValues(alpha: .28)
              : GlassTheme.border,
        ),
      ),
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            contentPadding: const EdgeInsets.fromLTRB(14, 5, 8, 5),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: GlassTheme.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(Icons.dns_rounded, color: GlassTheme.primary, size: 21),
            ),
            title: Text(
              repository.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$enabledCount of ${repository.plugins.length} providers active',
                style: const TextStyle(color: GlassTheme.muted, fontSize: 10),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Remove repository',
                  onPressed: _confirmRemove,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  visualDensity: VisualDensity.compact,
                ),
                AnimatedRotation(
                  turns: _expanded ? .5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              children: [
                Divider(height: 1, color: GlassTheme.border),
                for (var index = 0; index < repository.plugins.length; index++)
                  _ProviderTile(
                    plugin: repository.plugins[index],
                    onChanged: (enabled) => widget.service.setPluginEnabled(
                      repository,
                      repository.plugins[index],
                      enabled,
                    ),
                    showDivider: index < repository.plugins.length - 1,
                  ),
                if (repository.plugins.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'This repository contains no valid providers.',
                      style: TextStyle(color: GlassTheme.muted, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.plugin,
    required this.onChanged,
    required this.showDivider,
  });

  final NuvioPlugin plugin;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Icon(
              plugin.enabled ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: plugin.enabled ? GlassTheme.primary : GlassTheme.disabled,
              size: 17,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plugin.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  if (plugin.description.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      plugin.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 10,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch.adaptive(
              value: plugin.enabled,
              onChanged: onChanged,
              activeTrackColor: GlassTheme.primary.withValues(alpha: .6),
              activeThumbColor: GlassTheme.primary,
            ),
          ],
        ),
      ),
      if (showDivider)
        Padding(
          padding: const EdgeInsets.only(left: 43),
          child: Divider(height: 1, color: GlassTheme.border),
        ),
    ],
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB547).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: const Color(0xFFFFB547).withValues(alpha: .2)),
    ),
    child: Row(
      children: [
        const Icon(Icons.power_settings_new_rounded, color: Color(0xFFFFB547), size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Color(0xFFFFB547), fontWeight: FontWeight.w700, fontSize: 12)),
              const SizedBox(height: 3),
              Text(message, style: const TextStyle(color: GlassTheme.muted, fontSize: 10, height: 1.35)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _RepositoryError extends StatelessWidget {
  const _RepositoryError({
    required this.name,
    required this.message,
    required this.onDismiss,
  });

  final String name;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB547).withValues(alpha: .07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFFFB547).withValues(alpha: .18)),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFB547), size: 20),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11)),
              const SizedBox(height: 3),
              Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: GlassTheme.muted, fontSize: 10, height: 1.3)),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Dismiss',
          visualDensity: VisualDensity.compact,
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    ),
  );
}
