// Help & Support in Settings: answers (FAQ, troubleshooting), a bug report
// and feedback form that sends to the Reelish API, and links to app
// information. Shared by phone, TV and the Windows settings pane.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/reelish_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/crash_reporter.dart';
import '../diagnostics/local_error_log.dart';
import '../navigation/app_transitions.dart';
import '../support/help_content.dart';
import '../support/support_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';
import 'app_information_screens.dart';
import 'legal_information_screen.dart';

void _push(BuildContext context, WidgetBuilder builder) => unawaited(
  Navigator.of(
    context,
  ).push(AppPageRoute<void>(context: context, builder: builder)),
);

/// Opens [uri] outside the app. TVs often have no browser, so a failure
/// shows the address to visit instead.
Future<void> _openExternal(BuildContext context, Uri uri) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Open ${uri.host}${uri.path} in a browser.')),
    );
  }
}

/// Opens an email to support. Many TVs have no email app: then the address
/// is copied, and the viewer is told where to send it from.
Future<void> _emailSupport(BuildContext context) async {
  const address = SupportConfig.contactEmail;
  var opened = false;
  try {
    opened = await launchUrl(
      Uri(
        scheme: 'mailto',
        path: address,
        query: 'subject=${Uri.encodeComponent('Reelish support')}',
      ),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
  if (opened || !context.mounted) return;
  await Clipboard.setData(const ClipboardData(text: address));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No email app here. $address was copied; send your message from '
          'another device or app.',
        ),
      ),
    );
  }
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key, this.service});

  /// Replaces the report sender (tests).
  final SupportService? service;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Help & Support',
    subtitle: 'Answers, contact, and everything about Reelish.',
    icon: ReelishIcons.support,
    children: [
      SettingsSection(
        label: 'FIND AN ANSWER',
        children: [
          SettingsTile(
            icon: ReelishIcons.help,
            title: 'Frequently asked questions',
            description: 'Search answers about Reelish',
            onTap: () => _push(context, (_) => const FaqScreen()),
          ),
          SettingsTile(
            icon: ReelishIcons.repair,
            title: 'Troubleshooting',
            description: 'Fix playback, sources, subtitles and more',
            onTap: () =>
                _push(context, (_) => TroubleshootingScreen(service: service)),
          ),
        ],
      ),
      SettingsSection(
        label: 'GET IN TOUCH',
        children: [
          SettingsTile(
            icon: ReelishIcons.bug,
            title: 'Report a problem',
            description: 'Tell the developer what went wrong',
            onTap: () => _push(
              context,
              (_) => ReportScreen(kind: ReportKind.bug, service: service),
            ),
          ),
          SettingsTile(
            icon: ReelishIcons.lightbulb,
            title: 'Send feedback',
            description: 'Ideas, suggestions and questions',
            onTap: () => _push(
              context,
              (_) => ReportScreen(kind: ReportKind.feedback, service: service),
            ),
          ),
          if (SupportConfig.contactEmail.isNotEmpty)
            SettingsTile(
              icon: ReelishIcons.mail,
              title: 'Email support',
              description: SupportConfig.contactEmail,
              onTap: () => _emailSupport(context),
            ),
          SettingsTile(
            icon: ReelishIcons.chat,
            title: 'Project page',
            description: 'Public issues and discussion on GitHub',
            onTap: () => _openExternal(context, SupportConfig.publicIssues),
          ),
        ],
      ),
      SettingsSection(
        label: 'ABOUT REELISH',
        children: [
          SettingsTile(
            icon: ReelishIcons.info,
            title: 'About Reelish',
            description: 'Version, build and updates',
            onTap: () => _push(context, (_) => const AboutScreen()),
          ),
          SettingsTile(
            icon: ReelishIcons.newBadge,
            title: 'Release notes',
            description: 'What changed in each version',
            onTap: () => _openExternal(context, SupportConfig.releaseNotes),
          ),
          SettingsTile(
            icon: ReelishIcons.heart,
            title: 'Support development',
            description: 'Optional help with development and server costs',
            onTap: () =>
                _push(context, (_) => const SupportDevelopmentScreen()),
          ),
          // Windows only: there, errors stay in a log on this computer.
          if (CrashReporter.instance.localLog case final log?)
            SettingsTile(
              icon: ReelishIcons.document,
              title: 'Open error log',
              description: 'Stays on this computer; nothing is sent',
              onTap: () => unawaited(_openErrorLog(log)),
            ),
        ],
      ),
      // A heading, not a page of its own: each document is one tap from here.
      SettingsSection(
        label: 'LEGAL',
        children: [
          SettingsTile(
            icon: ReelishIcons.shield,
            title: 'Privacy policy',
            description:
                'What stays on your device and what is sent to services',
            onTap: () => _push(
              context,
              (_) =>
                  const LegalInformationScreen(document: LegalDocument.privacy),
            ),
          ),
          SettingsTile(
            icon: ReelishIcons.gavel,
            title: 'Terms of use',
            description: 'Rules for using the app, add-ons and media sources',
            onTap: () => _push(
              context,
              (_) =>
                  const LegalInformationScreen(document: LegalDocument.terms),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Searchable, filterable questions with answers that open in place.
class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  final _query = TextEditingController();
  FaqCategory? _category;
  final Set<FaqEntry> _open = {};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final entry in faqEntries)
        if ((_category == null || entry.category == _category) &&
            entry.matches(_query.text))
          entry,
    ];
    return SettingsScaffold(
      title: 'Questions',
      subtitle: 'Answers about how Reelish works.',
      icon: ReelishIcons.help,
      children: [
        TextField(
          controller: _query,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search questions',
            prefixIcon: const Icon(ReelishIcons.search),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(ReelishIcons.close),
                    onPressed: () => setState(_query.clear),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: _category == null,
              onSelected: (_) => setState(() => _category = null),
            ),
            for (final category in FaqCategory.values)
              if (faqEntries.any((entry) => entry.category == category))
                ChoiceChip(
                  label: Text(category.label),
                  selected: _category == category,
                  onSelected: (_) => setState(
                    () => _category = _category == category ? null : category,
                  ),
                ),
          ],
        ),
        const SizedBox(height: 18),
        if (visible.isEmpty)
          SettingsSection(
            label: 'NO MATCHES',
            children: [
              const SettingsParagraph(
                text:
                    'No question matches your search. Try fewer words, or '
                    'see Troubleshooting for common problems.',
              ),
              SettingsTile(
                icon: ReelishIcons.repair,
                title: 'Troubleshooting',
                onTap: () =>
                    _push(context, (_) => const TroubleshootingScreen()),
              ),
            ],
          )
        else
          SettingsSection(
            label: _category?.label.toUpperCase() ?? 'ALL QUESTIONS',
            children: [
              for (final entry in visible)
                _FaqTile(
                  entry: entry,
                  open: _open.contains(entry),
                  onToggle: () => setState(() {
                    if (!_open.remove(entry)) _open.add(entry);
                  }),
                ),
            ],
          ),
      ],
    );
  }
}

