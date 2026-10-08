import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_metadata.dart';
import '../widgets/settings/settings_components.dart';

enum LegalDocument { privacy, terms, notices }

class LegalInformationScreen extends StatefulWidget {
  const LegalInformationScreen({
    super.key,
    required this.document,
    this.requireReadToEnd = false,
  });

  final LegalDocument document;
  final bool requireReadToEnd;

  static const _effectiveDate = 'October 6, 2026';

  /// Credits and third-party notices; also shown on the Credits screen.
  static const noticeSections = <(String, String)>[
    (
      'Catalog data and artwork',
      'This product uses the TMDB API but is not endorsed or certified by '
          'TMDB. TMDB supplies catalog metadata and imagery. TMDB trademarks '
          'and content remain with their respective owners; see TMDB’s terms '
          'and attribution requirements before redistributing any material.',
    ),
    (
      'Plugin library',
      'The plugin library lists provider repositories from a '
          'community-maintained catalog curated by wolf knight. Repository '
          'names, descriptions, logos and manifests belong to their authors, '
          'who build and maintain each provider independently of Reelish. '
          'A listing is not an endorsement or a verification of a provider.',
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

  @override
  State<LegalInformationScreen> createState() => _LegalInformationScreenState();
}

class _LegalInformationScreenState extends State<LegalInformationScreen> {
  final _scrollController = ScrollController();
  bool _hasReadToEnd = false;

  String get _title => switch (widget.document) {
    LegalDocument.privacy => 'Privacy policy',
    LegalDocument.terms => 'Terms of use',
    LegalDocument.notices => 'Credits & third-party notices',
  };

  IconData get _icon => switch (widget.document) {
    LegalDocument.privacy => Symbols.shield_rounded,
    LegalDocument.terms => Symbols.gavel_rounded,
    LegalDocument.notices => Symbols.handshake_rounded,
  };

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_checkReadProgress);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkReadProgress());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_checkReadProgress)
      ..dispose();
    super.dispose();
  }

  void _checkReadProgress() {
    if (!widget.requireReadToEnd ||
        !mounted ||
        _hasReadToEnd ||
        !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.extentAfter <= 0) {
      setState(() => _hasReadToEnd = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = switch (widget.document) {
      LegalDocument.privacy => _privacySections,
      LegalDocument.terms => _termsSections,
      LegalDocument.notices => LegalInformationScreen.noticeSections,
    };

    return SettingsScaffold(
      title: _title,
      subtitle: 'Reelish · Updated ${LegalInformationScreen._effectiveDate}',
      icon: _icon,
      controller: _scrollController,
      bottomBar: widget.requireReadToEnd
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _hasReadToEnd
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Done reading'),
                    ),
                  ),
                ),
              ),
            )
          : null,
      children: [
        SettingsSection(
          children: [
            for (final section in sections)
              SettingsParagraph(title: section.$1, text: section.$2),
          ],
        ),
        SettingsSection(
          label: 'CONTACT',
          description:
              'For privacy requests, use the developer contact published on '
              'the store listing. Do not post personal information in public '
              'issue trackers.',
          children: [
            SettingsTile(
              icon: Symbols.open_in_new_rounded,
              title: 'Project page & support',
              description: 'github.com/frnzeeey/reelish',
              onTap: () async {
                final uri = Uri.parse(AppMetadata.projectUrl);
                if (!await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    ) &&
                    context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Could not open the project page.'),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  static const _privacySections = <(String, String)>[
    (
      'Who this applies to',
      'This policy describes the Reelish app. The app does not ask '
          'you to create an account and has no app-operated account service. '
          'Your device and the services you choose to use still process data as '
          'described below.',
    ),
    (
      'Information kept on your device',
      'The app stores your favorites, recently played titles and resume '
          'positions, playback preferences, installed add-on repository '
          'addresses and settings, a short-lived cache of selected stream '
          'sources, and a copy of the plugin library catalog. These are stored in the app’s private device storage. The '
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
          'episode identifier to the OpenSubtitles v3 service. Opening the '
          'plugin library downloads its catalog from the app’s GitHub '
          'repository and loads provider logos from the addresses listed in '
          'the catalog; those hosts can receive your IP address and request '
          'data, but no title or account information is sent. If you install '
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
      'These terms cover your use of Reelish. By using '
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
          'unavailable or unsafe. The app checks each stream address before '
          'playback, but the video engine then follows redirects and playlist '
          'links chosen by the stream host, which can reach other addresses, '
          'including devices on your local network.',
    ),
    (
      'Third-party services and software',
      'Third-party services and add-ons are not controlled or endorsed by the '
          'app publisher. Their own terms and privacy policies apply. The app '
          'may include open-source software, which remains subject to its '
          'respective license. Third-party names and marks belong to their '
          'owners. Reelish is an independent app and is not affiliated with, '
          'endorsed by or sponsored by Stremio, CloudStream or '
          'OpenSubtitles. Their names are used only to describe compatible '
          'formats and services.',
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
}
