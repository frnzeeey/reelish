import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/plugin_catalog.dart';
import '../../services/provider_plugin_service.dart';
import '../../theme/glass_theme.dart';

/// Hands a catalog manifest to the existing provider installer.
///
/// The library never installs or runs anything itself:
/// [ProviderPluginService.install] validates the manifest and network
/// destination exactly as it does for a manually pasted URL.
class PluginInstallButton extends StatefulWidget {
  const PluginInstallButton({
    super.key,
    required this.plugin,
    required this.pluginService,
  });

  final ReelishPlugin plugin;
  final ProviderPluginService pluginService;

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

  Future<void> _install() async {
    final url = widget.plugin.manifestUrl;
    if (url == null) return;
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
    if (confirmed != true || !mounted) return;
    setState(() => _installing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repository = await widget.pluginService.install(url.toString());
      final count = repository.plugins.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Added $count ${count == 1 ? 'provider' : 'providers'}. '
            'Turn them on or off in Plugins.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.toString().replaceFirst(
              RegExp(r'^[A-Za-z]*Exception:\s*'),
              '',
            ),
          ),
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
      final installed = PluginInstallButton.isInstalled(
        widget.pluginService,
        widget.plugin.manifestUrl,
      );
      final canInstall =
          widget.plugin.manifestUrl != null && !installed && !_installing;
      final label = installed
          ? 'Installed'
          : _installing
          ? 'Installing…'
          : widget.plugin.manifestUrl == null
          ? 'No manifest'
          : 'Install plugin';
      return Semantics(
        button: true,
        enabled: canInstall,
        label: installed
            ? '${widget.plugin.name} is installed'
            : 'Install ${widget.plugin.name}',
        excludeSemantics: true,
        child: FilledButton.icon(
          onPressed: canInstall ? _install : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            disabledBackgroundColor: installed
                ? GlassTheme.primary.withValues(alpha: .16)
                : null,
            disabledForegroundColor: installed ? GlassTheme.primary : null,
          ),
          icon: _installing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  installed
                      ? Symbols.check_circle_rounded
                      : Symbols.download_rounded,
                ),
          label: Text(label),
        ),
      );
    },
  );
}
