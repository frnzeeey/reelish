import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../navigation/app_transitions.dart';
import '../services/app_metadata.dart';
import '../theme/glass_theme.dart';
import '../widgets/app_update_flow.dart';
import '../widgets/settings/settings_components.dart';
import 'credits_screen.dart';

/// The Reelish name, icon and tagline, used where the app identifies itself.
class ReelishIdentity extends StatelessWidget {
  const ReelishIdentity({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 26),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.asset(
            'assets/icons/reelish_icon.png',
            width: 60,
            height: 60,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reelish',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.6,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'A streaming catalog app with add-on support and an in-app '
                'video player.',
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _copyCommit(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: AppMetadata.gitSha));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Commit copied.')));
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'About',
    subtitle: 'App information and version.',
    icon: Symbols.info_rounded,
    children: [
      const ReelishIdentity(),
      FutureBuilder<PackageInfo>(
        future: AppMetadata.packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final pending = snapshot.connectionState != ConnectionState.done;
          final fallback = pending ? 'Loading…' : 'Unavailable';
          return SettingsSection(
            label: 'BUILD IDENTITY',
            children: [
              SettingsTile(
                icon: Symbols.verified_rounded,
                title: 'Version',
                value: info?.version ?? fallback,
              ),
              SettingsTile(
                icon: Symbols.tag_rounded,
                title: 'Build',
                value: info?.buildNumber ?? fallback,
              ),
              if (AppMetadata.buildTag != 'local')
                const SettingsTile(
                  icon: Symbols.sell_rounded,
                  title: 'Tag',
                  value: AppMetadata.buildTag,
                ),
              SettingsTile(
                icon: Symbols.commit_rounded,
                title: 'Commit',
                description: 'Tap to copy.',
                value: AppMetadata.gitSha,
                showChevron: false,
                onTap: () => _copyCommit(context),
              ),
            ],
          );
        },
      ),
      if (AppUpdateFlow.isSupported)
        SettingsSection(
          label: 'UPDATES',
          children: [
            SettingsTile(
              icon: Symbols.system_update_rounded,
              title: 'Check for updates',
              description: 'Look for a newer release on GitHub.',
              onTap: () => AppUpdateFlow.checkManually(context),
            ),
          ],
        ),
      SettingsSection(
        label: 'MORE',
        children: [
          SettingsTile(
            icon: Symbols.handshake_rounded,
            title: 'Credits & attribution',
            description: 'TMDB, third-party services and acknowledgments',
            onTap: () => Navigator.of(context).push(
              AppPageRoute<void>(
                context: context,
                builder: (_) => const CreditsScreen(),
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

class SupportDevelopmentScreen extends StatelessWidget {
  const SupportDevelopmentScreen({super.key});

  static final _coffeeUri = Uri.https('www.buymeacoffee.com', '/frnzegl');

  Future<void> _openCoffeePage(BuildContext context) async {
    if (!await launchUrl(_coffeeUri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the support page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Support development',
    subtitle: 'Completely optional.',
    icon: Symbols.favorite_rounded,
    children: [
      const SettingsSection(
        label: 'A LITTLE SUPPORT GOES A LONG WAY',
        children: [
          SettingsParagraph(
            text:
                'If you enjoy Reelish, you can help with ongoing development '
                'and server costs. Support is completely optional and does not '
                'unlock features or content.',
          ),
        ],
      ),
      SizedBox(
        height: 54,
        child: FilledButton.icon(
          onPressed: () => _openCoffeePage(context),
          icon: const Icon(Symbols.coffee_rounded),
          label: const Text('Buy me a coffee'),
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Opens buymeacoffee.com in your browser.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GlassTheme.muted, fontSize: 11.5),
      ),
    ],
  );
}
