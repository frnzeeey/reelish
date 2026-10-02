import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/glass_theme.dart';
import 'legal_information_screen.dart';

class FirstRunConsentScreen extends StatefulWidget {
  const FirstRunConsentScreen({super.key, required this.onAccepted});

  final VoidCallback onAccepted;

  static const _acceptedKey = 'reelish.legal.documentsAccepted.v1';

  static Future<bool> hasAccepted() async =>
      (await SharedPreferences.getInstance()).getBool(_acceptedKey) ?? false;

  @override
  State<FirstRunConsentScreen> createState() => _FirstRunConsentScreenState();
}

class _FirstRunConsentScreenState extends State<FirstRunConsentScreen> {
  bool _privacyRead = false;
  bool _termsRead = false;
  bool _privacyAgreed = false;
  bool _termsAgreed = false;
  bool _saving = false;

  bool get _canContinue =>
      _privacyRead && _termsRead && _privacyAgreed && _termsAgreed && !_saving;

  Future<void> _readDocument(LegalDocument document) async {
    final readToEnd = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LegalInformationScreen(
          document: document,
          requireReadToEnd: true,
        ),
      ),
    );
    if (!mounted || readToEnd != true) return;
    setState(() {
      if (document == LegalDocument.privacy) {
        _privacyRead = true;
      } else {
        _termsRead = true;
      }
    });
  }

  Future<void> _accept() async {
    if (!_canContinue) return;
    setState(() => _saving = true);
    try {
      final saved = await SharedPreferences.getInstance();
      final stored = await saved.setBool(
        FirstRunConsentScreen._acceptedKey,
        true,
      );
      if (!stored) throw StateError('Consent choice was not saved.');
      if (mounted) widget.onAccepted();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save your choice. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * .9;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: .72),
      body: SafeArea(
        child: Center(
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 18,
            ),
            backgroundColor: GlassTheme.surface,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: GlassTheme.coralGlow,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.policy_outlined,
                            color: GlassTheme.coralBright,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Before you start',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 9),
                        const Text(
                          'Please read Reelish’s privacy policy and terms of use. '
                          'They explain what information stays on your device, '
                          'what may be shared with services and add-ons you use, '
                          'and the responsibilities and risks of playing '
                          'third-party content. You need to review both and '
                          'agree before using the app.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Column(
                        children: [
                          _DocumentConsentTile(
                            title: 'Privacy policy',
                            read: _privacyRead,
                            agreed: _privacyAgreed,
                            onRead: () => _readDocument(LegalDocument.privacy),
                            onChanged: _privacyRead
                                ? (value) => setState(
                                    () => _privacyAgreed = value ?? false,
                                  )
                                : null,
                          ),
                          const SizedBox(height: 8),
                          _DocumentConsentTile(
                            title: 'Terms of use',
                            read: _termsRead,
                            agreed: _termsAgreed,
                            onRead: () => _readDocument(LegalDocument.terms),
                            onChanged: _termsRead
                                ? (value) => setState(
                                    () => _termsAgreed = value ?? false,
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 22),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _canContinue ? _accept : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          child: Text(
                            _saving ? 'Saving…' : 'Agree and continue',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DocumentConsentTile extends StatelessWidget {
  const _DocumentConsentTile({
    required this.title,
    required this.read,
    required this.agreed,
    required this.onRead,
    required this.onChanged,
  });

  final String title;
  final bool read;
  final bool agreed;
  final VoidCallback onRead;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: GlassTheme.elevatedSurface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Column(
      children: [
        ListTile(
          leading: Icon(
            read ? Icons.check_circle_rounded : Icons.description_outlined,
            color: read ? GlassTheme.coralBright : GlassTheme.muted,
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(read ? 'Read to the end' : 'Read the full document'),
          trailing: TextButton(
            onPressed: onRead,
            child: Text(read ? 'Read again' : 'Read'),
          ),
        ),
        CheckboxListTile(
          value: agreed,
          onChanged: onChanged,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(
            'I have read and agree to the ${title.toLowerCase()}.',
            style: const TextStyle(fontSize: 12, height: 1.35),
          ),
        ),
      ],
    ),
  );
}
