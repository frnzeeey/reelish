// Shared Plugin Manager pieces for phone, TV and Windows: source trust,
// device compatibility, what any provider can do in Reelish, the guarded
// "switch on" action and the page frame the manager's pages use.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/provider_plugin.dart';
import '../../platform/device_capabilities.dart';
import '../../services/plugin_compatibility.dart';
import '../../services/plugin_trust.dart';
import '../../services/provider_plugin_service.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';

/// A compact source-trust chip. Verified uses the info colour; the others
/// stay neutral or warn, so "listed" never reads as an endorsement.
class PluginTrustBadge extends StatelessWidget {
  const PluginTrustBadge({super.key, required this.trust});

  final PluginSourceTrust trust;

  static (IconData, Color) styleOf(PluginSourceTrust trust) => switch (trust) {
    PluginSourceTrust.verified => (ReelishIcons.verified, GlassTheme.info),
    PluginSourceTrust.listed => (ReelishIcons.store, GlassTheme.muted),
    PluginSourceTrust.unlisted => (ReelishIcons.link, GlassTheme.warning),
    PluginSourceTrust.unknown => (ReelishIcons.help, GlassTheme.muted),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = styleOf(trust);
    return PluginStatusChip(icon: icon, label: trust.label, color: color);
  }
}

/// Small icon + label chip; text stays [GlassTheme.textPrimary] so it is
/// readable in every theme, the colour marks only the icon and outline.
class PluginStatusChip extends StatelessWidget {
  const PluginStatusChip({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(7, 4, 9, 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      border: Border.all(color: color.withValues(alpha: .3)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.micro,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class PluginCompatibilityChip extends StatelessWidget {
  const PluginCompatibilityChip({super.key, required this.level});

  final PluginCompatibilityLevel level;

  static (IconData, Color) styleOf(
    PluginCompatibilityLevel level,
  ) => switch (level) {
    PluginCompatibilityLevel.compatible => (
      ReelishIcons.checkCircle,
      GlassTheme.success,
    ),
    PluginCompatibilityLevel.partial => (ReelishIcons.info, GlassTheme.info),
    PluginCompatibilityLevel.unsupported => (
      ReelishIcons.blocked,
      GlassTheme.warning,
    ),
    PluginCompatibilityLevel.unknown => (ReelishIcons.help, GlassTheme.muted),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = styleOf(level);
    return PluginStatusChip(icon: icon, label: level.label, color: color);
  }
}

/// A titled card with an icon, used for trust, compatibility and status.
class PluginInfoCard extends StatelessWidget {
  const PluginInfoCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.children,
    this.actions = const [],
  });

  final IconData icon;
  final Color color;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: color.withValues(alpha: .22)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 19, color: color),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: AppTextSize.label,
                ),
              ),
              const SizedBox(height: 4),
              ...children,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// Body text for [PluginInfoCard].
class PluginInfoText extends StatelessWidget {
  const PluginInfoText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        color: GlassTheme.textPrimary.withValues(alpha: .75),
        fontSize: AppTextSize.caption,
        height: 1.4,
      ),
    ),
  );
}

/// Where a repository comes from, and what its trust level does and does
/// not mean.
class PluginSourceCard extends StatelessWidget {
  const PluginSourceCard({
    super.key,
    required this.trust,
    required this.manifestUrl,
  });

  final PluginSourceTrust trust;
  final String manifestUrl;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = PluginTrustBadge.styleOf(trust);
    final host = PluginHost.of(manifestUrl);
    return PluginInfoCard(
      icon: icon,
      color: color,
      title: trust.label,
      children: [
        PluginInfoText(trust.explanation),
        if (manifestUrl.isNotEmpty)
          PluginInfoText(
            host.account == null
                ? 'Hosted on ${host.service}.'
                : 'Hosted on ${host.service} by the account "${host.account}". '
                      'That is the account name the host shows, not a '
                      'confirmed identity.',
          ),
      ],
    );
  }
}

