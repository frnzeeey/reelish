import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/provider_plugin.dart';
import '../screens/plugin_library_screen.dart';
import '../services/plugin_library_repository.dart';
import '../services/provider_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/provider_installer_modal.dart';
import 'desktop_widgets.dart';

/// Plugins on Windows: the installed repositories and their providers at a
/// desktop width, with the same actions as the phone and TV screen (add
/// from the library or a manifest URL, refresh, switch providers on and
/// off, remove, allow changed provider code) through the same
/// [ProviderPluginService], so what is installed and enabled is shared.
class DesktopPluginsPage extends StatelessWidget {
  const DesktopPluginsPage({
    super.key,
    required this.pluginService,
    required this.pluginLibrary,
  });

  final ProviderPluginService pluginService;
  final PluginLibraryRepository pluginLibrary;

  static const _warning = Color(0xFFFFB547);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: pluginService,
    builder: (context, _) {
      final repositories = pluginService.repositories;
      final plugins = repositories.expand((repo) => repo.plugins).toList();
      final enabled = plugins.where((plugin) => plugin.enabled).length;
      void install() => ProviderInstallerModal.show(context, pluginService);
      void browse() => PluginLibraryScreen.open(
        context,
        repository: pluginLibrary,
        pluginService: pluginService,
      );
      final issues =
          pluginService.errors.length +
          pluginService.pendingScriptUpdates.length;
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: DesktopPageHeader(
              title: 'Plugins',
              subtitle:
                  'Choose which trusted providers Reelish can search when '
                  'you press play.',
              trailing: Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Refresh repositories',
                    onPressed: () => unawaited(pluginService.load()),
                    icon: const Icon(Symbols.refresh_rounded),
                  ),
                  OutlinedButton.icon(
                    onPressed: install,
                    style: _outlined,
                    icon: const Icon(Symbols.add_link_rounded),
                    label: const Text('Paste a manifest URL'),
                  ),
                  FilledButton.icon(
                    onPressed: browse,
                    style: _filled,
                    icon: const Icon(Symbols.storefront_rounded),
                    label: const Text('Browse Reelish Plugins'),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              DesktopMetrics.pagePadding,
              14,
              DesktopMetrics.pagePadding,
              48,
            ),
            sliver: SliverList.list(
              children: [
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    _Stat(
                      icon: Symbols.bolt_rounded,
                      value: enabled,
                      label: enabled == 1
                          ? 'provider active'
                          : 'providers active',
                      highlight: true,
                    ),
                    _Stat(
                      icon: Symbols.hub_rounded,
                      value: plugins.length,
                      label: plugins.length == 1
                          ? 'provider installed'
                          : 'providers installed',
                    ),
                    _Stat(
                      icon: Symbols.dns_rounded,
                      value: repositories.length,
                      label: repositories.length == 1
                          ? 'repository'
                          : 'repositories',
                    ),
                  ],
                ),
                if (issues > 0) ...[
                  _Heading(
                    title: 'Needs attention',
                    detail: issues == 1 ? '1 issue' : '$issues issues',
                  ),
                  for (final update
                      in pluginService.pendingScriptUpdates.entries)
                    _Issue(
                      name:
                          repositories
                              .where((repo) => repo.url == update.key)
                              .firstOrNull
                              ?.name ??
                          update.key,
                      message: update.value.length == 1
                          ? 'A provider was added or changed its code. It is '
                                'paused until you allow it. Only allow it if '
                                'you trust this repository.'
                          : '${update.value.length} providers were added or '
                                'changed their code. They are paused until '
                                'you allow them. Only allow it if you trust '
                                'this repository.',
                      actions: [
                        FilledButton.tonal(
                          onPressed: () => unawaited(
                            pluginService.approveScriptUpdates(update.key),
                          ),
                          child: const Text('Allow update'),
                        ),
                      ],
                    ),
                  for (final error in pluginService.errors.entries)
                    _Issue(
                      name: error.key,
                      message: error.value,
                      actions:
                          pluginService.failedRepositoryUrls.contains(error.key)
                          ? [
                              TextButton.icon(
                                onPressed: () =>
                                    unawaited(pluginService.load()),
                                icon: const Icon(
                                  Symbols.refresh_rounded,
                                  size: 18,
                                ),
                                label: const Text('Retry'),
                              ),
                              TextButton.icon(
                                onPressed: () => unawaited(
                                  _confirmRemoveFailed(
                                    context,
                                    pluginService,
                                    error.key,
                                  ),
                                ),
                                icon: const Icon(
                                  Symbols.delete_rounded,
                                  size: 18,
                                ),
                                label: const Text('Remove'),
                              ),
                            ]
                          : [
                              TextButton(
                                onPressed: () =>
                                    pluginService.dismissError(error.key),
                                child: const Text('Dismiss'),
                              ),
                            ],
                    ),
                ],
                _Heading(
                  title: 'Your repositories',
                  detail: repositories.isEmpty
                      ? 'Add a provider manifest to get started'
                      : '${repositories.length} installed',
                ),
                if (repositories.isEmpty)
                  _Empty(onBrowse: browse, onInstall: install)
                else ...[
                  if (enabled == 0)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: _Notice(
                        title: 'All providers are switched off',
                        message:
                            'Enable at least one provider below before '
                            'searching for a stream.',
                      ),
                    ),
                  for (final repository in repositories)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _RepositoryCard(
                        key: ValueKey(repository.url),
                        repository: repository,
                        service: pluginService,
                        // A single repository opens with its providers.
                        initiallyExpanded: repositories.length == 1,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );

  static final _filled = FilledButton.styleFrom(
    backgroundColor: GlassTheme.primary,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
  );

  static final _outlined = OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    backgroundColor: Colors.white.withValues(alpha: .05),
    side: const BorderSide(color: DesktopSurfaces.hairline),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    this.highlight = false,
  });

  final IconData icon;
  final int value;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    return Container(
      constraints: const BoxConstraints(minWidth: 220),
      padding: const EdgeInsets.fromLTRB(16, 14, 22, 14),
      decoration: BoxDecoration(
        gradient: highlight
            ? LinearGradient(
                colors: [
                  accent.withValues(alpha: .18),
                  accent.withValues(alpha: .05),
                ],
              )
            : null,
        color: highlight ? null : GlassTheme.surface,
        borderRadius: BorderRadius.circular(DesktopSurfaces.radius + 2),
        border: Border.all(
          color: highlight
              ? accent.withValues(alpha: .3)
              : DesktopSurfaces.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: highlight ? accent : GlassTheme.muted, size: 24),
          const SizedBox(width: 14),
          Text(
            '$value',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: GlassTheme.muted)),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 30, bottom: 12),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 18,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: GlassTheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: GlassTheme.muted, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onBrowse, required this.onInstall});

  final VoidCallback onBrowse;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(DesktopSurfaces.radius + 4),
      border: Border.all(color: DesktopSurfaces.hairline),
    ),
    child: Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .14),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Icon(
              Symbols.travel_explore_rounded,
              size: 32,
              color: GlassTheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 22),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Start with a provider',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 6),
              Text(
                'Browse the library or paste a provider manifest URL to add '
                'streaming sources. You can turn each provider on or off at '
                'any time.',
                style: TextStyle(color: GlassTheme.muted, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(width: 22),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: onInstall,
              icon: const Icon(Symbols.add_rounded),
              label: const Text('Paste a manifest'),
            ),
            FilledButton.icon(
              onPressed: onBrowse,
              icon: const Icon(Symbols.storefront_rounded),
              label: const Text('Browse the library'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => _Warning(
    icon: Symbols.power_settings_new_rounded,
    title: title,
    message: message,
  );
}

class _Issue extends StatelessWidget {
  const _Issue({
    required this.name,
    required this.message,
    required this.actions,
  });

  final String name;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _Warning(
      icon: Symbols.warning_rounded,
      title: name,
      message: message,
      actions: actions,
    ),
  );
}

class _Warning extends StatelessWidget {
  const _Warning({
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    const warning = DesktopPluginsPage._warning;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(DesktopSurfaces.radius),
        border: Border.all(color: warning.withValues(alpha: .2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: warning, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlassTheme.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 12),
            Wrap(spacing: 6, children: actions),
          ],
        ],
      ),
    );
  }
}

