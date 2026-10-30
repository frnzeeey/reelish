// Trakt sign-in, shown before Home whenever no session is stored. Phone
// and Windows open Trakt in the browser (falling back to a code); TV shows
// a code to enter on another device, reachable with the D-pad.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_controller.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/brand_logo.dart';

/// Shows [child] while signed in and [SignInScreen] otherwise. Signing
/// out, from Settings or because the session ended, also closes every
/// page and dialog opened above, so the sign-in screen is what remains.
class AccountGate extends StatefulWidget {
  const AccountGate({super.key, required this.account, required this.child});

  final AccountController account;
  final Widget child;

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  // Read now, not lazily: read first inside [_changed], it would already
  // hold the new status and no change would be seen.
  late AccountStatus _status;

  @override
  void initState() {
    super.initState();
    _status = widget.account.status;
    widget.account.addListener(_changed);
  }

  @override
  void didUpdateWidget(AccountGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account) {
      oldWidget.account.removeListener(_changed);
      widget.account.addListener(_changed);
      _status = widget.account.status;
    }
  }

  void _changed() {
    final previous = _status;
    _status = widget.account.status;
    if (previous == AccountStatus.signedIn &&
        _status == AccountStatus.signedOut) {
      // Pages pushed over Home (Settings → Account, details, the player)
      // would otherwise stay on top of the sign-in screen.
      final navigator = Navigator.maybeOf(context);
      if (navigator != null && mounted) {
        navigator.popUntil((route) => route.isFirst);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.account.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.account.status) {
    AccountStatus.restoring => const ColoredBox(color: GlassTheme.background),
    AccountStatus.signedOut => SignInScreen(account: widget.account),
    AccountStatus.signedIn => widget.child,
  };
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.account});

  final AccountController account;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  DeviceSignIn? _signIn;

  void _begin([SignInMethod? method]) {
    _signIn?.dispose();
    setState(() => _signIn = widget.account.startSignIn(method: method));
  }

  void _reset() {
    _signIn?.dispose();
    setState(() => _signIn = null);
  }

  @override
  void dispose() {
    _signIn?.dispose();
    super.dispose();
  }

  List<Widget> _intro({required bool tv}) => [
    _Brand(tv: tv),
    const SizedBox(height: AppSpace.lg),
    Text(
      'Sign in to Reelish',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: tv ? AppTextSize.display : 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -.3,
      ),
    ),
    const SizedBox(height: AppSpace.xs),
    Text(
      'Use your Trakt account. My list, history and plugins on this device '
      'stay as they are.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: GlassTheme.muted,
        fontSize: tv ? AppTextSize.bodyLarge : AppTextSize.body,
        fontWeight: FontWeight.w500,
        height: 1.45,
      ),
    ),
    if (widget.account.endedReason case final reason?) ...[
      const SizedBox(height: AppSpace.md),
      _Notice(text: reason),
    ],
  ];

  Widget _action(bool tv, Duration duration) => AnimatedSwitcher(
    duration: duration,
    reverseDuration: AppMotion.exitOf(duration),
    switchInCurve: AppMotion.enter,
    switchOutCurve: AppMotion.exit,
    child: _signIn == null
        ? _Welcome(key: const ValueKey('welcome'), tv: tv, onStart: _begin)
        : ListenableBuilder(
            key: ValueKey(_signIn),
            listenable: _signIn!,
            builder: (context, _) => _SignInProgress(
              signIn: _signIn!,
              tv: tv,
              onRestart: () => _begin(_signIn?.method),
              onUseCode: () => _begin(SignInMethod.code),
              onBack: _reset,
            ),
          ),
  );

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.usesTvLayout && !DeviceCapabilities.isDesktop;
    final duration = AppMotion.resolve(context, AppMotion.page);
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: Stack(
        children: [
          const Positioned.fill(child: _AmbientGlow()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: tv ? AppSpace.xxl : AppSpace.lg,
                  vertical: AppSpace.xl,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: tv ? 1040 : 440),
                  child: tv
                      // Landscape, viewed from afar: who and why on the left,
                      // the code on the right, all on one screen (the code
                      // panel has nothing to focus, so it must not scroll).
                      ? Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ..._intro(tv: true),
                                  const SizedBox(height: AppSpace.lg),
                                  const _PrivacyNote(tv: true),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpace.xxl),
                            SizedBox(
                              width: 480,
                              child: _action(true, duration),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ..._intro(tv: false),
                            const SizedBox(height: AppSpace.lg),
                            _action(false, duration),
                            const SizedBox(height: AppSpace.lg),
                            const _PrivacyNote(),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft accent light behind the brand, drawn once (no blur filter).
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -.85),
          radius: 1.1,
          colors: [
            GlassTheme.primary.withValues(alpha: .22),
            GlassTheme.primary.withValues(alpha: .06),
            GlassTheme.background.withValues(alpha: 0),
          ],
          stops: const [0, .45, 1],
        ),
      ),
    ),
  );
}

