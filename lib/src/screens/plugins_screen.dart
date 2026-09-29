import 'package:flutter/material.dart';
import '../services/nuvio_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/nuvio_plugin_installer_modal.dart';
import '../widgets/glass_box.dart';

class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key, required this.pluginService});

  final NuvioPluginService pluginService;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pluginService,
    builder: (context, _) {
      final enabledCount = pluginService.repositories
          .expand((repo) => repo.plugins)
          .where((plugin) => plugin.enabled)
          .length;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Nuvio plugins'),
          actions: [
            IconButton(
              tooltip: 'Refresh repositories',
              onPressed: pluginService.load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () =>
              NuvioPluginInstallerModal.show(context, pluginService),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Install plugin'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          children: [
            Text(
              'Your providers  ·  $enabledCount enabled',
              style: TextStyle(color: GlassTheme.muted),
            ),
            const SizedBox(height: 12),
            if (pluginService.repositories.isNotEmpty && enabledCount == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GlassBox(
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.info_outline_rounded,
                      color: Colors.orangeAccent,
                    ),
                    title: Text('Turn on a provider'),
                    subtitle: Text(
                      'New providers may be off by default. Use a switch below to enable one before searching for streams.',
                    ),
                  ),
                ),
              ),
            if (pluginService.repositories.isEmpty)
              GlassBox(
                radius: 22,
                child: const Column(
                  children: [
                    Icon(
                      Icons.travel_explore_rounded,
                      size: 38,
                      color: GlassTheme.primary,
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Your next source starts here',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Install a Nuvio provider manifest and enable the sources you want to use.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                  ],
                ),
              ),
            for (final repo in pluginService.repositories)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassBox(
                  radius: 20,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Material(
                    color: Colors.transparent,
                    child: ExpansionTile(
                      leading: const Icon(
                        Icons.browse_gallery_rounded,
                        color: GlassTheme.primary,
                      ),
                      title: Text(
                        repo.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text('${repo.plugins.length} providers'),
                      trailing: IconButton(
                        tooltip: 'Remove repository',
                        onPressed: () => pluginService.remove(repo),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                      children: [
                        for (final plugin in repo.plugins)
                          SwitchListTile(
                            dense: true,
                            title: Text(plugin.name),
                            subtitle: plugin.description.isEmpty
                                ? null
                                : Text(
                                    plugin.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            value: plugin.enabled,
                            onChanged: (enabled) => pluginService
                                .setPluginEnabled(repo, plugin, enabled),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            for (final error in pluginService.errors.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassBox(
                  child: ListTile(
                    leading: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orangeAccent,
                    ),
                    title: Text(error.key),
                    subtitle: Text(error.value),
                    trailing: IconButton(
                      tooltip: 'Dismiss',
                      onPressed: () => pluginService.removeFailed(error.key),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
