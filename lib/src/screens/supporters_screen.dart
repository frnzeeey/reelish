// Reelish Supporters: a place to thank the people who fund Reelish, and to
// support it. Supporting is optional and unlocks nothing; this page asks once,
// here, and never interrupts anyone. Shared by phone, TV and Windows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/supporter_controller.dart';
import '../platform/device_capabilities.dart';
import '../support/support_service.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/supporter_badge.dart';

class SupportersScreen extends StatefulWidget {
  const SupportersScreen({super.key, this.controller, this.openLink});

  /// [SupporterController.instance] when null.
  final SupporterController? controller;

  /// Opens a link outside the app; a test can stand in for it.
  @visibleForTesting
  final Future<bool> Function(Uri link)? openLink;

  @override
  State<SupportersScreen> createState() => _SupportersScreenState();
}

class _SupportersScreenState extends State<SupportersScreen>
    with WidgetsBindingObserver {
  late final SupporterController _supporters =
      widget.controller ?? SupporterController.instance;
  late Future<List<PublicSupporter>> _publicList;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _publicList = _loadList();
    unawaited(_supporters.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the browser: a donation may have just arrived.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_supporters.refresh());
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    _say('Supporter code copied');
  }

  /// Copies the code first, since Buy Me a Coffee cannot be told it.
  Future<void> _support(SupporterStatus? status) async {
    final code = status?.code;
    if (code != null) await Clipboard.setData(ClipboardData(text: code));
    final opened = await _open(SupportConfig.donationPage);
    if (!opened) {
      _say('Could not open the page. Visit ${SupportConfig.donationPageLabel}');
    } else if (code != null) {
      _say('Code copied. Paste it into your message.');
    }
  }

  /// False when nothing on this device can open [link], as an email address
  /// on most TVs.
  Future<bool> _open(Uri link) async {
    final open = widget.openLink;
    if (open != null) return open(link);
    try {
      return await launchUrl(link, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Shows what to send and where. The account is marked pending only once
  /// the viewer says it was sent: opening an email app proves nothing.
  Future<void> _reviewEmail(SupporterStatus status) async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => _ReviewEmailDialog(
        code: status.code,
        pending: status.state == SupporterState.pending,
        open: _open,
      ),
    );
    if (sent != true) return;
    _say(
      await _supporters.requestReview()
          ? 'Thank you. Your donation will be checked by hand.'
          : 'Could not reach Reelish. Try again in a moment.',
    );
  }

  Future<void> _editRecognition(SupporterStatus status, bool listed) async {
    if (!listed) {
      if (!await _supporters.setRecognition(listed: false)) {
        _say('Could not save that. Try again in a moment.');
      }
      _reloadList();
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PublicNameDialog(initial: status.publicName),
    );
    if (name == null) return;
    final saved = await _supporters.setRecognition(listed: true, name: name);
    if (!saved) _say('That name could not be saved. Try another.');
    _reloadList();
  }

  /// The list is far down a lazily built page, so nothing may be listening
  /// yet when this fails. Its section shows the failure once it is built.
  Future<List<PublicSupporter>> _loadList() {
    final list = _supporters.publicList();
    list.ignore();
    return list;
  }

  void _reloadList() {
    if (mounted) setState(() => _publicList = _loadList());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _supporters,
    builder: (context, _) {
      final status = _supporters.status;
      final verified = status?.state == SupporterState.verified;
      return SettingsScaffold(
        title: 'Reelish Supporters',
        subtitle: 'Completely optional, always appreciated.',
        icon: ReelishIcons.heart,
        children: [
          _Hero(status: status, onSupport: () => unawaited(_support(status))),
          const SizedBox(height: AppSpace.lg),
          if (status == null && _supporters.failed)
            SettingsSection(
              label: 'YOUR SUPPORT',
              children: [
                const SettingsParagraph(
                  text:
                      'Your supporter details could not be loaded. You can '
                      'still support Reelish, and add your code once this '
                      'page loads.',
                ),
                SettingsTile(
                  icon: ReelishIcons.refresh,
                  title: 'Try again',
                  onTap: () => unawaited(_supporters.refresh()),
                ),
              ],
            ),
          if (status != null && !verified)
            _HowItWorks(
              status: status,
              onCopy: () => unawaited(_copyCode(status.code)),
              onCheck: _supporters.loading
                  ? null
                  : () => unawaited(_supporters.refresh()),
              onReview: () => unawaited(_reviewEmail(status)),
            ),
          if (verified)
            SettingsSection(
              label: 'SUPPORTERS LIST',
              children: [
                SettingsSwitchTile(
                  icon: ReelishIcons.people,
                  title: 'Show me on the supporters list',
                  description: status!.listed
                      ? 'Listed as ${status.publicName}. You keep your badge '
                            'either way.'
                      : 'Off: you are not shown anywhere publicly. You keep '
                            'your badge either way.',
                  value: status.listed,
                  onChanged: (value) =>
                      unawaited(_editRecognition(status, value)),
                ),
              ],
            ),
          const SizedBox(height: AppSpace.lg),
          const SettingsSection(
            label: 'WHAT YOUR SUPPORT DOES',
            children: [
              _Benefit(
                icon: ReelishIcons.supporter,
                text:
                    'You receive the Reelish Supporter Badge, which never expires.',
              ),
              _Benefit(
                icon: ReelishIcons.people,
                text: 'You can be recognized here, if you choose to be.',
              ),
              _Benefit(
                icon: ReelishIcons.server,
                text: 'It helps pay for development and server costs.',
              ),
              _Benefit(
                icon: ReelishIcons.sparkle,
                text: 'It encourages future improvements and new features.',
              ),
              SettingsParagraph(
                text:
                    'Everything in Reelish stays available to everyone, '
                    'whether or not you donate. Every supporter gets the same '
                    'badge, whatever the amount. A refunded donation no longer '
                    'counts.',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          _SupportersList(list: _publicList, onRetry: _reloadList),
        ],
      );
    },
  );
}

/// The thank-you, the status and the one call to action.
class _Hero extends StatelessWidget {
  const _Hero({required this.status, required this.onSupport});

  final SupporterStatus? status;
  final VoidCallback onSupport;

  static const message =
      'Reelish is built with passion, dedication, and countless hours of '
      'development. If you enjoy using Reelish and want to support its '
      'continued development, your contribution means a lot. Every supporter '
      'helps make Reelish better.';

  @override
  Widget build(BuildContext context) {
    final verified = status?.state == SupporterState.verified;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(0x33F5B942)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0x26F5B942),
            GlassTheme.primary.withValues(alpha: .1),
            GlassTheme.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SupporterEmblem(size: 44),
          const SizedBox(height: AppSpace.sm),
          Text(
            verified
                ? 'Thank you for supporting Reelish'
                : 'Reelish Supporters',
            style: const TextStyle(
              fontSize: AppTextSize.headline,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          if (verified) ...[
            const SupporterBadge(),
            const SizedBox(height: AppSpace.xs),
            Text(
              status!.since == null
                  ? 'You help keep Reelish growing.'
                  : 'Supporter since ${supporterSinceLabel(status!.since!)}. '
                        'You help keep Reelish growing.',
              style: const TextStyle(color: GlassTheme.muted, height: 1.4),
            ),
          ] else
            const Text(
              message,
              style: TextStyle(color: GlassTheme.muted, height: 1.45),
            ),
          const SizedBox(height: AppSpace.md),
          if (DeviceCapabilities.isTv)
            _SupportFromPhone(code: verified ? null : status?.code)
          else ...[
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: onSupport,
                icon: const Icon(ReelishIcons.coffee),
                label: Text(verified ? 'Support again' : 'Support Reelish'),
                style: FilledButton.styleFrom(
                  textStyle: const TextStyle(
                    fontFamily: GlassTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Opens ${SupportConfig.donationPageLabel} in your browser.',
              style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Most TVs have no browser, so a TV gives what to do on a phone or computer
/// instead of a button that cannot work.
class _SupportFromPhone extends StatelessWidget {
  const _SupportFromPhone({required this.code});

  /// Null once the code is not needed, or before it has loaded.
  final String? code;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'On your phone or computer, open',
        style: TextStyle(color: GlassTheme.muted, fontSize: AppTextSize.body),
      ),
      const SizedBox(height: AppSpace.xxs),
      Text(
        SupportConfig.donationPageLabel,
        style: const TextStyle(
          fontSize: AppTextSize.titleLarge,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (code != null) ...[
        const SizedBox(height: AppSpace.sm),
        const Text(
          'and add this code to your message',
          style: TextStyle(color: GlassTheme.muted, fontSize: AppTextSize.body),
        ),
        const SizedBox(height: AppSpace.xxs),
        Text(
          code!,
          style: const TextStyle(
            color: Color(0xFFFFD98A),
            fontSize: AppTextSize.headline,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ],
    ],
  );
}

/// Month and year, as a reader says it.
String supporterSinceLabel(DateTime since) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[since.month - 1]} ${since.year}';
}

/// How a donation reaches this account, and what to do if the code was missed.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks({
    required this.status,
    required this.onCopy,
    required this.onCheck,
    required this.onReview,
  });

  final SupporterStatus status;
  final VoidCallback onCopy;
  final VoidCallback? onCheck;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final pending = status.state == SupporterState.pending;
    return SettingsSection(
      label: 'GET YOUR BADGE',
      children: [
        const SettingsParagraph(
          text:
              'Buy Me a Coffee cannot tell which Reelish account a donation '
              'came from, so your code does. Paste it into the message when '
              'you donate, and your badge arrives on its own, on all your '
              'devices.',
        ),
        // On TV the code is above, and there is nowhere to paste it.
        if (!DeviceCapabilities.isTv)
          SettingsTile(
            icon: ReelishIcons.copy,
            title: status.code,
            description: 'Your supporter code. Select to copy.',
            onTap: onCopy,
          ),
        SettingsTile(
          icon: ReelishIcons.refresh,
          title: 'I donated: check again',
          description: 'Your badge can take a minute or two to arrive.',
          onTap: onCheck,
        ),
        if (pending)
          const SettingsParagraph(
            text:
                'Review requested. Your badge appears once your email and '
                'donation have been checked by hand.',
          ),
        SettingsTile(
          icon: ReelishIcons.mail,
          title: pending ? 'See the review email' : 'I forgot to add my code',
          description: pending
              ? 'What to send and where, if you have not sent it yet.'
              : 'Send a short email from the address you donated with, so '
                    'your donation can be checked by hand.',
          onTap: onReview,
        ),
      ],
    );
  }
}

/// The email that proves a donation: where it goes, and what it says. Works
/// with no email app, since the details can be sent from any account.
class _ReviewEmailDialog extends StatefulWidget {
  const _ReviewEmailDialog({
    required this.code,
    required this.pending,
    required this.open,
  });

  final String code;
  final bool pending;
  final Future<bool> Function(Uri link) open;

  @override
  State<_ReviewEmailDialog> createState() => _ReviewEmailDialogState();
}

class _ReviewEmailDialogState extends State<_ReviewEmailDialog> {
  bool _noEmailApp = false;
  bool _copied = false;

  String get _subject => 'Supporter review ${widget.code}';
  String get _body =>
      'I donated to Reelish without adding my code.\n'
      'Supporter code: ${widget.code}';

  Future<void> _openEmail() async {
    final opened = await widget.open(
      Uri(
        scheme: 'mailto',
        path: SupportConfig.contactEmail,
        query:
            'subject=${Uri.encodeComponent(_subject)}'
            '&body=${Uri.encodeComponent(_body)}',
      ),
    );
    if (mounted && !opened) setState(() => _noEmailApp = true);
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: 'To: ${SupportConfig.contactEmail}\nSubject: $_subject\n\n$_body',
      ),
    );
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    return AlertDialog(
      title: const Text('Ask for a review'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tv
                  ? 'On your phone or computer, send this email from the '
                        'address you donated with.'
                  : 'Send this email from the address you donated with. That '
                        'shows the donation is yours.',
              style: const TextStyle(height: 1.4),
            ),
            const SizedBox(height: AppSpace.md),
            _EmailDetail(label: 'To', value: SupportConfig.contactEmail),
            _EmailDetail(label: 'Subject', value: _subject),
            if (_noEmailApp) ...[
              const SizedBox(height: AppSpace.xs),
              const Text(
                'No email app was found here. Copy the details and send them '
                'from any email account.',
                style: TextStyle(color: GlassTheme.warning, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actionsOverflowButtonSpacing: AppSpace.xs,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        if (!tv)
          TextButton(
            onPressed: () => unawaited(_copy()),
            child: Text(_copied ? 'Copied' : 'Copy details'),
          ),
        if (!tv)
          TextButton(
            onPressed: () => unawaited(_openEmail()),
            child: const Text('Open email app'),
          ),
        // Saying so again changes nothing once the review is requested.
        if (!widget.pending)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I sent it'),
          ),
      ],
    );
  }
}

class _EmailDetail extends StatelessWidget {
  const _EmailDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
        ),
        SelectableText(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.md,
      vertical: AppSpace.xs,
    ),
    child: Row(
      children: [
        Icon(icon, size: AppIcon.md, color: GlassTheme.primary),
        const SizedBox(width: AppSpace.sm),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ],
    ),
  );
}

/// The people who chose to be shown. Never filled with examples.
class _SupportersList extends StatelessWidget {
  const _SupportersList({required this.list, required this.onRetry});

  final Future<List<PublicSupporter>> list;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<PublicSupporter>>(
    future: list,
    builder: (context, snapshot) {
      final supporters = snapshot.data;
      return SettingsSection(
        label: 'OUR SUPPORTERS',
        children: [
          if (snapshot.hasError)
            SettingsTile(
              icon: ReelishIcons.refresh,
              title: 'The list could not be loaded',
              description: 'Try again',
              onTap: onRetry,
            )
          else if (supporters == null)
            const Padding(
              padding: EdgeInsets.all(AppSpace.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (supporters.isEmpty)
            const SettingsParagraph(
              text:
                  'Supporters who choose to be shown will appear here. '
                  'Thank you to everyone helping quietly.',
            )
          else
            for (final person in supporters)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.xs,
                ),
                child: Row(
                  children: [
                    const SupporterEmblem(size: 22),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      );
    },
  );
}

class _PublicNameDialog extends StatefulWidget {
  const _PublicNameDialog({required this.initial});

  final String initial;

  @override
  State<_PublicNameDialog> createState() => _PublicNameDialogState();
}

class _PublicNameDialogState extends State<_PublicNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Your name on the list'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 40,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        hintText: 'Any name you like',
        helperText: 'Anyone using Reelish can see this.',
      ),
      onSubmitted: (value) => Navigator.pop(context, value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _name.text.trim()),
        child: const Text('Show me'),
      ),
    ],
  );
}