class _Brand extends StatelessWidget {
  const _Brand({required this.tv});

  final bool tv;

  @override
  Widget build(BuildContext context) {
    final icon = tv ? 76.0 : 64.0;
    return Column(
      children: [
        Container(
          width: icon,
          height: icon,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(icon * .28),
            boxShadow: [
              BoxShadow(
                color: GlassTheme.primary.withValues(alpha: .35),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: ExcludeSemantics(
            child: Image.asset(
              BrandAssets.appIcon,
              width: icon,
              height: icon,
              cacheWidth: (icon * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        ReelishWordmark(height: tv ? 22 : 18, lifted: true),
      ],
    );
  }
}

/// The first step: one clear action, with the alternative beside it.
class _Welcome extends StatelessWidget {
  const _Welcome({super.key, required this.tv, required this.onStart});

  final bool tv;
  final void Function([SignInMethod? method]) onStart;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PrimaryButton(
        autofocus: true,
        icon: Symbols.login_rounded,
        label: tv ? 'Sign in with Trakt' : 'Continue with Trakt',
        onPressed: () => onStart(),
      ),
      if (!tv) ...[
        const SizedBox(height: AppSpace.xs),
        TextButton(
          onPressed: () => onStart(SignInMethod.code),
          child: const Text('Sign in with a code instead'),
        ),
      ],
    ],
  );
}

class _SignInProgress extends StatelessWidget {
  const _SignInProgress({
    required this.signIn,
    required this.tv,
    required this.onRestart,
    required this.onUseCode,
    required this.onBack,
  });

  final DeviceSignIn signIn;
  final bool tv;
  final VoidCallback onRestart;
  final VoidCallback onUseCode;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => switch (signIn.phase) {
    DeviceSignInPhase.starting => const _Panel(
      child: _Status(text: 'Connecting to Trakt…', busy: true),
    ),
    DeviceSignInPhase.done => const _Panel(
      child: _Status(text: 'Signed in. Loading Reelish…', busy: true),
    ),
    DeviceSignInPhase.waiting when signIn.method == SignInMethod.browser =>
      _BrowserPanel(signIn: signIn, onUseCode: onUseCode, onBack: onBack),
    DeviceSignInPhase.waiting => _CodePanel(
      signIn: signIn,
      tv: tv,
      onBack: tv ? null : onBack,
    ),
    DeviceSignInPhase.expired => _Retry(
      text: signIn.method == SignInMethod.browser
          ? 'That sign-in timed out.'
          : 'That code expired.',
      action: signIn.method == SignInMethod.browser
          ? 'Try again'
          : 'Get a new code',
      onPressed: onRestart,
      onBack: onBack,
    ),
    DeviceSignInPhase.denied => _Retry(
      text: 'Sign-in was declined on Trakt.',
      action: 'Try again',
      onPressed: onRestart,
      onBack: onBack,
    ),
    DeviceSignInPhase.failed => _Retry(
      text: signIn.error ?? 'Sign-in is not available right now.',
      action: 'Try again',
      onPressed: onRestart,
      onBack: onBack,
    ),
  };
}

/// Browser sign-in in progress: Trakt is open in the browser.
class _BrowserPanel extends StatelessWidget {
  const _BrowserPanel({
    required this.signIn,
    required this.onUseCode,
    required this.onBack,
  });

  final DeviceSignIn signIn;
  final VoidCallback onUseCode;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Symbols.open_in_browser_rounded,
          size: AppIcon.xl,
          color: GlassTheme.coralBright,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          signIn.browserFailed
              ? 'Your browser didn’t open'
              : 'Continue in your browser',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: AppTextSize.title,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpace.xxs),
        Text(
          signIn.browserFailed
              ? 'Open Trakt again, or sign in with a code instead.'
              : 'Sign in to Trakt and approve Reelish, then come back here. '
                    'This page updates by itself.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GlassTheme.muted,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        _PrimaryButton(
          autofocus: true,
          icon: Symbols.open_in_new_rounded,
          label: 'Open Trakt again',
          onPressed: signIn.openBrowser,
        ),
        const SizedBox(height: AppSpace.xs),
        OutlinedButton.icon(
          onPressed: onUseCode,
          icon: const Icon(Symbols.pin_rounded),
          label: const Text('Use a code instead'),
        ),
        const SizedBox(height: AppSpace.md),
        const _Status(text: 'Waiting for Trakt…', busy: true),
        const SizedBox(height: AppSpace.xxs),
        TextButton(onPressed: onBack, child: const Text('Cancel')),
      ],
    ),
  );
}

