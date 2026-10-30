// Trakt sign-in, shown before Home whenever no session is stored: a code
// to enter at trakt.tv, on every platform (D-pad friendly on TV).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_controller.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/brand_logo.dart';

/// Shows [child] while signed in and [SignInScreen] otherwise.
class AccountGate extends StatelessWidget {
  const AccountGate({super.key, required this.account, required this.child});

  final AccountController account;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) => switch (account.status) {
      AccountStatus.restoring => const ColoredBox(color: GlassTheme.background),
      AccountStatus.signedOut => SignInScreen(account: account),
      AccountStatus.signedIn => child,
    },
  );
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.account});

  final AccountController account;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  DeviceSignIn? _signIn;

  void _begin() {
    _signIn?.dispose();
    setState(() => _signIn = widget.account.startSignIn());
  }

  @override
  void dispose() {
    _signIn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.usesTvLayout;
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: tv ? 640 : 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: ReelishWordmark(height: tv ? 26 : 20)),
                  const SizedBox(height: AppSpace.lg),
                  Text(
                    'Sign in with Trakt',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: tv ? 30 : 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    'Reelish uses your Trakt account. My list, history and '
                    'plugins on this device stay as they are.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: GlassTheme.muted,
                      fontSize: tv ? AppTextSize.body + 2 : AppTextSize.body,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                  if (widget.account.endedReason case final reason?) ...[
                    const SizedBox(height: AppSpace.md),
                    _Notice(text: reason),
                  ],
                  const SizedBox(height: AppSpace.lg),
                  if (_signIn case final signIn?)
                    ListenableBuilder(
                      listenable: signIn,
                      builder: (context, _) =>
                          _SignInProgress(signIn: signIn, onRestart: _begin),
                    )
                  else
                    FilledButton.icon(
                      autofocus: true,
                      onPressed: _begin,
                      icon: const Icon(Symbols.login_rounded),
                      label: const Text('Sign in with Trakt'),
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

class _SignInProgress extends StatelessWidget {
  const _SignInProgress({required this.signIn, required this.onRestart});

  final DeviceSignIn signIn;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) => switch (signIn.phase) {
    DeviceSignInPhase.starting || DeviceSignInPhase.done => const _Status(
      text: 'Connecting to Trakt…',
      busy: true,
    ),
    DeviceSignInPhase.waiting => _CodePanel(signIn: signIn),
    DeviceSignInPhase.expired => _Retry(
      text: 'That code expired.',
      action: 'Get a new code',
      onPressed: onRestart,
    ),
    DeviceSignInPhase.denied => _Retry(
      text: 'Sign-in was declined on Trakt.',
      action: 'Try again',
      onPressed: onRestart,
    ),
    DeviceSignInPhase.failed => _Retry(
      text: signIn.error ?? 'Sign-in is not available right now.',
      action: 'Try again',
      onPressed: onRestart,
    ),
  };
}

class _CodePanel extends StatelessWidget {
  const _CodePanel({required this.signIn});

  final DeviceSignIn signIn;

  @override
  Widget build(BuildContext context) {
    final code = signIn.code!;
    final tv = DeviceCapabilities.usesTvLayout && !DeviceCapabilities.isDesktop;
    final url = code.verificationUrl;
    final shownUrl = '${url.host}${url.path}';
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: GlassTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tv ? 'On your phone or computer, go to' : 'Go to',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: AppSpace.xxs),
          SelectableText(
            shownUrl,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.coralBright,
              fontSize: tv ? 26 : 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          const Text(
            'and enter this code',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GlassTheme.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Semantics(
            label: 'Code ${code.userCode.split('').join(' ')}',
            child: ExcludeSemantics(
              child: SelectableText(
                code.userCode,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: tv ? 48 : 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (!tv)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                // Copies the code first: the browser covers this screen,
                // so the code can then simply be pasted on Trakt.
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code.userCode));
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Symbols.open_in_new_rounded),
                  label: const Text('Copy code and open Trakt'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code.userCode));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    }
                  },
                  icon: const Icon(Symbols.content_copy_rounded),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          if (!tv) ...[
            const SizedBox(height: AppSpace.xs),
            const Text(
              'Paste the code on Trakt, approve, then come back here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.caption,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          const _Status(
            text: 'Waiting for you to approve on Trakt…',
            busy: true,
          ),
        ],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.text, this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        const SizedBox(width: AppSpace.xs),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Notice(text: text),
      const SizedBox(height: AppSpace.md),
      FilledButton(autofocus: true, onPressed: onPressed, child: Text(action)),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: GlassTheme.warning.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: GlassTheme.warning.withValues(alpha: .35)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
}
