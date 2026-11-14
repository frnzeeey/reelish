// Manage one installed provider repository ("collection"): where it comes
// from and how far it is trusted, code waiting for review with its version
// change, an update check, and every provider it lists with its device
// compatibility and switch. Shared by phone, TV and Windows.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/plugin_catalog.dart';
import '../models/provider_plugin.dart';
import '../navigation/app_transitions.dart';
import '../platform/device_capabilities.dart';
import '../services/plugin_compatibility.dart';
import '../services/plugin_library_repository.dart';
import '../services/plugin_trust.dart';
import '../services/provider_plugin_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/plugin_library/copy_manifest_button.dart';
import '../widgets/plugin_library/plugin_logo.dart';
import '../widgets/plugin_library/plugin_search_bar.dart';
import '../widgets/plugin_manager/plugin_transparency.dart';
import '../widgets/tv/tv_focus.dart';
import 'installed_provider_screen.dart';

enum _ProviderFilter {
  all('All'),
  on('On'),
  off('Off'),
  attention('Needs attention'),
  unsupported('Not for this device');

  const _ProviderFilter(this.label);
  final String label;
}

class PluginCollectionScreen extends StatefulWidget {
  const PluginCollectionScreen({
    super.key,
    required this.repositoryUrl,
    required this.pluginService,
    this.pluginLibrary,
    this.device,
  });

  final String repositoryUrl;
  final ProviderPluginService pluginService;

  /// The catalog, to tell listed, verified and added-by-link sources apart.
  final PluginLibraryRepository? pluginLibrary;

  /// Overrides the detected interface in tests.
  final ReelishDevice? device;

  static Future<void> open(
    BuildContext context, {
    required String repositoryUrl,
    required ProviderPluginService pluginService,
    PluginLibraryRepository? pluginLibrary,
  }) => Navigator.push<void>(
    context,
    AppPageRoute<void>(
      context: context,
      details: true,
      builder: (_) => PluginCollectionScreen(
        repositoryUrl: repositoryUrl,
        pluginService: pluginService,
        pluginLibrary: pluginLibrary,
      ),
    ),
  );

  @override
  State<PluginCollectionScreen> createState() => _PluginCollectionScreenState();
}

class _PluginCollectionScreenState extends State<PluginCollectionScreen> {
  final _search = TextEditingController();
  String _query = '';
  _ProviderFilter _filter = _ProviderFilter.all;
  bool _checking = false;
  bool _removing = false;

  ReelishDevice get _device => widget.device ?? ReelishDevice.current;