/// What every provider can and cannot do in Reelish. These limits come
/// from the provider runtime and network policy and apply to every
/// provider equally: providers do not declare permissions, so none are
/// listed per provider.
class ProviderCapabilitiesCard extends StatelessWidget {
  const ProviderCapabilitiesCard({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  static const can = [
    'Receive the title you are about to watch: its TMDB number, whether it '
        'is a movie or a series, and the season and episode.',
    'Contact websites on the public internet over HTTPS. A provider can send '
        'what it receives to any site it contacts.',
    'Return stream links and the request headers the player sends with them. '
        'Reelish checks each link before playing it.',
  ];

  static const cannot = [
    'Reach your home network or this device: requests to private and local '
        'addresses are refused.',
    'Read your Reelish or Trakt account, sign-in tokens, watch history, '
        'files or other providers’ cookies. Reelish gives providers none '
        'of these.',
    'Keep running: a provider that takes longer than 45 seconds is stopped, '
        'and only a few run at once.',
    'Change its code silently after you install it: new or changed code '
        'waits until you allow it.',
  ];

  @override
  Widget build(BuildContext context) => PluginExpandableSurface(
    child: Theme(
      // No divider lines from ExpansionTile.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(ReelishIcons.shield, color: GlassTheme.primary),
        title: const Text(
          'What providers can do',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: AppTextSize.bodySmall,
          ),
        ),
        subtitle: Text(
          'The same limits apply to every provider',
          style: TextStyle(
            color: GlassTheme.muted,
            fontSize: AppTextSize.micro,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CapabilityHeading('Providers can'),
          for (final line in can) _CapabilityLine(text: line, allowed: true),
          const SizedBox(height: 8),
          const _CapabilityHeading('Providers cannot'),
          for (final line in cannot)
            _CapabilityLine(text: line, allowed: false),
          const SizedBox(height: 8),
          Text(
            'Providers run inside Reelish’s script engine, separate from '
            'your data, but that is not an operating-system sandbox. Install '
            'only what you trust.',
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.micro,
              height: 1.4,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The card an [ExpansionTile] sits on: a [Material], so the tile's ink and
/// focus highlight paint on it instead of under a decorated box.
class PluginExpandableSurface extends StatelessWidget {
  const PluginExpandableSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      side: BorderSide(color: GlassTheme.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _CapabilityHeading extends StatelessWidget {
  const _CapabilityHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: GlassTheme.muted,
        fontSize: AppTextSize.micro,
        fontWeight: FontWeight.w800,
        letterSpacing: .6,
      ),
    ),
  );
}

class _CapabilityLine extends StatelessWidget {
  const _CapabilityLine({required this.text, required this.allowed});

  final String text;
  final bool allowed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            allowed ? ReelishIcons.check : ReelishIcons.blocked,
            size: 15,
            color: allowed ? GlassTheme.textPrimary : GlassTheme.muted,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: GlassTheme.textPrimary.withValues(alpha: .8),
              fontSize: AppTextSize.caption,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Switches a provider on or off. Switching on one that is not meant for
/// this device asks first, so it is never enabled by accident; one Reelish
/// never searches cannot be switched on at all.
Future<void> setProviderEnabled(
  BuildContext context, {
  required ProviderPluginService service,
  required ProviderRepository repository,
  required ProviderPlugin plugin,
  required bool enabled,
  ReelishDevice? device,
}) async {
  if (enabled) {
    final compatibility = PluginCompatibility.of(
      plugin,
      device ?? ReelishDevice.current,
    );
    if (!compatibility.searchable) return;
    if (compatibility.blockedOnDevice) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GlassTheme.elevatedSurface,
          title: Text('Switch on ${plugin.name}?'),
          content: Text(
            '${compatibility.reasons.first}\n\nIt may fail or slow down '
            'searches here.',
            style: TextStyle(color: GlassTheme.muted, height: 1.4),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Switch on anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
  }
  await service.setPluginEnabled(repository, plugin, enabled);
}

/// The frame of a Plugin Manager page: a back row, a readable column and,
/// on Windows, Esc to go back (as on the other detail pages).
class PluginManagerPage extends StatelessWidget {
  const PluginManagerPage({
    super.key,
    required this.backLabel,
    required this.slivers,
  });

  final String backLabel;
  final List<Widget> slivers;

  static const maxContentWidth = 760.0;

  static Widget constrained(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxContentWidth),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      backgroundColor: GlassTheme.background,
      body: CustomScrollView(
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverToBoxAdapter(
              child: constrained(
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 20, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: DeviceCapabilities.isDesktop
                            ? 'Back (Esc)'
                            : 'Back to $backLabel',
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(ReelishIcons.back),
                      ),
                      Expanded(
                        child: Text(
                          backLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GlassTheme.muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ...slivers,
          const SliverToBoxAdapter(
            child: SafeArea(top: false, child: SizedBox(height: 32)),
          ),
        ],
      ),
    );
    if (!DeviceCapabilities.isDesktop) return page;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(autofocus: true, child: page),
    );
  }
}

/// A section heading on a Plugin Manager page.
class PluginSectionHeading extends StatelessWidget {
  const PluginSectionHeading(this.title, {super.key, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 10),
    child: Semantics(
      header: true,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: AppTextSize.title,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Label/value rows in a card. Values are selectable so addresses can be
/// copied on every platform.
class PluginFactsTable extends StatelessWidget {
  const PluginFactsTable({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Column(
      children: [
        for (final (index, (label, value)) in rows.indexed) ...[
          if (index > 0) Divider(height: 1, color: GlassTheme.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: GlassTheme.muted,
                      fontSize: AppTextSize.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                      fontSize: AppTextSize.label,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// "Movies, Series" from declared content types.
String describeContentTypes(List<String> types) {
  final labels = <String>{
    for (final type in types)
      switch (PluginCompatibility.normalizeType(type)) {
        'movie' => 'Movies',
        'tv' => 'Series',
        final other =>
          other.isEmpty
              ? other
              : '${other[0].toUpperCase()}${other.substring(1)}',
      },
  }..remove('');
  return labels.isEmpty ? 'None declared' : labels.join(', ');
}