class _FaqTile extends StatelessWidget {
  const _FaqTile({
    required this.entry,
    required this.open,
    required this.onToggle,
  });

  final FaqEntry entry;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        expanded: open,
        child: SettingsTile(
          title: entry.question,
          showChevron: false,
          trailing: AnimatedRotation(
            turns: open ? .5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(ReelishIcons.chevronDown),
          ),
          onTap: onToggle,
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: open
            ? Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  entry.answer,
                  style: const TextStyle(color: GlassTheme.muted, height: 1.5),
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
    ],
  );
}

class TroubleshootingScreen extends StatelessWidget {
  const TroubleshootingScreen({super.key, this.service});

  final SupportService? service;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Troubleshooting',
    subtitle: 'Common problems and how to fix them.',
    icon: ReelishIcons.repair,
    children: [
      SettingsSection(
        label: 'COMMON PROBLEMS',
        children: [
          for (final article in troubleshootingArticles)
            SettingsTile(
              title: article.title,
              description: article.summary,
              onTap: () => _push(
                context,
                (_) => TroubleshootingArticleScreen(
                  article: article,
                  service: service,
                ),
              ),
            ),
        ],
      ),
    ],
  );
}

class TroubleshootingArticleScreen extends StatelessWidget {
  const TroubleshootingArticleScreen({
    super.key,
    required this.article,
    this.service,
  });