  @override
  void initState() {
    super.initState();
    // Local copy first; a network refresh only when the cached catalog is
    // stale (the repository's own rule).
    final library = widget.pluginLibrary;
    if (library != null) unawaited(library.load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ProviderRepository? get _repository => widget.pluginService.repositories
      .where((repo) => repo.url == widget.repositoryUrl)
      .firstOrNull;

  PluginCatalog? get _catalog => widget.pluginLibrary?.snapshot?.catalog;

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.pluginService.checkForUpdates(
        widget.repositoryUrl,
      );
      final parts = [
        result.awaitingReview == 0
            ? 'No new code'
            : result.awaitingReview == 1
            ? '1 provider has new code to review'
            : '${result.awaitingReview} providers have new code to review',
        if (result.failed > 0)
          '${result.failed} could not be checked, try again later',
      ];
      messenger.showSnackBar(SnackBar(content: Text('${parts.join('. ')}.')));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not reach this collection. Check your connection and try '
            'again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _approve(ProviderRepository repository) async {
    final pending = _pendingProviders(repository);
    final trust = PluginSourceTrust.of(repository.url, _catalog);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GlassTheme.elevatedSurface,
        title: const Text('Allow the new code?'),
        content: Text(
          '${pending.length == 1 ? 'One provider' : '${pending.length} providers'} '
          'in ${repository.name} changed or were added. Reelish does not review '
          'provider code; it runs on this device with the limits shown under '
          '"What providers can do".\n\nSource: ${trust.label}. Allow it only '
          'if you trust this collection.',
          style: TextStyle(color: GlassTheme.muted, height: 1.4),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.pluginService.approveScriptUpdates(repository.url);
    }
  }

  Future<void> _remove(ProviderRepository repository) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GlassTheme.elevatedSurface,
        title: Text('Remove ${repository.name}?'),
        content: Text(
          'Its ${repository.plugins.length} providers will no longer be '
          'searched, and your on/off choices and code approvals for it are '
          'forgotten. Something already playing keeps playing.',
          style: TextStyle(color: GlassTheme.muted, height: 1.4),
        ),
        actions: [
          TextButton(
            autofocus: true,
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
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.pluginService.remove(repository);
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${repository.name}.')),
      );
      navigator.maybePop();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not remove it. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  List<ProviderPlugin> _pendingProviders(ProviderRepository repository) => [
    for (final plugin in repository.plugins)
      if (widget.pluginService.isAwaitingReview(repository, plugin)) plugin,
  ];

  bool _needsAttention(ProviderRepository repository, ProviderPlugin plugin) =>
      widget.pluginService.isAwaitingReview(repository, plugin) ||
      widget.pluginService.lastErrorFor(repository, plugin) != null;

  bool _matches(ProviderRepository repository, ProviderPlugin plugin) {
    final terms = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final text = [
      plugin.name,
      plugin.description,
      plugin.author ?? '',
    ].join('\n').toLowerCase();
    if (!terms.every(text.contains)) return false;
    return switch (_filter) {
      _ProviderFilter.all => true,
      _ProviderFilter.on => plugin.enabled,
      _ProviderFilter.off => !plugin.enabled,
      _ProviderFilter.attention => _needsAttention(repository, plugin),
      _ProviderFilter.unsupported =>
        PluginCompatibility.of(plugin, _device).level ==
            PluginCompatibilityLevel.unsupported,
    };
  }

  void _openProvider(ProviderRepository repository, ProviderPlugin plugin) =>
      InstalledProviderScreen.open(
        context,
        repositoryUrl: repository.url,
        pluginId: plugin.id,
        pluginService: widget.pluginService,
        pluginLibrary: widget.pluginLibrary,
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.pluginService, ?widget.pluginLibrary]),
    builder: (context, _) {
      final repository = _repository;
      if (repository == null) {
        return PluginManagerPage(
          backLabel: 'Plugins',
          slivers: [
            SliverToBoxAdapter(
              child: PluginManagerPage.constrained(
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: PluginInfoCard(
                    icon: ReelishIcons.offline,
                    color: GlassTheme.warning,
                    title: 'This collection is not loaded',
                    children: [
                      PluginInfoText(
                        widget.pluginService.errors[widget.repositoryUrl] ??
                            'It was removed, or it has not loaded yet.',
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
        backLabel: 'Plugins',
        slivers: _content(context, repository),
      );
    },
  );

  List<Widget> _content(BuildContext context, ProviderRepository repository) {
    final service = widget.pluginService;
    final trust = PluginSourceTrust.of(repository.url, _catalog);
    final host = PluginHost.of(repository.url);
    final pending = _pendingProviders(repository);
    final enabled = repository.plugins.where((plugin) => plugin.enabled).length;
    final loadError = service.errors[repository.url];
    final counts = {
      for (final filter in _ProviderFilter.values)
        filter: repository.plugins.where((plugin) {
          return switch (filter) {
            _ProviderFilter.all => true,
            _ProviderFilter.on => plugin.enabled,
            _ProviderFilter.off => !plugin.enabled,
            _ProviderFilter.attention => _needsAttention(repository, plugin),
            _ProviderFilter.unsupported =>
              PluginCompatibility.of(plugin, _device).level ==
                  PluginCompatibilityLevel.unsupported,
          };
        }).length,
    };
    final visible = [
      for (final plugin in repository.plugins)
        if (_matches(repository, plugin)) plugin,
    ];
    Widget pad(Widget child) => PluginManagerPage.constrained(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: child,
      ),
    );

    return [
      SliverToBoxAdapter(
        child: pad(
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _Hero(
              repository: repository,
              trust: trust,
              host: host,
              enabled: enabled,
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: pad(
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  autofocus: DeviceCapabilities.isTv,
                  onPressed: _checking ? null : _checkForUpdates,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  icon: _checking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(ReelishIcons.update, size: 18),
                  label: Text(_checking ? 'Checking…' : 'Check for updates'),
                ),
                OutlinedButton.icon(
                  onPressed: () => CopyManifestButton.copy(
                    context,
                    Uri.parse(repository.url),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    foregroundColor: GlassTheme.textPrimary,
                    side: BorderSide(color: GlassTheme.border),
                  ),
                  icon: const Icon(ReelishIcons.copy, size: 18),
                  label: const Text('Copy link'),
                ),
                OutlinedButton.icon(
                  onPressed: _removing ? null : () => _remove(repository),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    foregroundColor: GlassTheme.textPrimary,
                    side: BorderSide(color: GlassTheme.border),
                  ),
                  icon: const Icon(ReelishIcons.trash, size: 18),
                  label: Text(_removing ? 'Removing…' : 'Remove'),
                ),
              ],
            ),
          ),
        ),
      ),
      if (loadError != null)
        SliverToBoxAdapter(
          child: pad(
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: PluginInfoCard(
                icon: ReelishIcons.offline,
                color: GlassTheme.warning,
                title: 'Temporarily unavailable',
                actions: [
                  TextButton(
                    onPressed: () => unawaited(service.load()),
                    child: const Text('Retry'),
                  ),
                ],
                children: [PluginInfoText(loadError)],
              ),
            ),
          ),
        ),
      if (pending.isNotEmpty)
        SliverToBoxAdapter(
          child: pad(
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _PendingReview(
                repository: repository,
                pending: pending,
                service: service,
                onApprove: () => _approve(repository),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(child: pad(const PluginSectionHeading('Source'))),
      SliverToBoxAdapter(
        child: pad(PluginSourceCard(trust: trust, manifestUrl: repository.url)),
      ),
      SliverToBoxAdapter(
        child: pad(
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: PluginFactsTable(
              rows: [
                ('Manifest', repository.url),
                ('Hosted on', host.label),
                if (repository.version case final version?)
                  ('Version', version),
                ('Updates', _updateNote),
              ],
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: pad(
          PluginSectionHeading(
            'Providers',
            detail: '$enabled of ${repository.plugins.length} on',
          ),
        ),
      ),
      if (repository.plugins.length > 6)
        SliverToBoxAdapter(child: pad(_searchField())),
      SliverToBoxAdapter(
        child: pad(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final filter in _ProviderFilter.values)
                  if (filter == _ProviderFilter.all || counts[filter]! > 0)
                    ChoiceChip(
                      label: Text('${filter.label} (${counts[filter]})'),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
              ],
            ),
          ),
        ),
      ),
      if (visible.isEmpty)
        SliverToBoxAdapter(
          child: pad(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                repository.plugins.isEmpty
                    ? 'This collection lists no valid providers.'
                    : 'No providers match. Try another search or filter.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassTheme.muted),
              ),
            ),
          ),
        )
      else
        SliverList.builder(
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final plugin = visible[index];
            return pad(
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ProviderRow(
                  key: ValueKey(plugin.id),
                  plugin: plugin,
                  compatibility: PluginCompatibility.of(plugin, _device),
                  awaitingReview: service.isAwaitingReview(repository, plugin),
                  failed: service.lastErrorFor(repository, plugin) != null,
                  onOpen: () => _openProvider(repository, plugin),
                  onChanged: (value) => setProviderEnabled(
                    context,
                    service: service,
                    repository: repository,
                    plugin: plugin,
                    enabled: value,
                    device: _device,
                  ),
                ),
              ),
            );
          },
        ),
      SliverToBoxAdapter(
        child: pad(
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: ProviderCapabilitiesCard(),
          ),
        ),
      ),
    ];
  }

  static const _updateNote =
      'Reelish reads this manifest at launch. When a provider’s code '
      'changes it pauses that provider until you allow the new code; it never '
      'updates provider code silently.';

  Widget _searchField() {
    if (DeviceCapabilities.isTv) {
      return TvTextField(
        value: _query,
        hint: 'Search providers',
        icon: ReelishIcons.search,
        textInputAction: TextInputAction.search,
        onChanged: (value) => setState(() => _query = value),
      );
    }
    return PluginSearchBar(
      controller: _search,
      hintText: 'Search providers…',
      onChanged: (value) => setState(() => _query = value),
      onClear: () {
        _search.clear();
        setState(() => _query = '');
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.repository,
    required this.trust,
    required this.host,
    required this.enabled,
  });

  final ProviderRepository repository;
  final PluginSourceTrust trust;
  final PluginHost host;
  final int enabled;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.xxl),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Icon(ReelishIcons.server, color: GlassTheme.primary, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  repository.name,
                  style: const TextStyle(
                    fontSize: AppTextSize.headline,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                host.label,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.caption,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  PluginTrustBadge(trust: trust),
                  if (repository.version case final version?)
                    PluginStatusChip(
                      icon: ReelishIcons.tag,
                      label: 'v$version',
                      color: GlassTheme.muted,
                    ),
                  PluginStatusChip(
                    icon: ReelishIcons.power,
                    label: '$enabled of ${repository.plugins.length} on',
                    color: enabled > 0 ? GlassTheme.primary : GlassTheme.muted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Providers whose code changed or was added, with the version change
/// where the manifest gives one.
class _PendingReview extends StatelessWidget {
  const _PendingReview({
    required this.repository,
    required this.pending,
    required this.service,
    required this.onApprove,
  });

  final ProviderRepository repository;
  final List<ProviderPlugin> pending;
  final ProviderPluginService service;
  final VoidCallback onApprove;

  String _change(ProviderPlugin plugin) {
    if (!service.hasApprovedCode(repository, plugin)) {
      return plugin.version == null
          ? 'New provider'
          : 'New provider, version ${plugin.version}';
    }
    final running = service.approvedVersionFor(repository, plugin);
    final listed = plugin.version;
    if (running != null && listed != null && running != listed) {
      return 'Version $running → $listed';
    }
    if (listed != null) return 'Code changed (manifest lists $listed)';
    return 'Code changed';
  }

  @override
  Widget build(BuildContext context) => PluginInfoCard(
    icon: ReelishIcons.systemUpdate,
    color: GlassTheme.warning,
    title: pending.length == 1
        ? '1 provider has new code'
        : '${pending.length} providers have new code',
    actions: [
      FilledButton.tonal(
        onPressed: onApprove,
        child: const Text('Review and allow'),
      ),
    ],
    children: [
      const PluginInfoText(
        'They are paused until you allow the new code. Allowing applies to '
        'every provider listed here.',
      ),
      for (final plugin in pending.take(8))
        PluginInfoText('• ${plugin.name}: ${_change(plugin)}'),
      if (pending.length > 8)
        PluginInfoText('• and ${pending.length - 8} more'),
    ],
  );
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    super.key,
    required this.plugin,
    required this.compatibility,
    required this.awaitingReview,
    required this.failed,
    required this.onOpen,
    required this.onChanged,
  });

  final ProviderPlugin plugin;
  final PluginCompatibility compatibility;
  final bool awaitingReview;
  final bool failed;
  final VoidCallback onOpen;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (plugin.version case final version?) 'v$version',
      describeContentTypes(plugin.supportedTypes),
    ].join('  ·  ');
    return Material(
      color: GlassTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: GlassTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              PluginLogo(
                name: plugin.name,
                url: plugin.logoUrl,
                size: 38,
                radius: 11,
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
                        fontWeight: FontWeight.w700,
                        fontSize: AppTextSize.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GlassTheme.muted,
                        fontSize: AppTextSize.micro,
                      ),
                    ),
                    if (awaitingReview ||
                        failed ||
                        compatibility.level !=
                            PluginCompatibilityLevel.compatible) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (awaitingReview)
                            PluginStatusChip(
                              icon: ReelishIcons.pause,
                              label: 'Paused for review',
                              color: GlassTheme.warning,
                            ),
                          if (failed)
                            PluginStatusChip(
                              icon: ReelishIcons.error,
                              label: 'Last search failed',
                              color: GlassTheme.danger,
                            ),
                          if (compatibility.level !=
                              PluginCompatibilityLevel.compatible)
                            PluginCompatibilityChip(level: compatibility.level),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Semantics(
                label: '${plugin.name} ${plugin.enabled ? 'on' : 'off'}',
                child: Switch(
                  value: plugin.enabled,
                  onChanged: compatibility.searchable || plugin.enabled
                      ? onChanged
                      : null,
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
}
