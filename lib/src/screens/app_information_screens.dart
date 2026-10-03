import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/glass_theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: GlassTheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: GlassTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: GlassTheme.primary.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Icon(
                  Icons.movie_creation_outlined,
                  color: GlassTheme.primary,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Reelish',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.7,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                'A streaming catalog app with add-on support and an in-app video player.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: GlassTheme.muted,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) => _InfoCard(
            title: 'App version',
            detail: snapshot.hasData
                ? '${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                : 'Loading…',
          ),
        ),
      ],
    ),
  );
}

class SupportDevelopmentScreen extends StatelessWidget {
  const SupportDevelopmentScreen({super.key});

  static final _coffeeUri = Uri.https('www.buymeacoffee.com', '/frnzegl');

  Future<void> _openCoffeePage(BuildContext context) async {
    if (!await launchUrl(
      _coffeeUri,
      mode: LaunchMode.externalApplication,
    ) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the support page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Support development')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      children: [
        const _InfoCard(
          title: 'A little support goes a long way',
          detail:
              "If you enjoy Reelish, you can help with ongoing development and server costs. Support is completely optional and does not unlock features or content.",
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: () => _openCoffeePage(context),
            icon: const Icon(Icons.coffee_rounded),
            label: const Text('Buy me a coffee'),
            style: FilledButton.styleFrom(
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.15,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          detail,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: GlassTheme.muted,
            height: 1.55,
          ),
        ),
      ],
    ),
  );
}
