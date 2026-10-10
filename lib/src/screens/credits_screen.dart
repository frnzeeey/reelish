import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_metadata.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/settings/tmdb_attribution.dart';
import 'legal_information_screen.dart';

bool _bundledLicensesRegistered = false;

/// Adds licenses for bundled assets that no package reports, such as the
/// Montserrat font, to Flutter's license registry. Safe to call repeatedly.
void registerBundledLicenses() {
  if (_bundledLicensesRegistered) return;
  _bundledLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Montserrat',
    ], await rootBundle.loadString('assets/fonts/Montserrat-OFL.txt'));
  });
}

/// Opens Flutter's license page for Reelish and its dependencies.
Future<void> showAppLicenses(BuildContext context) async {
  registerBundledLicenses();
  PackageInfo? info;
  try {
    info = await AppMetadata.packageInfo;
  } catch (_) {
    // The page still lists every license without a version.
  }
  if (!context.mounted) return;
  showLicensePage(
    context: context,
    applicationName: 'Reelish',
    applicationVersion: info?.version,
    applicationIcon: Padding(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.asset(
          'assets/icons/reelish_icon.png',
          width: 48,
          height: 48,
        ),
      ),
    ),
    applicationLegalese: TmdbAttribution.disclaimer,
  );
}

Future<void> _openExternal(BuildContext context, Uri uri, String name) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not open $name.')));
  }
}

/// Credits for the data, services and software Reelish relies on.
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  static (String, String) _notice(String title) => LegalInformationScreen
      .noticeSections
      .firstWhere((section) => section.$1 == title);

  @override
  Widget build(BuildContext context) {
    final pluginLibrary = _notice('Plugin library');
    final externalContent = _notice('External content');
    final reporting = _notice('Reporting and support');
    return SettingsScaffold(
      title: 'Credits & attribution',
      subtitle: 'Data, services and software behind Reelish.',
      icon: Symbols.handshake_rounded,
      // The full TMDB attribution is on this page; the footer only repeats
      // the required notice, without a second logo.
      footer: const TmdbAttributionFooter(showLogo: false),
      children: [
        SettingsSection(
          label: 'DATA & METADATA',
          children: [
            const _TmdbAttributionBlock(),
            SettingsTile(
              icon: Symbols.open_in_new_rounded,
              title: 'The Movie Database (TMDB)',
              description: 'www.themoviedb.org',
              onTap: () => _openExternal(
                context,
                TmdbAttribution.website,
                'The Movie Database',
              ),
            ),
          ],
        ),
        SettingsSection(
          label: 'CONTENT DISCLAIMER',
          children: [
            SettingsParagraph(
              text: LegalInformationScreen.contentDisclaimer.$2,
            ),
          ],
        ),
        SettingsSection(
          label: 'THIRD-PARTY SERVICES',
          children: [
            const SettingsTile(
              icon: Symbols.closed_caption_rounded,
              title: 'OpenSubtitles v3',
              description:
                  'Preinstalled Stremio subtitle addon used to search for '
                  'subtitles. Reelish is not affiliated with OpenSubtitles.',
            ),
            const SettingsTile(
              icon: Symbols.cloud_rounded,
              title: 'GitHub',
              description:
                  'Hosts Reelish releases for update checks and the plugin '
                  'library catalog.',
            ),
            SettingsParagraph(title: pluginLibrary.$1, text: pluginLibrary.$2),
            SettingsParagraph(
              title: externalContent.$1,
              text: externalContent.$2,
            ),
          ],
        ),
        SettingsSection(
          label: 'OPEN-SOURCE ACKNOWLEDGMENTS',
          children: [
            const SettingsParagraph(
              text:
                  'Reelish is built with Flutter and open-source packages. '
                  'The Montserrat typeface is used under the SIL Open Font '
                  'License 1.1. Each component remains subject to its own '
                  'license.',
            ),
            SettingsTile(
              icon: Symbols.code_rounded,
              title: 'Open-source licenses',
              description: 'Full license texts for every package and font',
              onTap: () => showAppLicenses(context),
            ),
          ],
        ),
        FutureBuilder<PackageInfo>(
          future: AppMetadata.packageInfo,
          builder: (context, snapshot) {
            final info = snapshot.data;
            final fallback = snapshot.connectionState == ConnectionState.done
                ? 'Unavailable'
                : 'Loading…';
            return SettingsSection(
              label: 'REELISH INFORMATION',
              children: [
                const SettingsTile(
                  icon: Symbols.movie_rounded,
                  title: 'App name',
                  value: 'Reelish',
                ),
                SettingsTile(
                  icon: Symbols.verified_rounded,
                  title: 'Version',
                  value: info == null
                      ? fallback
                      : '${info.version} (build ${info.buildNumber})',
                ),
                SettingsTile(
                  icon: Symbols.code_blocks_rounded,
                  title: 'Project page & support',
                  description: 'github.com/frnzeeey/reelish',
                  onTap: () => _openExternal(
                    context,
                    Uri.parse(AppMetadata.projectUrl),
                    'the project page',
                  ),
                ),
                SettingsParagraph(title: reporting.$1, text: reporting.$2),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// TMDB's logo, required notice and a description of what TMDB supplies.
///
/// Laid out as a plain credit, not a promotion: the logo sits at a modest
/// size beneath Reelish's own branding, unmodified and on the dark surface
/// TMDB's gradient artwork is designed for.
class _TmdbAttributionBlock extends StatelessWidget {
  const _TmdbAttributionBlock();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(16, 20, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TmdbLogo(height: 20),
        SizedBox(height: 16),
        Text(
          TmdbAttribution.disclaimer,
          style: TextStyle(
            color: GlassTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.45,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Movie and TV show information, including titles, descriptions, '
          'artwork, ratings, and related metadata, may be provided by The '
          'Movie Database (TMDB).',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'TMDB trademarks and content remain with their respective owners; '
          'see TMDB’s terms and attribution requirements before '
          'redistributing any material.',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: 11.5,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}
