// The genre step: "What do you love watching?". Shown once, full screen,
// after a brand-new account's first sign-in, and from the Home card for
// existing accounts. One page for phone, TV and Windows: tiles are ordinary
// focusable buttons, so touch, the D-pad and the keyboard all work.

import 'package:flutter/material.dart';

import '../discovery/discovery_controller.dart';
import '../discovery/tmdb_genres.dart';
import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';

class GenreOnboardingScreen extends StatefulWidget {
  const GenreOnboardingScreen({
    super.key,
    required this.discovery,
    this.loadGenres,
  });

  final DiscoveryController discovery;

  /// TMDB's genre lists (`TmdbService.genreCatalog`). The built-in copy
  /// shows at once and is replaced when these arrive.
  final Future<GenreCatalog> Function()? loadGenres;

  /// Below this many, Continue still works; the count only says more help.
  static const suggestedCount = 3;

  /// Opens the step over everything. Completes with whether it was answered
  /// (genres saved, or skipped); going back leaves it unanswered.
  static Future<bool> show(
    BuildContext context, {
    required DiscoveryController discovery,
    Future<GenreCatalog> Function()? loadGenres,
  }) async =>
      await Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          settings: const RouteSettings(name: 'genre-onboarding'),
          builder: (_) => GenreOnboardingScreen(
            discovery: discovery,
            loadGenres: loadGenres,
          ),
        ),
      ) ??
      false;

  @override
  State<GenreOnboardingScreen> createState() => _GenreOnboardingScreenState();
}

class _GenreOnboardingScreenState extends State<GenreOnboardingScreen> {
  GenreCatalog _catalog = GenreCatalog.fallback;
  late final Set<int> _picked = {...widget.discovery.favoriteGenres};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final load = widget.loadGenres;
    if (load != null) {
      load().then((catalog) {
        if (mounted) setState(() => _catalog = catalog);
      }, onError: (Object _) {});
    }
  }

  Future<void> _finish({required bool skip}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (skip) {
        await widget.discovery.skipOnboarding();
      } else {
        await widget.discovery.completeOnboarding(_catalog.valid(_picked));
      }
    } finally {
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final genres = _catalog.pickable;
    final large = DeviceCapabilities.usesTvLayout;
    final count = _picked.where(genres.contains).length;
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      large ? AppSpace.xl : AppSpace.md + 4,
                      large ? AppSpace.xxl : AppSpace.xl,
                      large ? AppSpace.xl : AppSpace.md + 4,
                      AppSpace.lg,
                    ),
                    children: [
                      Icon(
                        ReelishIcons.sparkle,
                        color: GlassTheme.primary,
                        size: AppIcon.lg,
                      ),
                      const SizedBox(height: AppSpace.md),
                      Semantics(
                        header: true,
                        child: Text(
                          'What do you love watching?',
                          style: AppType.display.copyWith(
                            color: GlassTheme.textPrimary,
                            fontSize: large ? 36 : 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Text(
                        'Choose the genres you enjoy. We’ll use your '
                        'preferences to make discovering your next favorite '
                        'movie or series easier.',
                        style: AppType.body.copyWith(
                          color: GlassTheme.muted,
                          fontSize: large ? 17 : 15,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: AppSpace.lg + 4),
                      Wrap(
                        spacing: AppSpace.sm - 2,
                        runSpacing: AppSpace.sm - 2,
                        children: [
                          for (final (index, id) in genres.indexed)
                            _GenreTile(
                              label: _catalog.nameOf(id) ?? '',
                              selected: _picked.contains(id),
                              large: large,
                              // On a remote, focus starts on the first genre.
                              autofocus: large && index == 0,
                              onTap: _saving
                                  ? null
                                  : () => setState(() {
                                      if (!_picked.remove(id)) _picked.add(id);
                                    }),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _Footer(
                  count: count,
                  saving: _saving,
                  large: large,
                  onSkip: () => _finish(skip: true),
                  onContinue: count == 0 ? null : () => _finish(skip: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.count,
    required this.saving,
    required this.large,
    required this.onSkip,
    required this.onContinue,
  });

  final int count;
  final bool saving, large;
  final VoidCallback onSkip;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final hint = count == 0
        ? 'Pick a few to get started'
        : count < GenreOnboardingScreen.suggestedCount
        ? '$count selected · a few more helps'
        : '$count selected';
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: GlassTheme.border)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: large ? AppSpace.xl : AppSpace.md + 4,
          vertical: AppSpace.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  hint,
                  style: AppType.bodySmall.copyWith(color: GlassTheme.muted),
                ),
              ),
            ),
            TextButton(
              onPressed: saving ? null : onSkip,
              child: const Text('Skip for now'),
            ),
            const SizedBox(width: AppSpace.xs),
            FilledButton(
              onPressed: saving ? null : onContinue,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One genre: a pill that fills with the accent when chosen. Focus (remote
/// or keyboard) draws an accent outline, so it is seen apart from choice.
class _GenreTile extends StatefulWidget {
  const _GenreTile({
    required this.label,
    required this.selected,
    required this.large,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final bool selected, large, autofocus;
  final VoidCallback? onTap;

  @override
  State<_GenreTile> createState() => _GenreTileState();
}

class _GenreTileState extends State<_GenreTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final primary = GlassTheme.primary;
    final radius = BorderRadius.circular(AppRadius.pill);
    final duration = AppMotion.resolve(context, AppMotion.hover);
    // One node: the label, the chosen state and the tap action together.
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.move,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected
                ? primary.withValues(alpha: .2)
                : GlassTheme.surface,
            border: Border.all(
              color: _focused
                  ? GlassTheme.textPrimary
                  : selected
                  ? primary
                  : GlassTheme.border,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              autofocus: widget.autofocus,
              onTap: widget.onTap,
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.large ? 22 : 18,
                  vertical: widget.large ? 14 : 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: duration,
                      child: selected
                          ? Padding(
                              key: const ValueKey('on'),
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                ReelishIcons.check,
                                size: AppIcon.sm,
                                color: primary,
                              ),
                            )
                          : const SizedBox(key: ValueKey('off')),
                    ),
                    Text(
                      widget.label,
                      style: AppType.titleSmall.copyWith(
                        color: GlassTheme.textPrimary,
                        fontSize: widget.large ? 17 : 15,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
