import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/glass_theme.dart';

enum LegalDocument { privacy, terms, notices }

class LegalInformationScreen extends StatelessWidget {
  const LegalInformationScreen({super.key, required this.document});

  final LegalDocument document;

  static const _projectUrl = 'https://github.com/frnzeeey/reelish';
  static const _effectiveDate = 'October 1, 2026';

  String get _title => switch (document) {
    LegalDocument.privacy => 'Privacy policy',
    LegalDocument.terms => 'Terms of use',
    LegalDocument.notices => 'Content & third-party notices',
  };

  @override
  Widget build(BuildContext context) {
    final sections = switch (document) {
      LegalDocument.privacy => _privacySections,
      LegalDocument.terms => _termsSections,
      LegalDocument.notices => _noticeSections,
    };

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
        children: [
          Text(
            'Onfeed (also shown as Reelish) · Updated $_effectiveDate',
            style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          for (final section in sections) ...[
            Text(
              section.$1,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              section.$2,
              style: const TextStyle(
                color: Colors.white70,
                height: 1.55,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
          ],
          OutlinedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(_projectUrl);
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
                  context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not open the project page.'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Project page & support'),
          ),
          const SizedBox(height: 8),
          const Text(
            'For privacy requests, use the developer contact published on the '
            'store listing. Do not post personal information in public issue '
            'trackers.',
            style: TextStyle(
              color: GlassTheme.muted,
              height: 1.45,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  static const _privacySections = <(String, String)>[
    (
      'Who this applies to',
      'This policy describes the Onfeed / Reelish app. The app does not ask '
          'you to create an account and has no app-operated account service. '
          'Your device and the services you choose to use still process data as '
          'described below.',
    ),
    (
      'Information kept on your device',
      'The app stores your favorites, recently played titles and resume '
          'positions, playback preferences, installed add-on repository '
          'addresses and settings, and a short-lived cache of selected stream '
          'sources. These are stored in the app’s private device storage. The '
          'app does not currently include its own advertising or analytics '
          'service. You can remove favorites and history in Library, remove '
          'add-ons in Plugins, clear the torrent cache in Playback settings, '
          'or erase app data by uninstalling the app. Device backups and '
          'operating-system behavior are controlled by your platform provider.',
    ),
    (
      'Information sent when you use network features',
      'When you browse, search or open titles, the app sends title identifiers '
          'and related requests to The Movie Database (TMDB) to retrieve '
          'catalog, artwork and details. Subtitle searches send a title or '
          'episode identifier to the OpenSubtitles v3 service. If you install '
          'an add-on, the app contacts the repository and service addresses '
          'configured for it. Add-ons receive the title and episode identifiers '
          'needed for your request and may send them to their own servers. '
          'Direct streams, subtitle files and torrent/P2P playback connect to '
          'the selected source or peers; those operators can receive your IP '
          'address and request data. Android may contact GitHub to check for '
          'app updates and download an APK when you choose an update. Android '
          'uses its package installer after you confirm the installation.',
    ),
    (
      'Third-party services and add-ons',
      'TMDB, OpenSubtitles, add-on publishers, media hosts, torrent peers, '
          'GitHub, and your device platform operate independently. Their '
          'privacy practices, logs, retention and locations are governed by '
          'their own policies. The app cannot control what an add-on publisher '
          'does with data it receives. Install only add-ons you trust. No '
          'payment, account credentials, contacts, precise location or '
          'advertising identifier is requested by the app’s own features.',
    ),
    (
      'Retention and choices',
      'On-device library entries and preferences remain until you remove them '
          'or erase app data. Catalog results may be cached in memory for the '
          'current session. Third-party services may retain request '
          'data under their own policies. Because the app has no account or '
          'developer-operated profile database, it has no server-side account '
          'data to delete. For data held by a third party, contact that service '
          'or add-on publisher directly. Applicable privacy rights depend on '
          'your location; contact the developer through the support contact '
          'on the store listing for requests concerning the app.',
    ),
    (
      'Children and changes',
      'The app is not designed as a service for children. A parent or guardian '
          'who believes a child has provided personal information to a '
          'third-party service should contact that service and the app '
          'publisher. This policy may change when app features or legal '
          'requirements change; the updated version and date will appear here.',
    ),
  ];

  static const _termsSections = <(String, String)>[
    (
      'Using the app',
      'These terms cover your use of Onfeed (also shown as Reelish). By using '
          'the app, you agree to follow these terms and the laws that apply to '
          'you. If you do not agree, stop using the app. The app is a media '
          'catalog and playback client. It does not host or supply a library of '
          'movies, shows or streams.',
    ),
    (
      'Content, add-ons and your responsibilities',
      'You choose which third-party add-ons, repositories, stream addresses '
          'and files to use. You are responsible for checking that your use and '
          'any access, copying, downloading or sharing is authorized where you '
          'live. Do not use the app to infringe copyright, bypass access '
          'controls, distribute unlawful material, or violate another '
          'person’s rights. P2P/torrent playback may share your network address '
          'with other participants and may upload pieces of a file. Add-ons '
          'and remote content can change without notice and may be inaccurate, '
          'unavailable or unsafe.',
    ),
    (
      'Third-party services and software',
      'Third-party services and add-ons are not controlled or endorsed by the '
          'app publisher. Their own terms and privacy policies apply. The app '
          'may include open-source software, which remains subject to its '
          'respective license. Third-party names and marks belong to their '
          'owners.',
    ),
    (
      'In-app updates',
      'On Android, the app checks the public GitHub releases page for a newer '
          'version. If one is available, you can choose to download its APK. '
          'You initiate installation in Android’s package installer; Android '
          'may ask you to allow installs from this source. Only install a '
          'release if you trust its source. Updates may also be installed '
          'through any distribution channel you use.',
    ),
    (
      'Availability and liability',
      'The app is provided as available. To the extent permitted by law, the '
          'publisher does not promise uninterrupted availability or the '
          'accuracy, legality, quality or safety of third-party content, and is '
          'not responsible for third-party services or networks. Nothing in '
          'these terms excludes liability or consumer rights that cannot '
          'lawfully be excluded in your jurisdiction.',
    ),
    (
      'Suspension, changes and applicable law',
      'The publisher may change or discontinue app features and may restrict '
          'use that creates security, legal or operational risk. These terms '
          'may be updated with the app; the current text and date are shown '
          'here. Applicable mandatory consumer protections remain in force. '
          'Any governing-law or dispute rules are those that apply to the '
          'publisher and user under applicable law.',
    ),
  ];

  static const _noticeSections = <(String, String)>[
    (
      'Catalog data and artwork',
      'This product uses the TMDB API but is not endorsed or certified by '
          'TMDB. TMDB supplies catalog metadata and imagery. TMDB trademarks '
          'and content remain with their respective owners; see TMDB’s terms '
          'and attribution requirements before redistributing any material.',
    ),
    (
      'External content',
      'Streams, subtitles, descriptions, artwork and add-on results come from '
          'third parties or user-configured sources. The app publisher does '
          'not verify ownership, licensing, accuracy, availability or safety '
          'of those materials and does not grant rights to them. Remove an '
          'add-on or stop playback if you believe a source violates rights or '
          'local law. Rights holders should use the support contact on the '
          'store listing to identify the material and relevant rights; do not '
          'include sensitive personal information in a public issue.',
    ),
    (
      'Reporting and support',
      'For technical issues, visit the project page. For a copyright or other '
          'legal notice, contact the developer using the up-to-date contact '
          'details on the app’s store listing and include enough information '
          'to identify the material and the right asserted. This in-app '
          'information is not a substitute for a formal notice required by '
          'your jurisdiction.',
    ),
  ];
}
