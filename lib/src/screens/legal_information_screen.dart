import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/device_capabilities.dart';
import '../services/app_metadata.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';

enum LegalDocument { privacy, terms, notices }

class LegalInformationScreen extends StatefulWidget {
  const LegalInformationScreen({
    super.key,
    required this.document,
    this.requireReadToEnd = false,
  });

  final LegalDocument document;
  final bool requireReadToEnd;

  static const _effectiveDate = 'October 16, 2026';

  /// The privacy policy's own date: it changed with accounts and the
  /// Reelish API, while the terms did not.
  static const _privacyDate = 'November 2, 2026';

  /// What Reelish is and is not responsible for. Shown first in the Terms of
  /// use and on the Credits screen; keep the wording exact.
  static const contentDisclaimer = (
    'Content disclaimer',
    'Reelish is a media discovery and playback application. Reelish does not '
        'host, store, upload, or distribute films, television programs, or '
        'any other copyrighted content, and no such content is stored on '
        'servers operated by Reelish.\n\n'
        'All streams are provided by independent third-party plugins and '
        'external services that users choose to install. Reelish does not '
        'own, operate, control, or endorse these sources, is not affiliated '
        'with their providers, and makes no representations regarding the '
        'legality, availability, accuracy, or quality of the content they '
        'provide. Users are solely responsible for ensuring that their use of '
        'any third-party source complies with the laws applicable in their '
        'jurisdiction.\n\n'
        'Movie and television metadata, including titles, descriptions, '
        'artwork, and ratings, is provided by The Movie Database (TMDB). All '
        'trademarks, logos, and content remain the property of their '
        'respective owners.',
  );

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
      subtitle:
          'Reelish · Updated ${widget.document == LegalDocument.privacy ? LegalInformationScreen._privacyDate : LegalInformationScreen._effectiveDate}',
      icon: _icon,
      controller: _scrollController,
      bottomBar: widget.requireReadToEnd
          ? SafeArea(
              top: false,
              child: Padding(
                // On a TV the button stays inside the overscan-safe area,
                // which many TVs crop.
                padding: DeviceCapabilities.isTv
                    ? const EdgeInsets.fromLTRB(
                        TvSafeArea.horizontal,
                        12,
                        TvSafeArea.horizontal,
                        TvSafeArea.vertical,
                      )
                    : const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
      'This policy describes the Reelish app and the Reelish API, the '
          'online service the app uses for accounts, the catalog and watch '
          'parties. To browse the catalog you sign in with a Trakt account; '
          'Reelish has no passwords of its own. Your device and the services '
          'you choose to use also process data as described below.',
    ),
    (
      'Your Reelish account',
      'You sign in on Trakt’s own page in your browser, or by entering a '
          'code on Trakt’s website from a TV. Reelish never sees your Trakt '
          'password. When you sign in, the Reelish API stores your Trakt '
          'account ID and username; your Trakt access tokens, encrypted, so '
          'the service can reach Trakt for you; and, for each signed-in '
          'device, a general label (such as “Android phone” or “Windows”), '
          'when it signed in and was last used, and session tokens kept only '
          'in hashed form. The service does not ask for your email address, '
          'contacts, payment details or precise location. Trakt’s own privacy '
          'policy applies to your Trakt account.',
    ),
    (
      'Information kept on your device',
      'The app stores your favorites, recently played titles and resume '
          'positions, playback and notification preferences, your profile '
          'display name and avatar choice, installed add-on repository '
          'addresses and settings, a short-lived cache of selected stream '
          'sources, and a copy of the plugin library catalog in the app’s '
          'private storage, and your sign-in session in the device’s secure '
          'storage. A profile photo you choose stays on the device and is '
          'never uploaded. The app has no advertising. Usage statistics are '
          'sent only if you agree (see Usage statistics). You can remove favorites and history in '
          'Library, remove add-ons in Plugins, clear the torrent cache in '
          'Playback settings, or erase app data by uninstalling the app. '
          'Device backups and operating-system behavior are controlled by '
          'your platform provider.',
    ),
    (
      'Information sent when you use network features',
      'When you browse, search or open titles, the app sends title '
          'identifiers and related requests to the Reelish API, which '
          'retrieves catalog data and details from The Movie Database (TMDB) '
          'for you; TMDB receives those requests from the service, not from '
          'your device. Artwork loads directly from TMDB’s image servers. If '
          'you turn on My list sync, the service reads and changes your Trakt '
          'watchlist for you. If you turn on new-episode alerts, the app sends '
          'the TMDB identifiers of series on My list or in progress to the '
          'service to check for new episodes; they are not stored. In a watch '
          'party, the title, the playback position and play or pause state, '
          'and each participant’s display name, chosen preset avatar (never a '
          'photo) and player status are shared through the service with the '
          'people in that party. Subtitle searches send a title or episode '
          'identifier to the OpenSubtitles v3 service. Opening the plugin '
          'library downloads its catalog from the app’s GitHub repository and '
          'loads provider logos from the addresses listed in it; those hosts '
          'can receive your IP address and request data, but no title or '
          'account information. If you install an add-on, the app contacts '
          'the repository and service addresses configured for it. Add-ons '
          'receive the title and episode identifiers needed for your request '
          'and may send them to their own servers. Direct streams, subtitle '
          'files and torrent/P2P playback connect to the selected source or '
          'peers; those operators can receive your IP address and request '
          'data. Video never passes through the Reelish API. Android and '
          'Windows may contact GitHub to check for app updates. When you '
          'choose an update, Android downloads an APK and uses its package '
          'installer after you confirm; installed Windows copies download the '
          'installer and run it after checking it, and portable copies '
          'download a ZIP for you to extract.',
    ),
    (
      'Problem reports and feedback',
      'When you send a report or feedback from Help & Support, the Reelish '
          'API stores what you wrote (title, category, details and optional '
          'steps), the device type you chose, and, unless you turn it off, '
          'the app version, build, operating system and version, interface, '
          'language and time. You see all of it before sending. It does not '
          'include your account name, history, providers or logs; the report '
          'is linked to a one-way code derived from your account so a person '
          'can send a limited number per day and so deleting your account '
          'deletes your reports. Reports are deleted after 180 days. Do not '
          'include personal information you do not want stored.',
    ),
    (
      'Usage statistics (Android only, optional)',
      'On Android phones, Android TV and Google TV, Reelish asks once '
          'whether you want to share usage statistics, and sends none until '
          'you agree. If you do, Google Analytics for Firebase receives which '
          'pages and features you use, whether a search found results (not '
          'what you searched for), and for each playback session the movie '
          'or episode’s public TMDB number, how long it took to start, '
          'buffering, the kind of error if it failed, and roughly how much '
          'was watched. It never receives your account, Trakt name, display '
          'name, search text, add-on or provider names, stream addresses or '
          'tokens. Google also records standard app information such as '
          'device model, operating-system version, app version, approximate '
          'country and an app-instance identifier; the advertising '
          'identifier, the Android ID and ad personalization are turned off. '
          'Google keeps this data under its own policies and Reelish’s '
          'retention setting. You can turn sharing off in Settings at any '
          'time; doing so also clears the analytics data and identifier '
          'stored on the device. Windows sends no usage statistics.',
    ),
    (
      'Third-party services and add-ons',
      'Trakt, TMDB, Cloudflare (which hosts the Reelish API), Google '
          '(usage statistics, only if you agree), OpenSubtitles, '
          'add-on publishers, media hosts, torrent peers, GitHub, and your '
          'device platform operate independently. Their privacy practices, '
          'logs, retention and locations are governed by their own policies. '
          'Cloudflare processes your IP address and request data to deliver '
          'the Reelish API. The app cannot control what an add-on publisher '
          'does with data it receives. Install only add-ons you trust. No '
          'payment, contacts, precise location or advertising identifier is '
          'requested by the app’s own features.',
    ),
    (
      'Retention and choices',
      'Your account data stays on the Reelish API until you delete your '
          'account. You can sign out of one device or of all devices, and '
          'delete your account in Settings > Profile and account; deleting '
          'it asks Trakt to revoke Reelish’s access and removes your account, '
          'your encrypted Trakt tokens and your device sessions, including '
          'those already signed out. A minimal security log, holding an '
          'internal account number, the kind of event (such as a sign-in or '
          'a sign-out) and its time, but no username, title or viewing '
          'information, is kept for 12 months to detect misuse, including '
          'after an account is deleted, and then erased. A watch party’s room is deleted when the party ends, '
          'and after 12 hours at most. Operational logs of the service record '
          'which address was requested and when, which can include a title '
          'identifier but not your account name, and are kept by the hosting '
          'provider for a limited period. On-device library entries and '
          'preferences remain until you remove them or erase app data. Third-'
          'party services may retain request data under their own policies; '
          'for data they hold, contact that service or add-on publisher '
          'directly. Applicable privacy rights depend on your location; '
          'contact the developer through the support contact on the store '
          'listing for requests concerning the app or the Reelish API.',
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
    LegalInformationScreen.contentDisclaimer,
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
