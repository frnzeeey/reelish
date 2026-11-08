import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/reelish_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../desktop/desktop_update_section.dart';
import '../navigation/app_transitions.dart';
import '../services/app_metadata.dart';
import '../theme/glass_theme.dart';
import '../widgets/app_update_flow.dart';
import '../widgets/settings/settings_components.dart';
import 'credits_screen.dart';
import '../widgets/brand_logo.dart';

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
            BrandAssets.appIcon,
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
              Text(
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
    icon: ReelishIcons.info,
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
                icon: ReelishIcons.verified,
                title: 'Version',
                value: info?.version ?? fallback,
              ),
              SettingsTile(
                icon: ReelishIcons.hash,
                title: 'Build',
                value: info?.buildNumber ?? fallback,
              ),
              if (AppMetadata.buildTag != 'local')
                const SettingsTile(
                  icon: ReelishIcons.tag,
                  title: 'Tag',
                  value: AppMetadata.buildTag,
                ),
              SettingsTile(
                icon: ReelishIcons.commit,
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
      if (AppUpdateFlow.isSupported &&
          defaultTargetPlatform == TargetPlatform.windows)
        FutureBuilder<PackageInfo>(
          future: AppMetadata.packageInfo,
          builder: (context, snapshot) => WindowsUpdateSection(
            installedVersion:
                snapshot.data?.version ??
                (snapshot.connectionState == ConnectionState.done
                    ? 'Unavailable'
                    : 'Loading…'),
          ),
        )
      else if (AppUpdateFlow.isSupported)
        SettingsSection(
          label: 'UPDATES',
          children: [
            SettingsTile(
              icon: ReelishIcons.systemUpdate,
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
            icon: ReelishIcons.credits,
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