  final TroubleshootingArticle article;
  final SupportService? service;

  Widget _list(String label, List<String> items, {bool numbered = false}) =>
      SettingsSection(
        label: label,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      numbered ? '${i + 1}.' : '•',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(
                    child: Text(items[i], style: const TextStyle(height: 1.45)),
                  ),
                ],
              ),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: article.title,
    subtitle: article.summary,
    icon: ReelishIcons.repair,
    children: [
      _list('POSSIBLE CAUSES', article.causes),
      _list('TRY THIS', article.solutions, numbered: true),
      if (article.moreSteps.isNotEmpty) _list('ALSO', article.moreSteps),
      SettingsSection(
        label: 'STILL NOT WORKING?',
        children: [
          SettingsTile(
            icon: ReelishIcons.bug,
            title: 'Report this problem',
            description: 'Opens a report with this problem filled in',
            onTap: () => _push(
              context,
              (_) => ReportScreen(
                kind: ReportKind.bug,
                initialCategory: article.reportCategory,
                initialTitle: article.title,
                service: service,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// The bug report and feedback form: fill in, review exactly what will be
/// sent, then send once.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.kind,
    this.initialCategory,
    this.initialTitle = '',
    this.service,
    this.diagnostics,
  });

  final ReportKind kind;
  final String? initialCategory;
  final String initialTitle;
  final SupportService? service;

  /// Replaces the collected device details (tests).
  final Future<SupportDiagnostics> Function()? diagnostics;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.initialTitle);
  final _description = TextEditingController();
  final _steps = TextEditingController();
  late String _category =
      widget.initialCategory != null &&
          _categories.containsKey(widget.initialCategory)
      ? widget.initialCategory!
      : _categories.keys.first;
  String _platform = SupportDiagnostics.currentPlatform();
  bool _includeDetails = true;
  late final Future<SupportDiagnostics> _details =
      (widget.diagnostics ?? SupportDiagnostics.collect)();
  bool _sending = false;
  String? _error;
  bool _errorRetryable = true;
  String? _sentId;

  bool get _bug => widget.kind == ReportKind.bug;
  Map<String, String> get _categories =>
      _bug ? bugCategories : feedbackCategories;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _steps.dispose();
    super.dispose();
  }

  Future<SupportReport> _report() async => SupportReport(
    kind: widget.kind,
    category: _category,
    platform: _platform,
    title: _title.text,
    description: _description.text,
    steps: _steps.text,
    diagnostics: _includeDetails ? await _details : null,
  );

  Future<void> _review() async {
    if (_sending || !(_form.currentState?.validate() ?? false)) return;
    final report = await _report();
    if (!mounted) return;
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review your report'),
        content: SingleChildScrollView(
          child: SelectableText(
            report.toText(),
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Edit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (send == true) await _send(report);
  }

  Future<void> _send(SupportReport report) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final id = await (widget.service ?? SupportService()).submit(report);
      if (mounted) setState(() => _sentId = id);
    } on SupportSubmitException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _errorRetryable = error.retryable;
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _copy() async {
    final report = await _report();
    await Clipboard.setData(ClipboardData(text: report.toText()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report copied.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _bug ? 'Report a problem' : 'Send feedback';
    final sentId = _sentId;
    if (sentId != null) {
      return SettingsScaffold(
        title: title,
        icon: ReelishIcons.checkCircle,
        children: [
          SettingsSection(
            label: _bug ? 'REPORT SENT' : 'FEEDBACK SENT',
            children: [
              SettingsParagraph(
                title: 'Thank you',
                text:
                    'The developer will read it. There is no reply in the '
                    'app, so add details to the project page if you would '
                    'like to follow up. Reference: ${sentId.substring(0, 8)}',
              ),
            ],
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return SettingsScaffold(
      title: title,
      subtitle: _bug
          ? 'Describe what happened so it can be fixed.'
          : 'Ideas and questions are welcome.',
      icon: _bug ? ReelishIcons.bug : ReelishIcons.lightbulb,
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _title,
                maxLength: 120,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: _bug ? 'What went wrong?' : 'Subject',
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Add a short title.' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _category,
                icon: const Icon(ReelishIcons.chevronDown, size: 20),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final MapEntry(:key, :value) in _categories.entries)
                    DropdownMenuItem(value: key, child: Text(value)),
                ],
                onChanged: (value) =>
                    setState(() => _category = value ?? _category),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _platform,
                icon: const Icon(ReelishIcons.chevronDown, size: 20),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Device'),
                items: [
                  for (final MapEntry(:key, :value) in reportPlatforms.entries)
                    DropdownMenuItem(value: key, child: Text(value)),
                ],
                onChanged: (value) =>
                    setState(() => _platform = value ?? _platform),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _description,
                minLines: 4,
                maxLines: 10,
                maxLength: 4000,
                decoration: InputDecoration(
                  labelText: _bug ? 'Details' : 'Your message',
                  alignLabelWithHint: true,
                  hintText: _bug
                      ? 'What did you expect, and what happened instead?'
                      : null,
                ),
                validator: (value) => (value ?? '').trim().length < 10
                    ? 'Add a sentence or two.'
                    : null,
              ),
              if (_bug) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _steps,
                  minLines: 2,
                  maxLines: 8,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: 'Steps to reproduce (optional)',
                    alignLabelWithHint: true,
                    hintText: '1. Open…\n2. Choose…',
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        SettingsSection(
          label: 'DEVICE DETAILS',
          children: [
            SettingsSwitchTile(
              icon: ReelishIcons.chip,
              title: 'Include app and device details',
              description:
                  'Version, build, system, interface, language and time. '
                  'Never your account, history or providers.',
              value: _includeDetails,
              onChanged: (value) => setState(() => _includeDetails = value),
            ),
            if (_includeDetails)
              FutureBuilder<SupportDiagnostics>(
                future: _details,
                builder: (context, snapshot) {
                  final values = snapshot.data?.values ?? const {};
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text(
                      [
                        for (final MapEntry(:key, :value) in values.entries)
                          '${SupportDiagnostics.labels[key] ?? key}: $value',
                      ].join('\n'),
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
        if (_error case final error?)
          SettingsSection(
            label: 'NOT SENT',
            children: [
              SettingsParagraph(text: error),
              SettingsTile(
                icon: ReelishIcons.copy,
                title: 'Copy report',
                description: 'To paste it somewhere else',
                onTap: () => unawaited(_copy()),
              ),
              if (!_errorRetryable && SupportConfig.contactEmail.isNotEmpty)
                SettingsTile(
                  icon: ReelishIcons.mail,
                  title: 'Email support',
                  description: SupportConfig.contactEmail,
                  onTap: () => unawaited(_emailSupport(context)),
                ),
              if (!_errorRetryable)
                SettingsTile(
                  icon: ReelishIcons.chat,
                  title: 'Project page',
                  onTap: () =>
                      _openExternal(context, SupportConfig.publicIssues),
                ),
            ],
          ),
        const SizedBox(height: 8),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _sending ? null : () => unawaited(_review()),
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(ReelishIcons.send),
            label: Text(
              _sending
                  ? 'Sending…'
                  : _error != null && _errorRetryable
                  ? 'Review and try again'
                  : 'Review and send',
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows the folder of the local error log in the file manager.
Future<void> _openErrorLog(LocalErrorLog log) async {
  try {
    final folder = await log.folder();
    await folder.create(recursive: true);
    await launchUrl(Uri.directory(folder.path, windows: true));
  } catch (_) {
    // Nothing to show; the app is unaffected.
  }
}
