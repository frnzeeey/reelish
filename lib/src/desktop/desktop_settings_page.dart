import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../screens/app_information_screens.dart';
import '../screens/credits_screen.dart';
import '../screens/legal_information_screen.dart';
import '../screens/playback_settings_screen.dart';
import '../screens/subtitle_addons_screen.dart';
import '../services/accent_settings_controller.dart';
import '../services/playback_settings_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';
import 'desktop_widgets.dart';

/// The settings pages a Windows Settings category shows.
enum DesktopSettingsSection {
  appearance(
    'Appearance',
    'Accent color for highlights and controls',
    Symbols.palette_rounded,
  ),
  playback(
    'Playback',
    'Player, stream selection, subtitles and P2P',
    Symbols.play_circle_rounded,
  ),
  subtitles(
    'Subtitle addons',
    'Stremio subtitle sources searched while you watch',
    Symbols.closed_caption_rounded,
  ),
  about('About Reelish', 'Version, build and updates', Symbols.info_rounded),
  credits(
    'Credits & attribution',
    'TMDB, third-party services and acknowledgments',
    Symbols.handshake_rounded,
  ),
  privacy(
    'Privacy policy',
    'What stays on your device and what is sent to services',
    Symbols.shield_rounded,
  ),
  terms(
    'Terms of use',
    'Rules for using the app, add-ons and media sources',
    Symbols.gavel_rounded,
  ),
  support(
    'Support development',
    'Optional help with development and server costs',
    Symbols.favorite_rounded,
  );

  const DesktopSettingsSection(this.title, this.description, this.icon);

  final String title;
  final String description;
  final IconData icon;
}