/// Code sign-in in progress: steps, the code, and on phone and Windows a
/// button that copies the code and opens Trakt.
class _CodePanel extends StatelessWidget {
  const _CodePanel({required this.signIn, required this.tv, this.onBack});

  final DeviceSignIn signIn;
  final bool tv;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final code = signIn.code!;
    final url = code.verificationUrl;
    final shownUrl = '${url.host}${url.path}';
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Step(
            number: 1,
            tv: tv,
            child: Text.rich(
              TextSpan(
                text: tv ? 'On your phone or computer, go to ' : 'Go to ',
                children: [
                  TextSpan(
                    text: shownUrl,
                    style: TextStyle(
                      color: GlassTheme.coralBright,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          _Step(number: 2, tv: tv, child: const Text('Enter this code')),
          const SizedBox(height: AppSpace.md),
          _CodeDisplay(code: code.userCode, tv: tv),
          const SizedBox(height: AppSpace.md),
          _Step(
            number: 3,
            tv: tv,
            child: const Text(
              'Approve Reelish. This screen continues by itself.',
            ),
          ),
          if (!tv) ...[
            const SizedBox(height: AppSpace.lg),
            // Copies the code first: the browser covers this screen, so the
            // code can then simply be pasted on Trakt.
            _PrimaryButton(
              autofocus: true,
              icon: Symbols.open_in_new_rounded,
              label: 'Copy code and open Trakt',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code.userCode));
                await launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
            const SizedBox(height: AppSpace.xs),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code.userCode));
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Code copied')));
                }
              },
              icon: const Icon(Symbols.content_copy_rounded),
              label: const Text('Copy code'),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          const _Status(
            text: 'Waiting for you to approve on Trakt…',
            busy: true,
          ),
          if (onBack != null) ...[
            const SizedBox(height: AppSpace.xxs),
            TextButton(onPressed: onBack, child: const Text('Cancel')),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.tv, required this.child});

  final int number;
  final bool tv;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final badge = tv ? 30.0 : 24.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: badge,
          height: badge,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: GlassTheme.primary.withValues(alpha: .16),
            border: Border.all(
              color: GlassTheme.primary.withValues(alpha: .45),
            ),
          ),
          child: Text(
            '$number',
            style: TextStyle(
              color: GlassTheme.coralBright,
              fontSize: tv ? AppTextSize.body : AppTextSize.label,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: tv ? 4 : 2),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                fontSize: tv ? AppTextSize.bodyLarge : AppTextSize.body,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// The code, large and spaced, read out character by character.
class _CodeDisplay extends StatelessWidget {
  const _CodeDisplay({required this.code, required this.tv});

  final String code;
  final bool tv;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Code ${code.split('').join(' ')}',
    child: ExcludeSemantics(
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: tv ? AppSpace.lg : AppSpace.md,
          horizontal: AppSpace.md,
        ),
        decoration: BoxDecoration(
          color: GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: GlassTheme.primary.withValues(alpha: .35)),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SelectableText(
            code,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: tv ? 52 : 36,
              fontWeight: FontWeight.w800,
              letterSpacing: tv ? 10 : 6,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: GlassTheme.surface.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(AppRadius.xxl),
      border: Border.all(color: GlassTheme.border),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 32,
          offset: Offset(0, 16),
        ),
      ],
    ),
    child: child,
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    autofocus: autofocus,
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      textStyle: const TextStyle(
        fontFamily: GlassTheme.fontFamily,
        fontSize: AppTextSize.bodyLarge,
        fontWeight: FontWeight.w700,
      ),
    ),
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({this.tv = false});

  final bool tv;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: AppSpace.xxs),
            child: Icon(
              Symbols.lock_rounded,
              size: tv ? AppIcon.md : AppIcon.sm,
              color: GlassTheme.muted,
            ),
          ),
        ),
        const TextSpan(
          text: 'You sign in on Trakt. Reelish never sees your password.',
        ),
      ],
    ),
    textAlign: TextAlign.center,
    style: TextStyle(
      color: GlassTheme.muted,
      // 14 pt is the smallest text on TV.
      fontSize: tv ? AppTextSize.body : AppTextSize.caption,
      fontWeight: FontWeight.w500,
    ),
  );
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
    required this.onBack,
  });

  final String text;
  final String action;
  final VoidCallback onPressed;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Notice(text: text),
        const SizedBox(height: AppSpace.md),
        _PrimaryButton(
          autofocus: true,
          icon: Symbols.refresh_rounded,
          label: action,
          onPressed: onPressed,
        ),
        const SizedBox(height: AppSpace.xxs),
        TextButton(onPressed: onBack, child: const Text('Back')),
      ],
    ),
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
      child: Row(
        children: [
          const Icon(
            Symbols.info_rounded,
            size: AppIcon.md,
            color: GlassTheme.warning,
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}
