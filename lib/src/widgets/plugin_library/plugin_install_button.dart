import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/plugin_catalog.dart';
import '../../services/provider_plugin_service.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'plugin_formatting.dart';

/// Hands a catalog manifest to the existing provider installer.
///
/// The library never installs or runs anything itself:
/// [ProviderPluginService.install] validates the manifest and network
/// destination exactly as it does for a manually pasted URL. What the
/// button shows comes from the service, never from an assumed outcome:
/// installed only once the service lists the repository.
class PluginInstallButton extends StatefulWidget {
  const PluginInstallButton({
    super.key,
    required this.plugin,
    required this.pluginService,
    this.compact = false,
  });

  final ReelishPlugin plugin;
  final ProviderPluginService pluginService;

  /// A card's shorter button: "Install" rather than "Install plugin".
  final bool compact;

  /// Whether [manifestUrl] is installed, including a repository that is
  /// installed but currently fails to load.
  static bool isInstalled(ProviderPluginService service, Uri? manifestUrl) {
    if (manifestUrl == null) return false;
    final url = manifestUrl.toString();
    return service.repositories.any((repo) => repo.url == url) ||
        service.errors.containsKey(url);
  }

  @override
  State<PluginInstallButton> createState() => _PluginInstallButtonState();
}

class _PluginInstallButtonState extends State<PluginInstallButton> {
  bool _installing = false;

  /// Why the last attempt failed, until the next one.
  String? _error;

  Future<void> _install() async {
    final url = widget.plugin.manifestUrl;
    if (url == null || _installing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GlassTheme.elevatedSurface,
        title: Text('Install ${widget.plugin.name}?'),
        content: Text(
          'This community repository was made by '
          '${widget.plugin.author ?? 'a third party'}, not Reelish. Its '
          'provider scripts run on this device and can make network requests. '
          'Install only if you trust this source.\n\n$url',
          style: const TextStyle(color: GlassTheme.muted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _installing) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repository = await widget.pluginService.install(url.toString());
      final count = repository.plugins.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Added $count ${count == 1 ? 'provider' : 'providers'} from '
            '${widget.plugin.name}. Turn them on or off in Plugins.',
          ),
        ),
      );
    } catch (error) {
      final message = describeInstallError(error);
      if (mounted) setState(() => _error = message);
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't install ${widget.plugin.name}. $message"),
        ),
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.pluginService,
    builder: (context, _) {
      final plugin = widget.plugin;
      final installed = PluginInstallButton.isInstalled(
        widget.pluginService,
        plugin.manifestUrl,
      );
      final failed = !installed && !_installing && _error != null;
      final canInstall =
          plugin.manifestUrl != null && !installed && !_installing;
      final label = installed
          ? 'Installed'
          : _installing
          ? 'Installing…'
          : plugin.manifestUrl == null
          ? 'No manifest'
          : failed
          ? 'Retry install'
          : widget.compact
          ? 'Install'
          : 'Install plugin';
      final height = widget.compact ? 44.0 : 48.0;
      final button = FilledButton.icon(
        onPressed: canInstall ? _install : null,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? AppSpace.md : AppSpace.lg,
          ),
          disabledBackgroundColor: installed
              ? GlassTheme.primary.withValues(alpha: .14)
              : null,
          disabledForegroundColor: installed ? GlassTheme.coralBright : null,
          textStyle: const TextStyle(
            fontFamily: GlassTheme.fontFamily,
            fontSize: AppTextSize.bodySmall,
            fontWeight: FontWeight.w800,
          ),
        ),
        icon: AnimatedSwitcher(
          duration: AppMotion.resolve(context, AppMotion.hover),
          child: _installing
              ? const SizedBox.square(
                  key: ValueKey('installing'),
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  installed
                      ? Symbols.check_circle_rounded
                      : failed
                      ? Symbols.error_rounded
                      : Symbols.download_rounded,
                  key: ValueKey(label),
                  size: 18,
                  fill: installed ? 1 : 0,
                ),
        ),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
      return Semantics(
        button: true,
        enabled: canInstall,
        label: installed
            ? '${plugin.name} is installed'
            : _installing
            ? 'Installing ${plugin.name}'
            : failed
            ? 'Retry installing ${plugin.name}. Last attempt failed: $_error'
            : 'Install ${plugin.name}',
        excludeSemantics: true,
        child: failed ? Tooltip(message: _error!, child: button) : button,
      );
    },
  );
}

/// Removes an installed catalog repository through the same
/// [ProviderPluginService.remove] the Plugins page uses, after the same
/// confirmation. Shows nothing while the manifest is not installed.
class PluginRemoveButton extends StatefulWidget {
  const PluginRemoveButton({
    super.key,
    required this.plugin,
    required this.pluginService,
  });

  final ReelishPlugin plugin;
  final ProviderPluginService pluginService;

  @override
  State<PluginRemoveButton> createState() => _PluginRemoveButtonState();
}

class _PluginRemoveButtonState extends State<PluginRemoveButton> {
  bool _removing = false;

  Future<void> _remove() async {
    final url = widget.plugin.manifestUrl?.toString();
    if (url == null || _removing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GlassTheme.elevatedSurface,
        title: Text('Remove ${widget.plugin.name}?'),
        content: const Text(
          'Its providers will no longer be searched when you press play. '
          'You can install it again from the library.',
          style: TextStyle(color: GlassTheme.muted, height: 1.4),
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
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    final service = widget.pluginService;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repository = service.repositories
          .where((repo) => repo.url == url)
          .firstOrNull;
      if (repository != null) {
        await service.remove(repository);
      } else {
        // Installed but failing to load: removed by URL, as on Plugins.
        await service.removeFailed(url);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${widget.plugin.name}.')),
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.pluginService,
    builder: (context, _) {
      if (!PluginInstallButton.isInstalled(
        widget.pluginService,
        widget.plugin.manifestUrl,
      )) {
        return const SizedBox.shrink();
      }
      return OutlinedButton.icon(
        onPressed: _removing ? null : _remove,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          foregroundColor: Colors.white,
          side: const BorderSide(color: GlassTheme.border),
        ),
        icon: _removing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.delete_rounded, size: 18),
        label: Text(_removing ? 'Removing…' : 'Remove'),
      );
    },
  );
}
