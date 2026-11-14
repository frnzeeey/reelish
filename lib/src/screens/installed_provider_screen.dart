// Details of one installed provider: what its manifest declares, whether it
// can work on this device and why, its running and listed versions, its last
// failure, what any provider can do, and its on/off switch. Shared by
// phone, TV and Windows.
import 'package:flutter/material.dart';

import '../models/provider_plugin.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../services/plugin_compatibility.dart';
import '../services/plugin_library_query.dart';
import '../services/plugin_library_repository.dart';
import '../services/provider_plugin_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/plugin_library/plugin_logo.dart';
import '../widgets/plugin_manager/plugin_transparency.dart';
import 'plugin_collection_screen.dart';

class InstalledProviderScreen extends StatelessWidget {
  const InstalledProviderScreen({
    super.key,
    required this.repositoryUrl,
    required this.pluginId,
    required this.pluginService,
    this.pluginLibrary,
    this.device,
  });

  final String repositoryUrl;
  final String pluginId;
  final ProviderPluginService pluginService;
  final PluginLibraryRepository? pluginLibrary;

  /// Overrides the detected interface in tests.
  final ReelishDevice? device;

  static Future<void> open(
    BuildContext context, {
    required String repositoryUrl,
    required String pluginId,
    required ProviderPluginService pluginService,
    PluginLibraryRepository? pluginLibrary,
  }) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      details: true,
      builder: (_) => InstalledProviderScreen(
        repositoryUrl: repositoryUrl,
        pluginId: pluginId,
        pluginService: pluginService,
        pluginLibrary: pluginLibrary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: pluginService,
    builder: (context, _) {
      final repository = pluginService.repositories
          .where((repo) => repo.url == repositoryUrl)
          .firstOrNull;
      final plugin = repository?.plugins
          .where((entry) => entry.id == pluginId)
          .firstOrNull;
      if (repository == null || plugin == null) {
        return PluginManagerPage(
          backLabel: 'Plugins',
          slivers: [
            SliverToBoxAdapter(
              child: PluginManagerPage.constrained(
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: PluginInfoCard(
                    icon: ReelishIcons.info,
                    color: GlassTheme.warning,
                    title: 'This provider is no longer listed',
                    children: [
                      PluginInfoText(
                        'Its collection was removed, or its manifest no longer '
                        'lists it.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return PluginManagerPage(
        backLabel: repository.name,
        slivers: [
          SliverToBoxAdapter(
            child: PluginManagerPage.constrained(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _Body(
                  repository: repository,
                  plugin: plugin,
                  service: pluginService,
                  library: pluginLibrary,
                  device: device ?? ReelishDevice.current,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _Body extends StatelessWidget {
  const _Body({
    required this.repository,
    required this.plugin,
    required this.service,
    required this.library,
    required this.device,
  });

  final ProviderRepository repository;
  final ProviderPlugin plugin;
  final ProviderPluginService service;
  final PluginLibraryRepository? library;
  final ReelishDevice device;

  @override
  Widget build(BuildContext context) {
    final compatibility = PluginCompatibility.of(plugin, device);
    final awaitingReview = service.isAwaitingReview(repository, plugin);
    final lastError = service.lastErrorFor(repository, plugin);
    final running = service.approvedVersionFor(repository, plugin);
    final (compatIcon, compatColor) = PluginCompatibilityChip.styleOf(
      compatibility.level,
    );
    final languages = {
      for (final code in plugin.contentLanguages) PluginLanguages.label(code),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Hero(plugin: plugin, compatibility: compatibility),
        const SizedBox(height: 14),
        _SwitchRow(
          plugin: plugin,
          compatibility: compatibility,
          onChanged: (value) => setProviderEnabled(
            context,
            service: service,
            repository: repository,
            plugin: plugin,
            enabled: value,
            device: device,
          ),
        ),
        if (awaitingReview) ...[
          const SizedBox(height: 12),
          PluginInfoCard(
            icon: ReelishIcons.pause,
            color: GlassTheme.warning,
            title: 'Paused: new code to review',
            actions: [
              FilledButton.tonal(
                onPressed: () => PluginCollectionScreen.open(
                  context,
                  repositoryUrl: repository.url,
                  pluginService: service,
                  pluginLibrary: library,
                ),
                child: const Text('Review in collection'),
              ),
            ],
            children: [
              PluginInfoText(
                service.hasApprovedCode(repository, plugin)
                    ? 'Its code changed since you allowed it, so it is not '
                          'searched until you allow the new code.'
                    : 'Its collection added it after you installed it, so it '
                          'is not searched until you allow its code.',
              ),
            ],
          ),
        ],
        if (lastError != null) ...[
          const SizedBox(height: 12),
          PluginInfoCard(
            icon: ReelishIcons.error,
            color: GlassTheme.danger,
            title: 'Last search failed',
            actions: [
              TextButton(
                onPressed: () =>
                    service.dismissError('${plugin.name} (${repository.name})'),
                child: const Text('Dismiss'),
              ),
            ],
            children: [PluginInfoText(lastError)],
          ),
        ],
        if (!plugin.enabled &&
            !plugin.defaultEnabled &&
            !service.hasEnabledChoice(repository, plugin)) ...[
          const SizedBox(height: 12),
          const PluginInfoCard(
            icon: ReelishIcons.info,
            color: GlassTheme.info,
            title: 'Off by default',
            children: [
              PluginInfoText(
                'Its manifest ships it switched off. Switch it on to include '
                'it in searches.',
              ),
            ],
          ),
        ],
        if (plugin.description.trim().isNotEmpty) ...[
          const PluginSectionHeading('About'),
          Text(
            plugin.description.trim(),
            style: TextStyle(
              color: GlassTheme.textPrimary.withValues(alpha: .75),
              height: 1.5,
              fontSize: AppTextSize.bodySmall,
            ),
          ),
        ],
        const PluginSectionHeading('On this device'),
        PluginInfoCard(
          icon: compatIcon,
          color: compatColor,
          title: '${compatibility.level.label} on ${device.label}',
          children: [
            if (compatibility.reasons.isEmpty)
              const PluginInfoText(
                'Nothing its manifest declares rules this device out. Whether '
                'it finds streams depends on the sites it uses.',
              )
            else
              for (final reason in compatibility.reasons)
                PluginInfoText(reason),
          ],
        ),
        const PluginSectionHeading('Details'),
        PluginFactsTable(
          rows: [
            ('Finds', describeContentTypes(plugin.supportedTypes)),
            if (languages.isNotEmpty) ('Languages', languages.join(', ')),
            if (plugin.formats.isNotEmpty)
              (
                'Formats',
                plugin.formats.map((f) => f.toUpperCase()).join(', '),
              ),
            ('Version', _version(running, plugin.version)),
            (
              'Author',
              plugin.author == null
                  ? 'Not stated'
                  : '${plugin.author} (as its manifest states)',
            ),
            ('Collection', repository.name),
          ],
        ),
        const SizedBox(height: 16),
        const ProviderCapabilitiesCard(),
        const SizedBox(height: 12),
        _Advanced(repository: repository, plugin: plugin),
      ],
    );
  }

  static String _version(String? running, String? listed) {
    if (running != null && listed != null && running != listed) {
      return '$running running, $listed listed';
    }
    return running ?? listed ?? 'Not stated';
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.plugin, required this.compatibility});

  final ProviderPlugin plugin;
  final PluginCompatibility compatibility;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      PluginLogo(name: plugin.name, url: plugin.logoUrl, size: 60, radius: 18),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                plugin.name,
                style: const TextStyle(
                  fontSize: AppTextSize.headline,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                PluginCompatibilityChip(level: compatibility.level),
                if (plugin.version case final version?)
                  PluginStatusChip(
                    icon: ReelishIcons.tag,
                    label: 'v$version',
                    color: GlassTheme.muted,
                  ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.plugin,
    required this.compatibility,
    required this.onChanged,
  });

  final ProviderPlugin plugin;
  final PluginCompatibility compatibility;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final canSwitch = compatibility.searchable || plugin.enabled;
    return Material(
      color: GlassTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: GlassTheme.border),
      ),
      child: SwitchListTile(
        autofocus: DeviceCapabilities.isTv,
        value: plugin.enabled,
        onChanged: canSwitch ? onChanged : null,
        activeTrackColor: GlassTheme.primary.withValues(alpha: .6),
        activeThumbColor: GlassTheme.primary,
        title: const Text(
          'Search this provider',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          !canSwitch
              ? 'Reelish never asks it for streams'
              : plugin.enabled
              ? 'Used for your next search. Something already playing is not '
                    'affected.'
              : 'Not used when you press play',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: AppTextSize.caption,
          ),
        ),
      ),
    );
  }
}

/// Technical identifiers, folded away by default.
class _Advanced extends StatelessWidget {
  const _Advanced({required this.repository, required this.plugin});

  final ProviderRepository repository;
  final ProviderPlugin plugin;

  @override
  Widget build(BuildContext context) => PluginExpandableSurface(
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(ReelishIcons.code, color: GlassTheme.muted),
        title: const Text(
          'Technical details',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: AppTextSize.bodySmall,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          PluginFactsTable(
            rows: [
              ('Provider ID', plugin.id),
              (
                'Script',
                ProviderPluginService.scriptUrlFor(repository, plugin),
              ),
              ('Priority', '${plugin.priority}'),
              if (plugin.disabledPlatforms.isNotEmpty)
                ('Disabled on', plugin.disabledPlatforms.join(', ')),
              if (plugin.hasSettings) ('Settings', 'Declared; not supported'),
            ],
          ),
        ],
      ),
    ),
  );
}
