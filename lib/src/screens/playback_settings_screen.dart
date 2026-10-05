import 'package:flutter/material.dart';
import 'package:feather_icon_font/feather_icon_font.dart';

import '../models/playback_settings.dart';
import '../services/accent_settings_controller.dart';
import '../services/playback_settings_controller.dart';
import '../theme/glass_theme.dart';
import 'app_information_screens.dart';
import 'legal_information_screen.dart';
import 'subtitle_addons_screen.dart';

Widget _settingsGroupLabel(BuildContext context, String label) => Padding(
  padding: const EdgeInsets.only(left: 4),
  child: Text(
    label,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: GlassTheme.muted,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.2,
    ),
  ),
);

class _SettingsPageHeader extends StatelessWidget {
  const _SettingsPageHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onBack,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 16, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to settings',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: GlassTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: GlassTheme.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: GlassTheme.primary, size: 21),
          ),
        ],
      ),
    ),
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.onPlaybackSettings,
    required this.onAppearanceSettings,
    required this.accentSettings,
  });

  final VoidCallback onPlaybackSettings;
  final VoidCallback onAppearanceSettings;
  final AccentSettingsController accentSettings;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 30, 20, 120),
    children: [
      Text(
        'Settings',
        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -.8,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        'Make Reelish work the way you like.',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: GlassTheme.muted,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 26),
      _settingsGroupLabel(context, 'PREFERENCES'),
      const SizedBox(height: 10),
      _ProfileEntry(
        icon: FeatherIcons.playCircle,
        eyebrow: 'PLAYER',
        title: 'Playback',
        subtitle: 'Streams, gestures, subtitles and P2P playback',
        onTap: onPlaybackSettings,
      ),
      const SizedBox(height: 12),
      AnimatedBuilder(
        animation: accentSettings,
        builder: (context, _) => _ProfileEntry(
          icon: FeatherIcons.monitor,
          eyebrow: 'PERSONALIZE',
          title: 'Appearance',
          subtitle: '${accentSettings.value.label} accent color',
          onTap: onAppearanceSettings,
        ),
      ),
      const SizedBox(height: 22),
      _settingsGroupLabel(context, 'INFORMATION'),
      const SizedBox(height: 10),
      _ProfileEntry(
        icon: FeatherIcons.shield,
        eyebrow: 'PRIVACY',
        title: 'Privacy policy',
        subtitle: 'What stays on your device and what is sent to services',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const LegalInformationScreen(document: LegalDocument.privacy),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _ProfileEntry(
        icon: FeatherIcons.fileText,
        eyebrow: 'LEGAL',
        title: 'Terms of use',
        subtitle: 'Rules for using the app, add-ons and media sources',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const LegalInformationScreen(document: LegalDocument.terms),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _ProfileEntry(
        icon: FeatherIcons.info,
        eyebrow: 'ABOUT',
        title: 'About',
        subtitle: 'App information and version',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
        ),
      ),
      const SizedBox(height: 12),
      _ProfileEntry(
        icon: FeatherIcons.fileText,
        eyebrow: 'ACKNOWLEDGEMENTS',
        title: 'Credits',
        subtitle: 'Services, content and third-party notices',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const LegalInformationScreen(document: LegalDocument.notices),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _ProfileEntry(
        icon: FeatherIcons.heart,
        eyebrow: 'OPTIONAL',
        title: 'Support development',
        subtitle: 'Help with continued development and server costs',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SupportDevelopmentScreen(),
          ),
        ),
      ),
    ],
  );
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.controller,
    required this.onBack,
  });

  final AccentSettingsController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _SettingsPageHeader(
        title: 'Appearance',
        subtitle: 'Choose the accent used across the app.',
        icon: Icons.palette_outlined,
        onBack: onBack,
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 132),
          children: [
            AnimatedBuilder(
              animation: controller,
              builder: (context, _) => _AppearanceSettings(
                selected: controller.value,
                onSelected: (accent) => controller.update(accent),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({required this.selected, required this.onSelected});

  final AccentPalette selected;
  final ValueChanged<AccentPalette> onSelected;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    borderRadius: BorderRadius.circular(20),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: selected.primary.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(FeatherIcons.monitor, color: selected.primary),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'APPEARANCE',
                      style: TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Accent color',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: selected.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      selected.label,
                      style: TextStyle(
                        color: selected.bright,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Choose a color for highlights and controls.',
            style: TextStyle(color: GlassTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final itemWidth = (constraints.maxWidth - spacing * 3) / 4;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final accent in GlassTheme.accents)
                    _AccentChoice(
                      accent: accent,
                      selected: accent.id == selected.id,
                      width: itemWidth,
                      onTap: () => onSelected(accent),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _AccentChoice extends StatelessWidget {
  const _AccentChoice({
    required this.accent,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final AccentPalette accent;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '${accent.label} accent color',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: width,
        height: 72,
        decoration: BoxDecoration(
          color: selected
              ? accent.primary.withValues(alpha: .12)
              : GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected ? accent.primary : GlassTheme.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: accent.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.primary.withValues(alpha: .35),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: GlassTheme.background,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.primary),
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        size: 10,
                        color: accent.bright,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              accent.label,
              style: TextStyle(
                color: selected ? accent.bright : GlassTheme.textPrimary,
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ProfileEntry extends StatelessWidget {
  const _ProfileEntry({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: GlassTheme.surface,
    borderRadius: BorderRadius.circular(20),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      minVerticalPadding: 12,
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: GlassTheme.primary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Icon(icon, color: GlassTheme.primary),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: GlassTheme.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              eyebrow,
              style: TextStyle(
                color: GlassTheme.primary,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -.1,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          style: const TextStyle(
            color: GlassTheme.muted,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
      trailing: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.chevron_right_rounded, size: 19, color: GlassTheme.muted),
      ),
      onTap: onTap,
    ),
  );
}

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({
    super.key,
    required this.controller,
    required this.plugins,
    required this.onBack,
  });

  final PlaybackSettingsController controller;
  final List<({String id, String name, String repository})> plugins;
  final VoidCallback onBack;

  Future<void> _save(PlaybackSettings value) => controller.update(value);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: true,
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final settings = controller.value;
        return Column(
          children: [
            _SettingsPageHeader(
              title: 'Playback',
              subtitle: 'Fine tune streams, subtitles and controls.',
              icon: Icons.play_circle_outline_rounded,
              onBack: onBack,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 132),
                children: [
                  _section('PLAYER', [
                    _switchRow(
                      'Loading overlay',
                      'Show a loading indicator until the first video frame appears.',
                      settings.showLoadingOverlay,
                      (value) =>
                          _save(settings.copyWith(showLoadingOverlay: value)),
                    ),
                    _switchRow(
                      'Show loading status',
                      'Display the player connection status while video initializes.',
                      settings.showLoadingStatus,
                      (value) =>
                          _save(settings.copyWith(showLoadingStatus: value)),
                    ),
                    _switchRow(
                      'Pause overlay',
                      'When paused, show the title artwork, details and synopsis with a large play button.',
                      settings.pauseOverlay,
                      (value) => _save(settings.copyWith(pauseOverlay: value)),
                    ),
                    _switchRow(
                      'Touch gestures',
                      'Use double taps to seek and vertical swipes to adjust brightness or volume.',
                      settings.touchGestures,
                      (value) => _save(settings.copyWith(touchGestures: value)),
                    ),
                    _switchRow(
                      'Hold to speed',
                      'Temporarily increase playback speed while pressing and holding the video.',
                      settings.holdToSpeed,
                      (value) => _save(settings.copyWith(holdToSpeed: value)),
                    ),
                    _choiceRow(
                      'Hold speed',
                      'Playback speed while the video surface is held.',
                      '${settings.holdSpeed}×',
                      () async {
                        final value = await _choose<String>(
                          context,
                          'Hold speed',
                          ['1.5×', '2×', '2.5×', '3×'],
                          '${settings.holdSpeed}×',
                        );
                        if (value != null) {
                          await _save(
                            settings.copyWith(
                              holdSpeed: double.parse(
                                value.replaceAll('×', ''),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    _choiceRow(
                      'Default playback speed',
                      'Starting speed for newly opened videos. In-player speed changes stay with the current video.',
                      '${settings.defaultPlaybackSpeed}×',
                      () async {
                        const speeds = [.5, .75, 1.0, 1.25, 1.5, 2.0];
                        final value = await _choose<double>(
                          context,
                          'Default playback speed',
                          speeds,
                          settings.defaultPlaybackSpeed,
                          label: (speed) => '$speed×',
                        );
                        if (value != null) {
                          await _save(
                            settings.copyWith(defaultPlaybackSpeed: value),
                          );
                        }
                      },
                    ),
                    _choiceRow(
                      'Preferred video quality',
                      'Preferred resolution for new videos when the stream exposes selectable video tracks.',
                      _qualityLabel(settings.preferredVideoHeight),
                      () async {
                        const heights = [0, 480, 720, 1080, 1440, 2160];
                        final value = await _choose<int>(
                          context,
                          'Preferred video quality',
                          heights,
                          settings.preferredVideoHeight,
                          label: _qualityLabel,
                        );
                        if (value != null) {
                          await _save(
                            settings.copyWith(preferredVideoHeight: value),
                          );
                        }
                      },
                    ),
                  ]),
                  _section('STREAM AUTO-PLAY', [
                    _switchRow(
                      'Auto stream selection',
                      'Play the first available stream automatically. Turn off to choose from results.',
                      settings.autoStreamSelection,
                      (value) =>
                          _save(settings.copyWith(autoStreamSelection: value)),
                    ),
                    _sliderRow(
                      'Stream selection timeout',
                      'Wait for more provider results before opening the stream picker.',
                      settings.streamSelectionTimeoutSeconds.toDouble(),
                      min: 1,
                      max: 15,
                      divisions: 14,
                      valueLabel: '${settings.streamSelectionTimeoutSeconds}s',
                      onChanged: (value) => _save(
                        settings.copyWith(
                          streamSelectionTimeoutSeconds: value.round(),
                        ),
                      ),
                    ),
                    _choiceRow(
                      'Allowed plugins',
                      'Choose which installed providers can return streams.',
                      _providerSummary(settings.allowedProviderIds),
                      () => _chooseProviders(context, settings),
                    ),
                  ]),
                  _section('DECODER', [
                    _infoRow(
                      'Decoder configuration',
                      'Platform managed',
                      'Android uses Media3 with a MediaKit fallback; other platforms use their registered video_player backend. These adapters do not expose decoder, renderer, Dolby Vision, or tunneled playback controls.',
                    ),
                  ]),
                  _section('SKIP SEGMENTS', [
                    _infoRow(
                      'Intro and outro detection',
                      'Unavailable in this build',
                      'Episode data and stream providers do not supply intro or outro timestamps, so automatic segment skipping is unavailable.',
                    ),
                  ]),
                  _section('NEXT EPISODE', [
                    _switchRow(
                      'Auto-play next episode',
                      'Start the next episode when the configured playback threshold is reached.',
                      settings.autoPlayNextEpisode,
                      (value) =>
                          _save(settings.copyWith(autoPlayNextEpisode: value)),
                    ),
                    _sliderRow(
                      'Next episode threshold',
                      'Percentage of the current episode used to offer the next one.',
                      settings.nextEpisodeThresholdPercent.toDouble(),
                      min: 50,
                      max: 100,
                      divisions: 50,
                      valueLabel: '${settings.nextEpisodeThresholdPercent}%',
                      onChanged: (value) => _save(
                        settings.copyWith(
                          nextEpisodeThresholdPercent: value.round(),
                        ),
                      ),
                    ),
                    _infoRow(
                      'Binge group options',
                      'Unavailable in this build',
                      'The episode catalog has no binge-group metadata or grouping behavior to configure.',
                    ),
                  ]),
                  _section('SUBTITLE AND AUDIO', [
                    _choiceRow(
                      'Preferred audio language',
                      'Select the first matching audio track when available.',
                      _languageLabel(
                        settings.preferredAudioLanguage,
                        device: true,
                      ),
                      () => _chooseLanguage(
                        context,
                        'Preferred audio language',
                        settings.preferredAudioLanguage,
                        (value) =>
                            settings.copyWith(preferredAudioLanguage: value),
                        includeDevice: true,
                      ),
                    ),
                    _choiceRow(
                      'Secondary audio language',
                      'Fallback audio language when the preferred language is unavailable.',
                      _languageLabel(settings.secondaryAudioLanguage),
                      () => _chooseLanguage(
                        context,
                        'Secondary audio language',
                        settings.secondaryAudioLanguage,
                        (value) =>
                            settings.copyWith(secondaryAudioLanguage: value),
                      ),
                    ),
                    _choiceRow(
                      'Preferred subtitle language',
                      'Choose the subtitle language to select automatically.',
                      _languageLabel(settings.preferredSubtitleLanguage),
                      () => _chooseLanguage(
                        context,
                        'Preferred subtitle language',
                        settings.preferredSubtitleLanguage,
                        (value) =>
                            settings.copyWith(preferredSubtitleLanguage: value),
                      ),
                    ),
                    _choiceRow(
                      'Secondary subtitle language',
                      'Fallback subtitle language.',
                      _languageLabel(settings.secondarySubtitleLanguage),
                      () => _chooseLanguage(
                        context,
                        'Secondary subtitle language',
                        settings.secondarySubtitleLanguage,
                        (value) =>
                            settings.copyWith(secondarySubtitleLanguage: value),
                      ),
                    ),
                    _switchRow(
                      'Strip SDH subtitles',
                      'Hide subtitles marked for sound descriptions or closed captions.',
                      settings.stripSdhSubtitles,
                      (value) =>
                          _save(settings.copyWith(stripSdhSubtitles: value)),
                    ),
                    _switchRow(
                      'Use forced subtitles',
                      'Prefer forced subtitles matching the selected audio language.',
                      settings.useForcedSubtitles,
                      (value) =>
                          _save(settings.copyWith(useForcedSubtitles: value)),
                    ),
                    _switchRow(
                      'Show only preferred languages',
                      'Filter the subtitle picker to your preferred subtitle languages.',
                      settings.showOnlyPreferredLanguages,
                      (value) => _save(
                        settings.copyWith(showOnlyPreferredLanguages: value),
                      ),
                    ),
                    _choiceRow(
                      'Subtitle addons',
                      'Stremio subtitle addons searched while you watch.',
                      'Manage',
                      () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SubtitleAddonsScreen(),
                        ),
                      ),
                    ),
                  ]),
                  _section('SUBTITLE RENDERING', [
                    _sliderRow(
                      'Subtitle size',
                      'Text size for external SRT and WebVTT subtitles.',
                      settings.subtitleSize,
                      min: 12,
                      max: 36,
                      divisions: 24,
                      valueLabel: '${settings.subtitleSize.round()} sp',
                      onChanged: (value) =>
                          _save(settings.copyWith(subtitleSize: value)),
                    ),
                    _sliderRow(
                      'Vertical offset',
                      'Distance above the bottom edge of the video.',
                      settings.subtitleVerticalOffset,
                      min: 0,
                      max: 80,
                      divisions: 16,
                      valueLabel: '${settings.subtitleVerticalOffset.round()}',
                      onChanged: (value) => _save(
                        settings.copyWith(subtitleVerticalOffset: value),
                      ),
                    ),
                    _switchRow(
                      'Bold',
                      'Use a heavier subtitle font weight.',
                      settings.subtitleBold,
                      (value) => _save(settings.copyWith(subtitleBold: value)),
                    ),
                    _colorRow(
                      context,
                      'Text color',
                      Color(settings.subtitleTextColor),
                      (color) => _save(
                        settings.copyWith(subtitleTextColor: color.toARGB32()),
                      ),
                    ),
                    _colorRow(
                      context,
                      'Background color',
                      Color(settings.subtitleBackgroundColor),
                      (color) => _save(
                        settings.copyWith(
                          subtitleBackgroundColor: color.toARGB32(),
                        ),
                      ),
                      allowTransparent: true,
                    ),
                    _switchRow(
                      'Outline',
                      'Draw a contrasting border around subtitle text.',
                      settings.subtitleOutline,
                      (value) =>
                          _save(settings.copyWith(subtitleOutline: value)),
                    ),
                    _colorRow(
                      context,
                      'Outline color',
                      Color(settings.subtitleOutlineColor),
                      (color) => _save(
                        settings.copyWith(
                          subtitleOutlineColor: color.toARGB32(),
                        ),
                      ),
                    ),
                    _infoRow(
                      'ASS / SSA rendering',
                      'External SRT and WebVTT only',
                      'The app currently renders text cues itself. libass styles and animations are not available in this player adapter.',
                    ),
                  ]),
                  _section('P2P STREAMING', [
                    _switchRow(
                      'P2P streaming',
                      'Allow torrent sources from installed providers on Android.',
                      settings.p2pStreaming,
                      (value) => _save(settings.copyWith(p2pStreaming: value)),
                    ),
                    _actionRow(
                      'Clear torrent cache',
                      'Remove files stored by torrent playback.',
                      'Clear',
                      () => _confirmClearTorrentCache(context),
                    ),
                    _infoRow(
                      'Torrent cache limit',
                      'Unsupported by the torrent plugin',
                      'The plugin accepts a cache directory but exposes no size limit or eviction API. Manual full-cache clearing is available.',
                    ),
                  ]),
                  _section('STREAM SELECTION', [
                    _switchRow(
                      'Reuse last link',
                      'Try the last working stream for this title while its cache is valid.',
                      settings.reuseLastLink,
                      (value) => _save(settings.copyWith(reuseLastLink: value)),
                    ),
                    _choiceRow(
                      'Last link cache duration',
                      'Forget saved stream links after this period.',
                      _durationLabel(settings.lastLinkCacheHours),
                      () async {
                        final value = await _choose<int>(
                          context,
                          'Last link cache duration',
                          const [6, 12, 24, 48, 72, 168],
                          settings.lastLinkCacheHours,
                          label: _durationLabel,
                        );
                        if (value != null) {
                          await _save(
                            settings.copyWith(lastLinkCacheHours: value),
                          );
                        }
                      },
                    ),
                  ]),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 5, bottom: 9),
          child: Text(
            title,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: 11,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: GlassTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: GlassTheme.border),
          ),
          child: Column(
            children: [
              for (var index = 0; index < children.length; index++)
                _wrapRow(
                  children[index],
                  divider: index != children.length - 1,
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _wrapRow(Widget child, {required bool divider}) => Column(
    children: [
      child,
      if (divider)
        const Divider(
          height: 1,
          indent: 17,
          endIndent: 17,
          color: Colors.white12,
        ),
    ],
  );

  Widget _switchRow(
    String title,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
  ) => _SettingRow(
    title: title,
    description: description,
    trailing: Switch.adaptive(value: value, onChanged: onChanged),
  );

  Widget _choiceRow(
    String title,
    String description,
    String value,
    VoidCallback onTap,
  ) => _SettingRow(
    title: title,
    description: description,
    value: value,
    onTap: onTap,
  );

  Widget _infoRow(String title, String value, String description) =>
      _SettingRow(title: title, description: description, value: value);

  Widget _actionRow(
    String title,
    String description,
    String action,
    VoidCallback onTap,
  ) => _SettingRow(
    title: title,
    description: description,
    trailing: TextButton(onPressed: onTap, child: Text(action)),
  );

  Widget _sliderRow(
    String title,
    String description,
    double value, {
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(17, 15, 17, 11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
            Text(valueLabel, style: const TextStyle(color: GlassTheme.muted)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _colorRow(
    BuildContext context,
    String title,
    Color color,
    ValueChanged<Color> onSelected, {
    bool allowTransparent = false,
  }) => _SettingRow(
    title: title,
    description: '',
    value: color.a == 0
        ? 'Transparent'
        : '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
    trailing: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white38),
      ),
    ),
    onTap: () async {
      final initial = HSVColor.fromColor(color.a == 0 ? Colors.white : color);
      var hue = initial.hue;
      var saturation = initial.saturation;
      var brightness = initial.value;
      var alpha = allowTransparent ? initial.alpha : 1.0;
      final chosen = await showDialog<Color>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final preview = HSVColor.fromAHSV(
              alpha,
              hue,
              saturation,
              brightness,
            ).toColor();
            return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 44,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: preview,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white38),
                      ),
                    ),
                    _colorSlider(
                      'Hue',
                      hue,
                      0,
                      360,
                      color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                      onChanged: (value) => setDialogState(() => hue = value),
                    ),
                    _colorSlider(
                      'Saturation',
                      saturation,
                      0,
                      1,
                      color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                      onChanged: (value) =>
                          setDialogState(() => saturation = value),
                    ),
                    _colorSlider(
                      'Brightness',
                      brightness,
                      0,
                      1,
                      color: HSVColor.fromAHSV(1, hue, saturation, 1).toColor(),
                      onChanged: (value) =>
                          setDialogState(() => brightness = value),
                    ),
                    if (allowTransparent)
                      _colorSlider(
                        'Opacity',
                        alpha,
                        0,
                        1,
                        onChanged: (value) =>
                            setDialogState(() => alpha = value),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, preview),
                  child: const Text('Choose'),
                ),
              ],
            );
          },
        ),
      );
      if (chosen != null) onSelected(chosen);
    },
  );

  Widget _colorSlider(
    String label,
    double value,
    double min,
    double max, {
    Color? color,
    required ValueChanged<double> onChanged,
  }) => Row(
    children: [
      SizedBox(width: 82, child: Text(label)),
      if (color != null)
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: max > 1 ? 36 : 20,
          onChanged: onChanged,
        ),
      ),
    ],
  );

  Future<void> _chooseLanguage(
    BuildContext context,
    String title,
    String current,
    PlaybackSettings Function(String) update, {
    bool includeDevice = false,
  }) async {
    final options = <String>[
      if (includeDevice) 'device',
      '',
      'en',
      'es',
      'fr',
      'de',
      'it',
      'pt',
      'ja',
      'ko',
      'zh',
      'ar',
      'ru',
    ];
    final value = await _choose<String>(
      context,
      title,
      options,
      current,
      label: (value) => _languageLabel(value, device: includeDevice),
    );
    if (value != null) await _save(update(value));
  }

  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    List<T> options,
    T current, {
    String Function(T)? label,
  }) => showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (context) => Material(
      color: GlassTheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final option in options)
            ListTile(
              title: Text(label?.call(option) ?? '$option'),
              trailing: option == current
                  ? Icon(Icons.check_rounded, color: GlassTheme.primary)
                  : null,
              onTap: () => Navigator.pop(context, option),
            ),
        ],
      ),
    ),
  );

  Future<void> _chooseProviders(
    BuildContext context,
    PlaybackSettings settings,
  ) async {
    final initial = settings.allowedProviderIds == null
        ? plugins.map((plugin) => plugin.id).toSet()
        : Set<String>.of(settings.allowedProviderIds!);
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (context) {
        final values = Set<String>.of(initial);
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Allowed plugins'),
            content: SizedBox(
              width: 420,
              child: plugins.isEmpty
                  ? const Text('Install a provider plugin first.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final plugin in plugins)
                          CheckboxListTile(
                            value: values.contains(plugin.id),
                            title: Text(plugin.name),
                            subtitle: Text(plugin.repository),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                values.add(plugin.id);
                              } else {
                                values.remove(plugin.id);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, <String>{'__all__'}),
                child: const Text('All enabled'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, values),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    final all = plugins.map((plugin) => plugin.id).toSet();
    final allSelected =
        selected.contains('__all__') || selected.containsAll(all);
    await _save(
      settings.copyWith(
        allowedProviderIds: allSelected ? null : selected,
        clearAllowedProviderIds: allSelected,
      ),
    );
  }

  Future<void> _confirmClearTorrentCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear torrent cache?'),
        content: const Text(
          'This removes cached torrent files stored by Reelish.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.clearTorrentCache();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Torrent cache cleared.')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not clear the torrent cache.')),
        );
      }
    }
  }

  String _providerSummary(Set<String>? ids) {
    if (ids == null) return 'All enabled plugins';
    if (ids.isEmpty) return 'None selected';
    return '${ids.length} selected';
  }

  String _languageLabel(String value, {bool device = false}) => switch (value) {
    'device' when device => 'Device language',
    '' => 'None',
    'en' => 'English',
    'es' => 'Spanish',
    'fr' => 'French',
    'de' => 'German',
    'it' => 'Italian',
    'pt' => 'Portuguese',
    'ja' => 'Japanese',
    'ko' => 'Korean',
    'zh' => 'Chinese',
    'ar' => 'Arabic',
    'ru' => 'Russian',
    _ => value,
  };

  String _qualityLabel(int height) => height == 0 ? 'Auto' : '${height}p';

  String _durationLabel(int hours) => hours >= 24
      ? '${hours ~/ 24} day${hours >= 48 ? 's' : ''}'
      : '$hours hours';
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.description,
    this.value,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String description;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$title. $description${value == null ? '' : ' $value'}',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  if (value != null && trailing == null) ...[
                    const SizedBox(height: 5),
                    Text(
                      value!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else if (onTap != null)
              const Icon(Icons.chevron_right_rounded, color: GlassTheme.muted),
          ],
        ),
      ),
    ),
  );
}
