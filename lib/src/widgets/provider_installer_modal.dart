import 'package:flutter/material.dart';
import '../theme/reelish_icons.dart';
import 'package:flutter/services.dart';
import '../platform/device_capabilities.dart';
import '../services/provider_plugin_service.dart';
import '../theme/glass_theme.dart';
import 'glass_box.dart';
import 'tv/tv_focus.dart';
import 'glass_button.dart';

class ProviderInstallerModal extends StatefulWidget {
  const ProviderInstallerModal({super.key, required this.pluginService});

  final ProviderPluginService pluginService;

  static Future<void> show(
    BuildContext context,
    ProviderPluginService pluginService,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ProviderInstallerModal(pluginService: pluginService),
  );

  @override
  State<ProviderInstallerModal> createState() => _ProviderInstallerModalState();
}

class _ProviderInstallerModalState extends State<ProviderInstallerModal> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clipboard?.text == null) return;
    setState(() {
      _url.text = clipboard!.text!.trim();
      _error = null;
      _success = null;
    });
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final repository = await widget.pluginService.install(_url.text);
      if (!mounted) return;
      setState(() {
        _url.clear();
        _success =
            'Added ${repository.plugins.length} provider(s). Enable the ones you want to use.';
      });
      FocusScope.of(context).unfocus();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: GlassBox(
        radius: 26,
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Add by link',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(ReelishIcons.close),
                  ),
                ],
              ),
              Text(
                'Provider scripts run on this device and can make network requests. Add only collections you trust. Use an HTTPS manifest link.',
                style: TextStyle(color: GlassTheme.muted),
              ),
              const SizedBox(height: 16),
              if (DeviceCapabilities.usesTvLayout)
                // The TV keyboard edits the URL in a dialog, so the remote
                // is never trapped in the field.
                Row(
                  children: [
                    Expanded(
                      child: TvTextField(
                        autofocus: true,
                        value: _url.text,
                        hint: 'Provider manifest URL',
                        icon: ReelishIcons.link,
                        keyboardType: TextInputType.url,
                        onChanged: (value) => setState(() => _url.text = value),
                        onSubmitted: (_) => _busy ? null : _install(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      tooltip: 'Paste from clipboard',
                      onPressed: _busy ? null : _paste,
                      icon: const Icon(ReelishIcons.paste),
                    ),
                  ],
                )
              else
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _install(),
                  decoration: InputDecoration(
                    hintText: 'Provider manifest URL',
                    prefixIcon: const Icon(ReelishIcons.link),
                    suffixIcon: IconButton(
                      tooltip: 'Paste from clipboard',
                      onPressed: _busy ? null : _paste,
                      icon: const Icon(ReelishIcons.paste),
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: GlassTheme.danger)),
              ],
              if (_success != null) ...[
                const SizedBox(height: 10),
                Text(_success!, style: TextStyle(color: GlassTheme.primary)),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _install,
                  icon: _busy
                      ? const GlassButtonProgress()
                      : const Icon(ReelishIcons.download),
                  label: Text(_busy ? 'Checking manifest…' : 'Add collection'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
