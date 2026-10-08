import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/subtitle_addon.dart';
import '../services/subtitle_addon_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';

/// Stremio subtitle addons the player searches while you watch.
/// OpenSubtitles v3 is preinstalled.
class SubtitleAddonsScreen extends StatefulWidget {
  const SubtitleAddonsScreen({super.key, this.service});

  final SubtitleAddonService? service;

  @override
  State<SubtitleAddonsScreen> createState() => _SubtitleAddonsScreenState();
}

class _SubtitleAddonsScreenState extends State<SubtitleAddonsScreen> {
  late final SubtitleAddonService _service =
      widget.service ?? SubtitleAddonService();
  final _url = TextEditingController();
  List<SubtitleAddon> _addons = const [];
  bool _loading = true;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final addons = await _service.addons();
    if (mounted) {
      setState(() {
        _addons = addons;
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    final url = _url.text.trim();
    if (url.isEmpty || _installing) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final addon = await _service.install(url);
      _url.clear();
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${addon.name} added')));
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _remove(SubtitleAddon addon) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${addon.name}?'),
        content: const Text(
          'Its subtitles will no longer appear in the player.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.remove(addon);
    await _reload();
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Subtitle addons',
    subtitle: 'Sources searched for subtitles while you watch.',
    icon: Symbols.closed_caption_rounded,
    children: [
      if (_loading)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: CircularProgressIndicator(color: GlassTheme.primary),
          ),
        )
      else ...[
        SettingsSection(
          label: 'INSTALLED',
          description:
              'While a title plays, Reelish asks these Stremio subtitle '
              'addons for subtitles. Addons only receive the IMDb id, season '
              'and episode.',
          children: [
            for (final addon in _addons)
              _AddonTile(
                addon: addon,
                onToggle: (enabled) async {
                  await _service.setEnabled(addon, enabled);
                  await _reload();
                },
                onRemove: () => _remove(addon),
              ),
            if (_addons.isEmpty)
              const SettingsTile(
                icon: Symbols.subtitles_off_rounded,
                title: 'No subtitle addons',
                description: 'Add one below to get external subtitles.',
              ),
          ],
        ),
        SettingsSection(
          label: 'ADD AN ADDON',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _install(),
                    decoration: InputDecoration(
                      hintText: 'https://…/manifest.json',
                      labelText: 'Manifest URL',
                      errorText: _error,
                      fillColor: GlassTheme.elevatedSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _installing ? null : _install,
                      icon: _installing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Symbols.add_rounded),
                      label: const Text('Add addon'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!_addons.any(
              (addon) => addon.id == SubtitleAddon.openSubtitlesV3.id,
            ))
              SettingsTile(
                icon: Symbols.restore_rounded,
                title: 'Restore OpenSubtitles v3',
                description: 'Reinstall the default subtitle addon.',
                onTap: _installing
                    ? null
                    : () {
                        _url.text = SubtitleAddon.openSubtitlesV3.manifestUrl;
                        _install();
                      },
              ),
          ],
        ),
      ],
    ],
  );
}

class _AddonTile extends StatelessWidget {
  const _AddonTile({
    required this.addon,
    required this.onToggle,
    required this.onRemove,
  });

  final SubtitleAddon addon;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: Symbols.closed_caption_rounded,
    title: addon.name,
    // Host only: configured addon URLs can contain tokens.
    description: Uri.tryParse(addon.manifestUrl)?.host ?? '',
    mergeSemantics: false,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch.adaptive(value: addon.enabled, onChanged: onToggle),
        IconButton(
          tooltip: 'Remove ${addon.name}',
          onPressed: onRemove,
          icon: const Icon(Symbols.delete_rounded),
        ),
      ],
    ),
  );
}
