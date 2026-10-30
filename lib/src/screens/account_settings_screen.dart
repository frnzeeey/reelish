// The signed-in Trakt account in Settings: who is signed in, sign out here
// or everywhere, and delete the Reelish account.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';

class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key, required this.account, this.onBack});

  final AccountController account;
  final VoidCallback? onBack;

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: GlassTheme.danger,
                      foregroundColor: Colors.white,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _run(BuildContext context, Future<void> Function() task) async {
    try {
      await task();
    } on AccountApiException catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not finish'),
          content: Text(
            error.code == 'network'
                ? 'Reelish could not be reached. Check your connection and try again.'
                : 'Something went wrong. Try again later.',
          ),
          actions: [
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) => SettingsPage(
      title: 'Account',
      subtitle: 'Your Trakt sign-in on this device.',
      icon: Symbols.account_circle_rounded,
      onBack: onBack,
      children: [
        SettingsSection(
          label: 'TRAKT',
          children: [
            SettingsTile(
              icon: Symbols.person_rounded,
              title: 'Signed in as',
              value: account.username ?? '—',
              showChevron: false,
            ),
          ],
        ),
        SettingsSection(
          label: 'SESSIONS',
          description:
              'Signing out keeps My list, history and plugins on '
              'this device.',
          children: [
            SettingsTile(
              icon: Symbols.logout_rounded,
              title: 'Sign out',
              description: 'Sign out of Reelish on this device',
              onTap: () async {
                final ok = await _confirm(
                  context,
                  title: 'Sign out?',
                  message:
                      'You will need to sign in with Trakt again to '
                      'browse.',
                  action: 'Sign out',
                );
                if (ok && context.mounted) {
                  await _run(context, account.signOut);
                }
              },
            ),
            SettingsTile(
              icon: Symbols.devices_rounded,
              title: 'Sign out everywhere',
              description: 'Sign out of Reelish on all your devices',
              onTap: () async {
                final ok = await _confirm(
                  context,
                  title: 'Sign out everywhere?',
                  message:
                      'Every device signed in to Reelish with this '
                      'Trakt account will need to sign in again.',
                  action: 'Sign out everywhere',
                );
                if (ok && context.mounted) {
                  await _run(context, account.signOutEverywhere);
                }
              },
            ),
          ],
        ),
        SettingsSection(
          label: 'DELETE',
          children: [
            SettingsTile(
              icon: Symbols.delete_forever_rounded,
              title: 'Delete Reelish account',
              description:
                  'Removes your Reelish account and its access to '
                  'Trakt. Your Trakt account is not affected.',
              onTap: () async {
                final ok = await _confirm(
                  context,
                  title: 'Delete your Reelish account?',
                  message:
                      'Reelish forgets your account, signs out every '
                      'device and gives up its access to your Trakt account. '
                      'Your Trakt account and the data on this device are '
                      'not deleted.',
                  action: 'Delete account',
                  destructive: true,
                );
                if (ok && context.mounted) {
                  await _run(context, account.deleteAccount);
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}