/// Settings on Windows: the categories of the phone and TV Settings list
/// on the left, the chosen one beside them, so a change and its effect are
/// on screen together. Each category is the same page the other platforms
/// open (Appearance, Playback, Subtitle addons, About, …), so every setting,
/// value and saved preference is the one they use. Pages those open further
/// still open over the window, where Esc closes them.
class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({
    super.key,
    required this.accentSettings,
    required this.playbackSettings,
    required this.plugins,
    this.initialSection = DesktopSettingsSection.appearance,
  });

  final AccentSettingsController accentSettings;
  final PlaybackSettingsController playbackSettings;

  /// The installed providers, for Playback's preferred-provider choices.
  final List<({String id, String name, String repository})> plugins;
  final DesktopSettingsSection initialSection;

  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  late DesktopSettingsSection _section = widget.initialSection;

  static const _groups = [
    ('GENERAL', [DesktopSettingsSection.appearance]),
    (
      'PLAYBACK',
      [DesktopSettingsSection.playback, DesktopSettingsSection.subtitles],
    ),
    (
      'ABOUT & INFORMATION',
      [DesktopSettingsSection.about, DesktopSettingsSection.credits],
    ),
    ('LEGAL', [DesktopSettingsSection.privacy, DesktopSettingsSection.terms]),
    ('SUPPORT', [DesktopSettingsSection.support]),
  ];

  Widget _page(DesktopSettingsSection section) => switch (section) {
    // The pages' Back is hidden in the pane (see SettingsEmbedding).
    DesktopSettingsSection.appearance => AppearanceSettingsScreen(
      controller: widget.accentSettings,
      onBack: () {},
    ),
    DesktopSettingsSection.playback => PlaybackSettingsScreen(
      controller: widget.playbackSettings,
      plugins: widget.plugins,
      onBack: () {},
    ),
    DesktopSettingsSection.subtitles => const SubtitleAddonsScreen(),
    DesktopSettingsSection.about => const AboutScreen(),
    DesktopSettingsSection.credits => const CreditsScreen(),
    DesktopSettingsSection.privacy => const LegalInformationScreen(
      document: LegalDocument.privacy,
    ),
    DesktopSettingsSection.terms => const LegalInformationScreen(
      document: LegalDocument.terms,
    ),
    DesktopSettingsSection.support => const SupportDevelopmentScreen(),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final railWidth = (constraints.maxWidth * .3).clamp(250.0, 330.0);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: railWidth,
            child: FocusTraversalGroup(
              // A dozen rows: all built, so each is a Tab stop at once.
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _RailTitle(),
                    for (final (label, sections) in _groups) ...[
                      _GroupLabel(label),
                      for (final section in sections)
                        AnimatedBuilder(
                          animation: widget.accentSettings,
                          builder: (context, _) => _RailItem(
                            section: section,
                            selected: section == _section,
                            value: section == DesktopSettingsSection.appearance
                                ? widget.accentSettings.value.label
                                : null,
                            onTap: () => setState(() => _section = section),
                          ),
                        ),
                      if (label == 'ABOUT & INFORMATION')
                        _RailItem.action(
                          title: 'Open-source licenses',
                          description:
                              'Licenses for Flutter, packages and fonts',
                          icon: Symbols.code_rounded,
                          onTap: () => showAppLicenses(context),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: .06),
          ),
          Expanded(
            child: SettingsEmbedding(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: AnimatedSwitcher(
                    duration: desktopMotion(context, 200),
                    switchInCurve: DesktopSurfaces.curve,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(.012, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Padding(
                      key: ValueKey(_section),
                      padding: const EdgeInsets.only(top: 22),
                      child: _page(_section),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _RailTitle extends StatelessWidget {
  const _RailTitle();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(DesktopMetrics.pagePadding - 20, 40, 8, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Settings',
          style: TextStyle(
            fontSize: 36,
            height: 1.1,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Make Reelish work the way you like.',
          style: TextStyle(color: GlassTheme.muted, fontSize: AppTextSize.body),
        ),
      ],
    ),
  );
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding - 20,
      22,
      8,
      8,
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: GlassTheme.muted,
        fontSize: AppTextSize.caption,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

/// A category in the rail; Enter or a click shows it. [action] rows open
/// something over the window instead (the licenses).
class _RailItem extends StatefulWidget {
  const _RailItem({
    required DesktopSettingsSection this.section,
    required this.selected,
    required this.onTap,
    this.value,
  }) : title = null,
       description = null,
       icon = null;

  const _RailItem.action({
    required String this.title,
    required String this.description,
    required IconData this.icon,
    required this.onTap,
  }) : section = null,
       selected = false,
       value = null;

  final DesktopSettingsSection? section;
  final String? title;
  final String? description;
  final IconData? icon;
  final bool selected;
  final String? value;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final title = section?.title ?? widget.title!;
    final description = section?.description ?? widget.description!;
    final icon = section?.icon ?? widget.icon!;
    final selected = widget.selected;
    final accent = GlassTheme.primary;
    final duration = desktopMotion(context, 160);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            selected: selected,
            label: '$title, $description',
            excludeSemantics: true,
            child: AnimatedContainer(
              duration: duration,
              curve: DesktopSurfaces.curve,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              decoration: BoxDecoration(
                gradient: selected
                    ? LinearGradient(
                        colors: [
                          accent.withValues(alpha: _hovered ? .24 : .18),
                          accent.withValues(alpha: _hovered ? .09 : .04),
                        ],
                      )
                    : null,
                color: selected
                    ? null
                    : _hovered
                    ? Colors.white.withValues(alpha: .05)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(DesktopSurfaces.radius),
                border: Border.all(
                  color: _focused ? GlassTheme.coralBright : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  SettingsIconBadge(icon: icon, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTextSize.body,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : GlassTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.value ?? description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTextSize.label,
                            color: widget.value != null
                                ? GlassTheme.coralBright
                                : GlassTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (section == null) ...[
                    // Apart from a title cut to fit, so the two never touch.
                    const SizedBox(width: 8),
                    const Icon(
                      Symbols.open_in_new_rounded,
                      size: 16,
                      color: GlassTheme.muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