class _RepositoryCard extends StatefulWidget {
  const _RepositoryCard({
    super.key,
    required this.repository,
    required this.service,
    this.initiallyExpanded = false,
  });

  final ProviderRepository repository;
  final ProviderPluginService service;
  final bool initiallyExpanded;

  @override
  State<_RepositoryCard> createState() => _RepositoryCardState();
}

class _RepositoryCardState extends State<_RepositoryCard> {
  late bool _expanded = widget.initiallyExpanded;
  bool _hovered = false;

  Future<void> _confirmRemove() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove repository?'),
        content: Text(
          'Providers from ${widget.repository.name} will no longer be '
          'available.',
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
    final active = repository.plugins.where((plugin) => plugin.enabled).length;
    final duration = desktopMotion(context, 200);
    return AnimatedContainer(
      duration: duration,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(DesktopSurfaces.radius + 4),
        border: Border.all(
          color: _expanded
              ? GlassTheme.primary.withValues(alpha: .28)
              : _hovered
              ? Colors.white.withValues(alpha: .16)
              : DesktopSurfaces.hairline,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: GlassTheme.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Symbols.dns_rounded,
                          color: GlassTheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              repository.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              repository.url,
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
                      const SizedBox(width: 16),
                      Text(
                        '$active of ${repository.plugins.length} providers '
                        'active',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: active > 0
                              ? GlassTheme.coralBright
                              : GlassTheme.muted,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: 'Remove repository',
                        onPressed: () => unawaited(_confirmRemove()),
                        icon: const Icon(Symbols.delete_rounded, size: 20),
                      ),
                      Tooltip(
                        message: _expanded
                            ? 'Hide providers'
                            : 'Show providers',
                        child: AnimatedRotation(
                          turns: _expanded ? .5 : 0,
                          duration: duration,
                          child: const Icon(
                            Symbols.keyboard_arrow_down_rounded,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: duration,
              curve: DesktopSurfaces.curve,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(
                          height: 1,
                          color: DesktopSurfaces.hairline,
                        ),
                        if (repository.plugins.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'This repository contains no valid providers.',
                              style: TextStyle(color: GlassTheme.muted),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: _ProviderGrid(
                              plugins: repository.plugins,
                              onChanged: (plugin, enabled) => unawaited(
                                widget.service.setPluginEnabled(
                                  repository,
                                  plugin,
                                  enabled,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Providers in one or two columns, as the card's width allows.
class _ProviderGrid extends StatelessWidget {
  const _ProviderGrid({required this.plugins, required this.onChanged});

  final List<ProviderPlugin> plugins;
  final void Function(ProviderPlugin plugin, bool enabled) onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 860 ? 2 : 1;
      const gap = 8.0;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final plugin in plugins)
            SizedBox(
              width: width,
              child: _ProviderTile(
                plugin: plugin,
                onChanged: (enabled) => onChanged(plugin, enabled),
              ),
            ),
        ],
      );
    },
  );
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.plugin, required this.onChanged});

  final ProviderPlugin plugin;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Material(
    color: plugin.enabled
        ? GlassTheme.primary.withValues(alpha: .06)
        : Colors.white.withValues(alpha: .02),
    borderRadius: BorderRadius.circular(DesktopSurfaces.radius - 2),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      // The whole row switches; the switch itself is the Tab stop.
      canRequestFocus: false,
      onTap: () => onChanged(!plugin.enabled),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              plugin.enabled
                  ? Symbols.check_circle_rounded
                  : Symbols.circle_rounded,
              fill: plugin.enabled ? 1 : 0,
              color: plugin.enabled ? GlassTheme.primary : GlassTheme.disabled,
              size: 19,
            ),
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
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (plugin.description.isNotEmpty ||
                      plugin.supportedTypes.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (plugin.supportedTypes.isNotEmpty)
                          plugin.supportedTypes
                              .map(
                                (type) => type == 'tv' || type == 'series'
                                    ? 'Series'
                                    : type == 'movie'
                                    ? 'Movies'
                                    : type,
                              )
                              .join(', '),
                        if (plugin.description.isNotEmpty) plugin.description,
                      ].join('  ·  '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: plugin.name,
              child: Switch(
                value: plugin.enabled,
                onChanged: onChanged,
                activeTrackColor: GlassTheme.primary.withValues(alpha: .6),
                activeThumbColor: GlassTheme.primary,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Removing an unreachable repository is permanent, so it is confirmed: the
/// usual cause is a missing connection, not a broken repository.
Future<void> _confirmRemoveFailed(
  BuildContext context,
  ProviderPluginService service,
  String url,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Remove repository?'),
      content: Text(
        'This uninstalls $url. If it failed only because you are offline, '
        'use Retry instead.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed == true) await service.removeFailed(url);
}
